// Composes the app icon — the cat in a hard hat, cut out like a sticker, on
// a glowing gradient tile — and writes every size the platforms need.
// No dependencies:
//   node tool/gen_icons.mjs
//
// The cat is tool/mascot.png, a cut-out with a transparent background; the
// tile, the sticker outline and the shadow are drawn here. To use another
// picture, replace that file and adjust the views below.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import zlib from 'node:zlib';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

const clamp = (v, lo = 0, hi = 1) => Math.max(lo, Math.min(hi, v));
const mix = (a, b, t) => a.map((x, i) => x + (b[i] - x) * t);
const hex = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));

// ---- the cat ---------------------------------------------------------------

/** Decodes an 8-bit RGB or RGBA PNG (not interlaced) into straight RGBA. */
function readPng(path) {
  const file = readFileSync(path);
  let w = 0, h = 0, channels = 0;
  const idat = [];
  for (let at = 8; at < file.length;) {
    const length = file.readUInt32BE(at);
    const type = file.toString('ascii', at + 4, at + 8);
    const data = file.subarray(at + 8, at + 8 + length);
    if (type === 'IHDR') {
      w = data.readUInt32BE(0);
      h = data.readUInt32BE(4);
      channels = { 2: 3, 6: 4 }[data[9]];
      if (data[8] !== 8 || !channels || data[12] !== 0) {
        throw new Error(`${path}: only 8-bit RGB(A) PNGs without interlacing`);
      }
    } else if (type === 'IDAT') idat.push(data);
    at += 12 + length;
  }
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = w * channels;
  const rgba = Buffer.alloc(w * h * 4);
  let previous = Buffer.alloc(stride);
  for (let y = 0; y < h; y++) {
    const filter = raw[y * (stride + 1)];
    const line = Buffer.from(raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1)));
    for (let i = 0; i < stride; i++) {
      const a = i >= channels ? line[i - channels] : 0;
      const b = previous[i];
      const c = i >= channels ? previous[i - channels] : 0;
      let predicted = 0;
      if (filter === 1) predicted = a;
      else if (filter === 2) predicted = b;
      else if (filter === 3) predicted = (a + b) >> 1;
      else if (filter === 4) {
        const p = a + b - c;
        const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
        predicted = pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      }
      line[i] = (line[i] + predicted) & 255;
    }
    for (let x = 0; x < w; x++) {
      const o = (y * w + x) * 4;
      rgba[o] = line[x * channels];
      rgba[o + 1] = line[x * channels + 1];
      rgba[o + 2] = line[x * channels + 2];
      rgba[o + 3] = channels === 4 ? line[x * channels + 3] : 255;
    }
    previous = line;
  }
  return { w, h, rgba };
}

/** Colours a little richer than the source photograph's. */
const SATURATION = 1.14;

/** The cat, premultiplied, as floats in 0..1. */
const mascot = (() => {
  const { w, h, rgba } = readPng(join(root, 'tool/mascot.png'));
  const px = new Float32Array(w * h * 4);
  for (let i = 0; i < w * h; i++) {
    const a = rgba[i * 4 + 3] / 255;
    const rgb = [rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]];
    const grey = 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2];
    for (let c = 0; c < 3; c++) {
      px[i * 4 + c] = (clamp(grey + (rgb[c] - grey) * SATURATION, 0, 255) / 255) * a;
    }
    px[i * 4 + 3] = a;
  }
  return { w, h, px };
})();

// Which square of mascot.png (in its pixels) fills the canvas. The cat's
// lower body is not in the picture, so every view lets it run off the
// bottom edge.
const VIEW_TILE = { x: -22, y: -20, size: 272 };
// Small icons show the head alone: at 16 px nothing else reads.
const VIEW_HEAD = { x: -17, y: -8, size: 196 };
// The adaptive icon's canvas is 108dp of which launchers show the middle
// 72dp, as a circle at worst; the head stays inside the 66dp safe zone.
const VIEW_ADAPTIVE = { x: -125, y: -115, size: 480 };
// On its own, for places that bring their own background.
const VIEW_ALONE = { x: -10, y: -36, size: 326 };

// The sticker look, in mascot.png pixels so it scales with the cat.
const OUTLINE = 6.5;
const SHADOW_BLUR = 9;
const SHADOW_DROP = 7;

