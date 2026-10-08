// Draws the app icon — a penguin on a glowing gradient tile — procedurally
// and writes every size the platforms need. No dependencies:
//   node tool/gen_icons.mjs
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import zlib from 'node:zlib';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

const clamp = (v, lo = 0, hi = 1) => Math.max(lo, Math.min(hi, v));
const mix = (a, b, t) => a.map((x, i) => x + (b[i] - x) * t);
const hex = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));

// ---- shapes: signed distance in canvas units (the canvas is 1 x 1) --------

function ellipse(px, py, cx, cy, rx, ry, angle = 0) {
  let x = px - cx, y = py - cy;
  if (angle) {
    const c = Math.cos(-angle), s = Math.sin(-angle);
    [x, y] = [x * c - y * s, x * s + y * c];
  }
  // Exact enough for anti-aliasing: scale the implicit function back.
  const k = Math.hypot(x / rx, y / ry);
  return (k - 1) * Math.min(rx, ry);
}

function roundedRect(px, py, x0, y0, x1, y1, r) {
  const cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
  const qx = Math.abs(px - cx) - (x1 - x0) / 2 + r;
  const qy = Math.abs(py - cy) - (y1 - y0) / 2 + r;
  return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - r;
}

/** Smooth union, so head and body melt into one silhouette. */
function smin(a, b, k) {
  const h = clamp(0.5 + (0.5 * (b - a)) / k);
  return b + (a - b) * h - k * h * (1 - h);
}

// ---- palette --------------------------------------------------------------

const INDIGO = hex('#1E2A78');
const BLUE = hex('#2F6BFF');
const CYAN = hex('#22D3EE');
const GREY_A = hex('#3F4758');
const GREY_B = hex('#7B8496');
const INK = hex('#0B1020');
const INK_HI = hex('#273352');
const WHITE = hex('#FBFCFF');
const SHADE = hex('#D3DEF2');
const ORANGE = hex('#FF9F2E');
const ORANGE_LO = hex('#F2710C');
const GREEN = hex('#26D07C');

/**
 * Colour of one sample point (x, y in 0..1). `aa` is the width of the
 * anti-aliasing band in canvas units.
 *   background: 'brand' | 'grey' | 'none'
 *   tile: clip the background to a rounded square
 *   penguin: draw the bird; `scale` enlarges it around the canvas centre
 *   dot: the green "connected" badge
 */
function shade(x, y, aa, o) {
  const cov = (d) => clamp(0.5 - d / aa);
  let rgb = [0, 0, 0], a = 0;

  if (o.background !== 'none') {
    const t = clamp((x * 0.55 + y * 0.75) / 1.3);
    rgb = o.background === 'grey'
      ? mix(GREY_A, GREY_B, t)
      : (t < 0.5 ? mix(INDIGO, BLUE, t * 2) : mix(BLUE, CYAN, (t - 0.5) * 2));
    // A soft light behind the bird and a darker rim for depth.
    const glow = clamp(1 - Math.hypot(x - 0.5, y - 0.44) / 0.52);
    rgb = mix(rgb, [255, 255, 255], 0.26 * glow * glow);
    const rim = clamp((Math.hypot(x - 0.5, y - 0.5) - 0.42) / 0.3);
    rgb = mix(rgb, [8, 12, 34], 0.34 * rim);
    // Glossy band across the top.
    const gloss = clamp(1 - Math.abs(y - 0.1 - 0.18 * (x - 0.5) ** 2) / 0.16);
    rgb = mix(rgb, [255, 255, 255], 0.1 * gloss);
    a = o.tile ? cov(roundedRect(x, y, 0, 0, 1, 1, 0.225)) : 1;
  }

  if (o.penguin !== false) {
    const s = o.scale ?? 1;
    const px = 0.5 + (x - 0.5) / s, py = 0.5 + (y - 0.5) / s;
    const band = aa / s;
    const c = (d) => clamp(0.5 - d / band);
    const paint = (colour, alpha) => {
      if (alpha <= 0) return;
      rgb = mix(rgb, colour, alpha);
      a = Math.max(a, alpha);
    };

    // Ground shadow: a soft blob that only darkens the tile, never the
    // transparent area around it.
    if (o.background !== 'none') {
      const k = Math.hypot((px - 0.5) / 0.24, (py - 0.9) / 0.034);
      rgb = mix(rgb, [4, 8, 26], 0.42 * clamp(1 - k) ** 1.5);
    }

    // Feet, behind the body.
    for (const fx of [0.415, 0.585]) {
      paint(mix(ORANGE, ORANGE_LO, clamp((py - 0.83) / 0.06)),
        c(ellipse(px, py, fx, 0.862, 0.072, 0.03)));
    }

    // Wings, then head + body as one silhouette.
    const wingL = ellipse(px, py, 0.288, 0.585, 0.052, 0.158, -0.24);
    const wingR = ellipse(px, py, 0.712, 0.585, 0.052, 0.158, 0.24);
    const head = ellipse(px, py, 0.5, 0.325, 0.168, 0.16);
    const body = ellipse(px, py, 0.5, 0.575, 0.232, 0.292);
    const silhouette = Math.min(smin(head, body, 0.07), wingL, wingR);
    const light = clamp(1 - Math.hypot(px - 0.4, py - 0.26) / 0.42);
    paint(mix(INK, INK_HI, 0.75 * light), c(silhouette));

    // Belly and face mask.
    const belly = ellipse(px, py, 0.5, 0.622, 0.158, 0.224);
    const face = Math.min(
      ellipse(px, py, 0.452, 0.345, 0.066, 0.07),
      ellipse(px, py, 0.548, 0.345, 0.066, 0.07),
    );
    const front = smin(belly, face, 0.04);
    paint(mix(WHITE, SHADE, clamp((py - 0.42) / 0.5)), c(front));

    // Eyes with a glint.
    for (const ex of [0.456, 0.544]) {
      paint(INK, c(ellipse(px, py, ex, 0.338, 0.0235, 0.027)));
      paint(WHITE, c(ellipse(px, py, ex + 0.008, 0.329, 0.0075, 0.0075)));
    }

    // Beak.
    paint(mix(ORANGE, ORANGE_LO, clamp((py - 0.385) / 0.05)),
      c(ellipse(px, py, 0.5, 0.404, 0.05, 0.029)));
  }

  if (o.dot) {
    const d = Math.hypot(x - 0.775, y - 0.775);
    const ring = cov(d - 0.235);
    if (ring > 0) { rgb = mix(rgb, [255, 255, 255], ring); a = Math.max(a, ring); }
    const fill = cov(d - 0.18);
    if (fill > 0) rgb = mix(rgb, GREEN, fill);
  }
  return [rgb[0], rgb[1], rgb[2], a];
}

