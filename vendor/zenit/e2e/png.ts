/// png.ts, minimal PNG decoder (8-bit RGB/RGBA, non-interlaced), for e2e pixel-level assertions.
/// Only depends on Bun.inflateSync; harness screenshots fixed to this format.
import { readFileSync, writeFileSync } from "node:fs";
import { inflateSync, deflateSync } from "node:zlib";

export interface DecodedPng {
  width: number;
  height: number;
  channels: number; // 3 (RGB) or 4 (RGBA)
  pixels: Uint8Array; // width*height*channels, row-major
}

export function decodePng(path: string): DecodedPng {
  const buf = readFileSync(path);
  if (buf.readUInt32BE(0) !== 0x89504e47) throw new Error(`${path}: 非 PNG`);
  let off = 8;
  let width = 0, height = 0, bitDepth = 0, colorType = 0;
  const idat: Uint8Array[] = [];
  while (off < buf.length) {
    const len = buf.readUInt32BE(off);
    const type = buf.toString("ascii", off + 4, off + 8);
    const data = buf.subarray(off + 8, off + 8 + len);
    if (type === "IHDR") {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      bitDepth = data[8];
      colorType = data[9];
      if (data[12] !== 0) throw new Error("不支持交错 PNG");
      if (bitDepth !== 8) throw new Error(`不支持 bitDepth=${bitDepth}`);
      if (colorType !== 2 && colorType !== 6) throw new Error(`不支持 colorType=${colorType}`);
    } else if (type === "IDAT") {
      idat.push(data);
    } else if (type === "IEND") break;
    off += 12 + len;
  }
  const channels = colorType === 6 ? 4 : 3;
  const compressed = Buffer.concat(idat);
  const raw = inflateSync(compressed);
  const stride = width * channels;
  const pixels = new Uint8Array(width * height * channels);
  // unfilter
  let ri = 0;
  for (let y = 0; y < height; y++) {
    const filter = raw[ri++];
    const row = pixels.subarray(y * stride, (y + 1) * stride);
    const prev = y > 0 ? pixels.subarray((y - 1) * stride, y * stride) : null;
    for (let x = 0; x < stride; x++) {
      const rawByte = raw[ri + x];
      const a = x >= channels ? row[x - channels] : 0;
      const b = prev ? prev[x] : 0;
      const c = x >= channels && prev ? prev[x - channels] : 0;
      let v: number;
      switch (filter) {
        case 0: v = rawByte; break;
        case 1: v = rawByte + a; break;
        case 2: v = rawByte + b; break;
        case 3: v = rawByte + ((a + b) >> 1); break;
        case 4: {
          const p = a + b - c;
          const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
          const pred = pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
          v = rawByte + pred;
          break;
        }
        default: throw new Error(`未知 filter ${filter}`);
      }
      row[x] = v & 0xff;
    }
    ri += stride;
  }
  return { width, height, channels, pixels };
}

/// Count pixels below brightness threshold in rect area (dark text/graphics pixels). rect is
/// logical coords, scale is screenshot physical/logical ratio (default auto-infer by png width /
/// logicalWidth).
export function countDarkPixels(
  png: DecodedPng,
  rect: { x: number; y: number; w: number; h: number },
  scale: number,
  threshold = 100,
): number {
  const x0 = Math.max(0, Math.round(rect.x * scale));
  const y0 = Math.max(0, Math.round(rect.y * scale));
  const x1 = Math.min(png.width, Math.round((rect.x + rect.w) * scale));
  const y1 = Math.min(png.height, Math.round((rect.y + rect.h) * scale));
  let count = 0;
  for (let y = y0; y < y1; y++) {
    for (let x = x0; x < x1; x++) {
      const i = (y * png.width + x) * png.channels;
      const lum = 0.299 * png.pixels[i] + 0.587 * png.pixels[i + 1] + 0.114 * png.pixels[i + 2];
      if (lum < threshold) count++;
    }
  }
  return count;
}

/// Count pixels differing from the background color in a region.
///
/// `countDarkPixels` (threshold=100, near-black) only fits dark text. Light graphics (spinner fine
/// rings, light-gray skeleton placeholders) render with only single-digit dark pixels, so a dark
/// criterion mistakes 'drawn correctly' for 'pixels empty'.
///
/// This function asks 'is this area pure background': pixels whose brightness delta from the
/// background exceeds `minDelta` count. It catches both missing dark text and missing light
/// graphics, at the cost of estimating the background (median of four corner brightnesses, see
/// below).
export function countNonBackgroundPixels(
  png: DecodedPng,
  rect: { x: number; y: number; w: number; h: number },
  scale: number,
  minDelta = 8,
): number {
  const x0 = Math.max(0, Math.round(rect.x * scale));
  const y0 = Math.max(0, Math.round(rect.y * scale));
  const x1 = Math.min(png.width, Math.round((rect.x + rect.w) * scale));
  const y1 = Math.min(png.height, Math.round((rect.y + rect.h) * scale));
  if (x1 <= x0 || y1 <= y0) return 0;

  const lumAt = (x: number, y: number): number => {
    const i = (y * png.width + x) * png.channels;
    return 0.299 * png.pixels[i] + 0.587 * png.pixels[i + 1] + 0.114 * png.pixels[i + 2];
  };

  // Background from four corners median: probability of corners landing on graphics far lower than
  // background, median also tolerates one-two corners hit by graphics.
  const corners = [
    lumAt(x0, y0),
    lumAt(x1 - 1, y0),
    lumAt(x0, y1 - 1),
    lumAt(x1 - 1, y1 - 1),
  ].sort((a, b) => a - b);
  const bg = (corners[1] + corners[2]) / 2;

  let count = 0;
  for (let y = y0; y < y1; y++) {
    for (let x = x0; x < x1; x++) {
      if (Math.abs(lumAt(x, y) - bg) >= minDelta) count++;
    }
  }
  return count;
}

export function writeRgbPng(path: string, width: number, height: number, pixels: Uint8Array) {
  const crc32 = (bytes: Uint8Array) => {
    let crc = 0xffffffff;
    for (const byte of bytes) { crc ^= byte; for (let i=0;i<8;i++) crc=(crc>>>1)^((crc&1)?0xedb88320:0); }
    return (crc ^ 0xffffffff) >>> 0;
  };
  const chunk = (type: string, data: Uint8Array) => {
    const b=Buffer.alloc(data.length+12); b.writeUInt32BE(data.length);b.write(type,4);b.set(data,8);b.writeUInt32BE(crc32(b.subarray(4,-4)),b.length-4);return b;
  };
  const header=Buffer.alloc(13);header.writeUInt32BE(width);header.writeUInt32BE(height,4);header[8]=8;header[9]=2;
  const raw=Buffer.alloc(height*(width*3+1));
  for(let y=0;y<height;y++) raw.set(pixels.subarray(y*width*3,(y+1)*width*3),y*(width*3+1)+1);
  writeFileSync(path,Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk("IHDR",header),chunk("IDAT",deflateSync(raw)),chunk("IEND",new Uint8Array())]));
}