/** Mitchell–Netravali: soft enough to hide the source's JPEG blocks. */
function mitchell(x) {
  x = Math.abs(x);
  if (x < 1) return (7 * x * x * x - 12 * x * x + 16 / 3) / 6;
  if (x < 2) return (-7 / 3 * x * x * x + 12 * x * x - 20 * x + 32 / 3) / 6;
  return 0;
}

/** For each of `count` output pixels: where it reads from, and the weights. */
function taps(count, start, step, limit) {
  const stretch = Math.max(1, step);
  return Array.from({ length: count }, (_, i) => {
    const centre = start + (i + 0.5) * step;
    const first = Math.floor(centre - 2 * stretch), last = Math.ceil(centre + 2 * stretch);
    const list = [];
    let total = 0;
    for (let j = first; j <= last; j++) {
      const weight = mitchell((j + 0.5 - centre) / stretch);
      if (weight === 0) continue;
      total += weight;
      // Beyond the picture there is only transparency.
      if (j >= 0 && j < limit) list.push([j, weight]);
    }
    return list.map(([j, weight]) => [j, weight / total]);
  });
}

/** The part of the cat inside `view`, resampled to size x size (premultiplied). */
function drawMascot(size, view) {
  const step = view.size / size;
  const { w, h, px } = mascot;
  const columns = taps(size, view.x, step, w), rows = taps(size, view.y, step, h);
  const wide = new Float32Array(size * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < size; x++) {
      const o = (y * size + x) * 4;
      for (const [j, weight] of columns[x]) {
        const s = (y * w + j) * 4;
        for (let c = 0; c < 4; c++) wide[o + c] += px[s + c] * weight;
      }
    }
  }
  const out = new Float32Array(size * size * 4);
  for (let y = 0; y < size; y++) {
    for (const [j, weight] of rows[y]) {
      for (let i = 0; i < size * 4; i++) out[y * size * 4 + i] += wide[j * size * 4 + i] * weight;
    }
  }
  for (let i = 0; i < out.length; i++) out[i] = clamp(out[i]);
  return out;
}

/** Grows a coverage map by `radius` pixels, with a soft edge. */
function grow(alpha, size, radius) {
  const reach = Math.ceil(radius + 0.5);
  const out = new Float32Array(size * size);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let best = 0;
      for (let dy = -reach; dy <= reach && best < 1; dy++) {
        const sy = y + dy;
        if (sy < 0 || sy >= size) continue;
        for (let dx = -reach; dx <= reach; dx++) {
          const sx = x + dx;
          if (sx < 0 || sx >= size) continue;
          const a = alpha[sy * size + sx];
          if (a <= best) continue;
          const v = a * clamp(radius + 0.5 - Math.hypot(dx, dy));
          if (v > best) best = v;
        }
      }
      out[y * size + x] = best;
    }
  }
  return out;
}

/** Two box blurs, which is close enough to a gaussian for a shadow. */
function blur(alpha, size, radius) {
  const r = Math.max(1, Math.round(radius));
  let from = alpha;
  for (let pass = 0; pass < 2; pass++) {
    for (const [dx, dy] of [[1, 0], [0, 1]]) {
      const to = new Float32Array(size * size);
      for (let y = 0; y < size; y++) {
        for (let x = 0; x < size; x++) {
          let sum = 0;
          for (let k = -r; k <= r; k++) {
            const sx = x + k * dx, sy = y + k * dy;
            if (sx >= 0 && sx < size && sy >= 0 && sy < size) sum += from[sy * size + sx];
          }
          to[y * size + x] = sum / (2 * r + 1);
        }
      }
      from = to;
    }
  }
  return from;
}

// ---- the tile --------------------------------------------------------------

function roundedRect(px, py, x0, y0, x1, y1, r) {
  const cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
  const qx = Math.abs(px - cx) - (x1 - x0) / 2 + r;
  const qy = Math.abs(py - cy) - (y1 - y0) / 2 + r;
  return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - r;
}

const INDIGO = hex('#1E2A78');
const BLUE = hex('#2F6BFF');
const CYAN = hex('#22D3EE');
const GREY_A = hex('#3F4758');
const GREY_B = hex('#7B8496');
const GREEN = hex('#26D07C');
const SHADOW = [4, 8, 26];

/**
 * Colour and coverage of the tile at one sample point (x, y in 0..1). `aa`
 * is the width of the anti-aliasing band in canvas units.
 */
