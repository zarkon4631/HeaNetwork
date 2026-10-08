// Draws the app icon procedurally and writes every size the platforms need.
// No dependencies:  node tool/gen_icons.mjs
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import zlib from 'node:zlib';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

const clamp = (v) => Math.max(0, Math.min(1, v));
const mix = (a, b, t) => a.map((x, i) => x + (b[i] - x) * t);

/** Signed distance to a rounded rectangle, in the same units as its args. */
function roundedRect(px, py, x0, y0, x1, y1, r) {
  const cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
  const qx = Math.abs(px - cx) - (x1 - x0) / 2 + r;
  const qy = Math.abs(py - cy) - (y1 - y0) / 2 + r;
  return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - r;
}

const BLUE = [47, 107, 255];
const TEAL = [34, 193, 195];
const GREY_A = [108, 117, 134];
const GREY_B = [142, 150, 165];
const GREEN = [38, 201, 113];

/**
 * Renders the icon into an RGBA buffer.
 *   background: 'brand' | 'grey' | 'none'
 *   glyph: scale of the "H" relative to the canvas (1 = launcher size)
 *   tile: draw the rounded tile (false = full-bleed square)
 *   dot: add the green "connected" dot
 */
function render(size, { background = 'brand', glyph = 1, tile = true, dot = false } = {}) {
  const buf = Buffer.alloc(size * size * 4);
  const aa = (d) => clamp(0.5 - d); // distance in pixels -> coverage
  const g = (v) => (0.5 + (v - 0.5) * glyph) * size; // glyph coords around centre

  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const px = x + 0.5, py = y + 0.5;
      let rgb = [0, 0, 0], a = 0;

      if (background !== 'none') {
        const t = clamp((px + py) / (2 * size));
        rgb = background === 'grey' ? mix(GREY_A, GREY_B, t) : mix(BLUE, TEAL, t);
        a = tile ? aa(roundedRect(px, py, 0, 0, size, size, size * 0.225)) : 1;
      }

      // The letter H: two posts and a crossbar.
      const r = 0.035 * glyph * size;
      const h = Math.min(
        roundedRect(px, py, g(0.285), g(0.25), g(0.415), g(0.75), r),
        roundedRect(px, py, g(0.585), g(0.25), g(0.715), g(0.75), r),
        roundedRect(px, py, g(0.36), g(0.44), g(0.64), g(0.56), r * 0.6),
      );
      const ha = aa(h);
      if (ha > 0) {
        rgb = mix(rgb, [255, 255, 255], ha);
        a = Math.max(a, ha);
      }

      if (dot) {
        const cx = size * 0.77, cy = size * 0.77;
        const d = Math.hypot(px - cx, py - cy);
        const ring = aa(d - size * 0.23);
        if (ring > 0) rgb = mix(rgb, [255, 255, 255], ring);
        const fill = aa(d - size * 0.175);
        if (fill > 0) rgb = mix(rgb, GREEN, fill);
        a = Math.max(a, ring);
      }

      const i = (y * size + x) * 4;
      buf[i] = Math.round(rgb[0]);
      buf[i + 1] = Math.round(rgb[1]);
      buf[i + 2] = Math.round(rgb[2]);
      buf[i + 3] = Math.round(a * 255);
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

// Windows: executable icon and the two tray states.
write('windows/runner/resources/app_icon.ico', ico([16, 24, 32, 48, 64, 128, 256]));
write('assets/icons/tray_off.ico', ico([16, 20, 24, 32, 48], { background: 'grey' }));
write('assets/icons/tray_on.ico', ico([16, 20, 24, 32, 48], { dot: true }));
write('assets/icons/app.png', png(256, render(256)));

// Android: legacy launcher icons plus the adaptive icon layers. The
// adaptive canvas is 108dp with a 66dp safe zone, hence the smaller glyph.
const densities = { mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 };
for (const [name, scale] of Object.entries(densities)) {
  const res = `android/app/src/main/res/mipmap-${name}`;
  const legacy = Math.round(48 * scale);
  const adaptive = Math.round(108 * scale);
  write(`${res}/ic_launcher.png`, png(legacy, render(legacy)));
  write(`${res}/ic_launcher_background.png`,
    png(adaptive, render(adaptive, { tile: false, glyph: 0 })));
  write(`${res}/ic_launcher_foreground.png`,
    png(adaptive, render(adaptive, { background: 'none', glyph: 0.58 })));
}