/** Renders an RGBA buffer, supersampled so small sizes stay crisp. */
function render(size, options = {}) {
  const o = { background: 'brand', tile: true, ...options };
  const ss = size <= 48 ? 4 : size <= 128 ? 3 : 2;
  const n = size * ss;
  const aa = 1.2 / n;
  const buf = Buffer.alloc(size * size * 4);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let r = 0, g = 0, b = 0, a = 0;
      for (let sy = 0; sy < ss; sy++) {
        for (let sx = 0; sx < ss; sx++) {
          const [cr, cg, cb, ca] = shade((x * ss + sx + 0.5) / n, (y * ss + sy + 0.5) / n, aa, o);
          // Premultiplied accumulation avoids dark fringes at the edges.
          r += cr * ca; g += cg * ca; b += cb * ca; a += ca;
        }
      }
      const i = (y * size + x) * 4;
      if (a > 0) {
        buf[i] = Math.round(r / a);
        buf[i + 1] = Math.round(g / a);
        buf[i + 2] = Math.round(b / a);
      }
      buf[i + 3] = Math.round((a / (ss * ss)) * 255);
    }
  }
  return buf;
}

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

function ico(sizes, options) {
  const images = sizes.map((size) => {
    const rgba = render(size, options);
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

// Windows: executable icon and the two tray states. In the tray the bird is
// drawn a little larger: at 16 px every pixel of it counts.
write('windows/runner/resources/app_icon.ico', ico([16, 24, 32, 48, 64, 128, 256]));
write('assets/icons/tray_off.ico', ico([16, 20, 24, 32, 48], { background: 'grey', scale: 1.14 }));
write('assets/icons/tray_on.ico', ico([16, 20, 24, 32, 48], { scale: 1.14, dot: true }));
write('assets/icons/app.png', png(256, render(256)));
write('docs/icon.png', png(512, render(512)));
// The bird alone, for places that bring their own background.
write('assets/icons/penguin.png', png(256, render(256, { background: 'none', scale: 1.12 })));

// Android: legacy launcher icons plus the adaptive icon layers. The
// adaptive canvas is 108dp with a 66dp safe zone, hence the smaller bird.
const densities = { mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 };
for (const [name, scale] of Object.entries(densities)) {
  const res = `android/app/src/main/res/mipmap-${name}`;
  const legacy = Math.round(48 * scale);
  const adaptive = Math.round(108 * scale);
  write(`${res}/ic_launcher.png`, png(legacy, render(legacy)));
  write(`${res}/ic_launcher_background.png`,
    png(adaptive, render(adaptive, { tile: false, penguin: false })));
  write(`${res}/ic_launcher_foreground.png`,
    png(adaptive, render(adaptive, { background: 'none', scale: 0.62 })));
}