function tile(x, y, aa, o) {
  const t = clamp((x * 0.55 + y * 0.75) / 1.3);
  let rgb = o.background === 'grey'
    ? mix(GREY_A, GREY_B, t)
    : (t < 0.5 ? mix(INDIGO, BLUE, t * 2) : mix(BLUE, CYAN, (t - 0.5) * 2));
  // A soft light behind the cat and a darker rim for depth.
  const glow = clamp(1 - Math.hypot(x - 0.5, y - 0.44) / 0.52);
  rgb = mix(rgb, [255, 255, 255], 0.26 * glow * glow);
  const rim = clamp((Math.hypot(x - 0.5, y - 0.5) - 0.42) / 0.3);
  rgb = mix(rgb, [8, 12, 34], 0.34 * rim);
  // Glossy band across the top.
  const gloss = clamp(1 - Math.abs(y - 0.1 - 0.18 * (x - 0.5) ** 2) / 0.16);
  rgb = mix(rgb, [255, 255, 255], 0.1 * gloss);
  const a = o.tile ? clamp(0.5 - roundedRect(x, y, 0, 0, 1, 1, 0.225) / aa) : 1;
  return [rgb[0], rgb[1], rgb[2], a];
}

/**
 * Renders one icon as straight RGBA.
 *   background: 'brand' | 'grey' | 'none'
 *   tile: clip the background to a rounded square
 *   view: which part of the cat to draw; false leaves it out
 *   dot: the green "connected" badge
 */
function render(size, options = {}) {
  const o = { background: 'brand', tile: true, view: VIEW_TILE, ...options };
  const ss = size <= 48 ? 4 : size <= 128 ? 3 : 2;
  const n = size * ss;
  const aa = 1.2 / n;

  let cat = null, outline = null, shadow = null, drop = 0;
  if (o.view) {
    const scale = size / o.view.size;
    cat = drawMascot(size, o.view);
    const alpha = Float32Array.from({ length: size * size }, (_, i) => cat[i * 4 + 3]);
    // Never thinner than a pixel, or small icons lose the cat in the tile.
    outline = grow(alpha, size, Math.max(OUTLINE * scale, 0.8));
    shadow = blur(outline, size, SHADOW_BLUR * scale);
    drop = Math.round(SHADOW_DROP * scale);
  }

  const buf = Buffer.alloc(size * size * 4);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      // The backdrop, supersampled so the tile's corners stay crisp.
      let rgb = [0, 0, 0], a = 0;
      if (o.background !== 'none') {
        let r = 0, g = 0, b = 0;
        for (let sy = 0; sy < ss; sy++) {
          for (let sx = 0; sx < ss; sx++) {
            const [cr, cg, cb, ca] = tile((x * ss + sx + 0.5) / n, (y * ss + sy + 0.5) / n, aa, o);
            // Premultiplied accumulation avoids dark fringes at the edges.
            r += cr * ca; g += cg * ca; b += cb * ca; a += ca;
          }
        }
        if (a > 0) rgb = [r / a, g / a, b / a];
        a /= ss * ss;
      }

      if (cat) {
        const i = y * size + x;
        // Shadow, sticker outline, cat: each laid over what is below it.
        const layers = [
          [SHADOW, 0.42 * (y >= drop ? shadow[i - drop * size] : 0)],
          [[255, 255, 255], outline[i]],
        ];
        // Without a backdrop the layers themselves make up the coverage.
        let cover = o.background === 'none' ? 0 : 1;
        for (const [colour, alpha] of layers) {
          if (alpha <= 0) continue;
          const under = cover * (1 - alpha);
          rgb = rgb.map((v, c) => (v * under + colour[c] * alpha) / (under + alpha));
          cover = under + alpha;
        }
        const ca = cat[i * 4 + 3];
        if (ca > 0) {
          const under = cover * (1 - ca);
          rgb = rgb.map((v, c) => (v * under + cat[i * 4 + c] * 255) / (under + ca));
          cover = under + ca;
        }
        if (o.background === 'none') a = cover;
      }

      if (o.dot) {
        const d = Math.hypot((x + 0.5) / size - 0.775, (y + 0.5) / size - 0.775);
        const band = 1.2 / size;
        const ring = clamp(0.5 - (d - 0.235) / band);
        if (ring > 0) { rgb = mix(rgb, [255, 255, 255], ring); a = Math.max(a, ring); }
        const fill = clamp(0.5 - (d - 0.18) / band);
        if (fill > 0) rgb = mix(rgb, GREEN, fill);
      }

      const p = (y * size + x) * 4;
      buf[p] = Math.round(clamp(rgb[0], 0, 255));
      buf[p + 1] = Math.round(clamp(rgb[1], 0, 255));
      buf[p + 2] = Math.round(clamp(rgb[2], 0, 255));
      buf[p + 3] = Math.round(clamp(a) * 255);
    }
  }
  return buf;
}

// ---- file formats ----------------------------------------------------------

function png(size, rgba) {
  const chunk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(zlib.crc32(body) >>> 0);
    return Buffer.concat([len, body, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  const raw = Buffer.alloc((size * 4 + 1) * size);
  for (let y = 0; y < size; y++) {
    rgba.copy(raw, y * (size * 4 + 1) + 1, y * size * 4, (y + 1) * size * 4);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

/** A classic 32-bit DIB icon image: BGRA bottom-up plus an AND mask. */
function dib(size, rgba) {
  const header = Buffer.alloc(40);
  header.writeUInt32LE(40, 0);
  header.writeInt32LE(size, 4);
  header.writeInt32LE(size * 2, 8); // colour + mask
  header.writeUInt16LE(1, 12);
  header.writeUInt16LE(32, 14);
  const pixels = Buffer.alloc(size * size * 4);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const s = ((size - 1 - y) * size + x) * 4, d = (y * size + x) * 4;
      pixels[d] = rgba[s + 2];
      pixels[d + 1] = rgba[s + 1];
      pixels[d + 2] = rgba[s];
      pixels[d + 3] = rgba[s + 3];
    }
  }
  const maskRow = Math.ceil(size / 32) * 4;
  return Buffer.concat([header, pixels, Buffer.alloc(maskRow * size)]);
}

/** `options` may be a function of the size, for a view that depends on it. */
function ico(sizes, options) {
  const images = sizes.map((size) => {
    const rgba = render(size, typeof options === 'function' ? options(size) : options);
    // 256px entries are stored as PNG; smaller ones as DIB for old loaders.
    return { size, data: size >= 256 ? png(size, rgba) : dib(size, rgba) };
  });
  const dir = Buffer.alloc(6 + 16 * images.length);
  dir.writeUInt16LE(1, 2);
  dir.writeUInt16LE(images.length, 4);
  let offset = dir.length;
  images.forEach(({ size, data }, i) => {
    const e = 6 + i * 16;
    dir[e] = size >= 256 ? 0 : size;
    dir[e + 1] = size >= 256 ? 0 : size;
    dir.writeUInt16LE(1, e + 4);
    dir.writeUInt16LE(32, e + 6);
    dir.writeUInt32LE(data.length, e + 8);
    dir.writeUInt32LE(offset, e + 12);
    offset += data.length;
  });
  return Buffer.concat([dir, ...images.map((i) => i.data)]);
}

function write(path, data) {
  const full = join(root, path);
  mkdirSync(dirname(full), { recursive: true });
  writeFileSync(full, data);
  console.log(`${path}  (${data.length} bytes)`);
}

// Windows: executable icon and the two tray states. Up to 32 px, and in the
// tray always, the icon is the cat's head: every pixel of it counts there.
write('windows/runner/resources/app_icon.ico',
  ico([16, 24, 32, 48, 64, 128, 256], (size) => (size <= 32 ? { view: VIEW_HEAD } : {})));
write('assets/icons/tray_off.ico',
  ico([16, 20, 24, 32, 48], { background: 'grey', view: VIEW_HEAD }));
write('assets/icons/tray_on.ico', ico([16, 20, 24, 32, 48], { view: VIEW_HEAD, dot: true }));
write('assets/icons/app.png', png(256, render(256)));
write('docs/icon.png', png(512, render(512)));
// The cat alone, for places that bring their own background.
write('assets/icons/mascot.png', png(256, render(256, { background: 'none', view: VIEW_ALONE })));

// Android: legacy launcher icons plus the adaptive icon layers.
const densities = { mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 };
for (const [name, scale] of Object.entries(densities)) {
  const res = `android/app/src/main/res/mipmap-${name}`;
  const legacy = Math.round(48 * scale);
  const adaptive = Math.round(108 * scale);
  write(`${res}/ic_launcher.png`, png(legacy, render(legacy)));
  write(`${res}/ic_launcher_background.png`,
    png(adaptive, render(adaptive, { tile: false, view: false })));
  write(`${res}/ic_launcher_foreground.png`,
    png(adaptive, render(adaptive, { background: 'none', view: VIEW_ADAPTIVE })));
}
