/**
 * design_diff.ts: structured pixel comparison design vs implementation.
 *
 * After changes run `--self-test` (6 test cases).
 *
 * Workflow vs `golden_compare.ts` (don't mix):
 *   - golden_compare: regression gate. Same-size baseline, unequal size throws, gives two global scalars only.
 *   - design_diff (this file): recovery aid. **Sizes naturally differ** (design export 2x vs app screenshot),
 *     auto-aligns sizes, outputs "where differs, how much, which direction", lets AI fix without reading image.
 *
 * Design goal: output must directly drive next fix. So give more than scores:
 *   - grid heatmap: which block differs (8x8 grid + ASCII viz)
 *   - edge projection diff: row/col content boundary offset -> maps directly to padding/gap/position errors
 *   - color diff: palette comparison -> maps directly to wrong token usage
 *
 * Usage:
 *   bun e2e/design_diff.ts DESIGN.png ACTUAL.png [--json] [--grid N] [--top N]
 *   bun e2e/design_diff.ts --self-test
 */
import { existsSync } from "node:fs";
import { decodePng, type DecodedPng } from "./png";

// ── Basic tools ──

/**
 * Composite alpha image onto opaque background.
 *
 * This step is mandatory, not optional: pencil `export_nodes` export component PNG
 * typically has transparent background, transparent pixel RGB often (0,0,0). Comparing RGB directly,
 * design treated as "black bg" while app screenshot white bg, result ~99% pixel diff + RMSE 250 false alarm,
 * yet images look nearly identical to human eye. Hit this pit in practice, self-test below catches it.
 */
export function flattenOnto(png: DecodedPng, matte: [number, number, number]): DecodedPng {
  if (png.channels < 4) return png;
  const out = new Uint8Array(png.width * png.height * 3);
  for (let i = 0; i < png.width * png.height; i++) {
    const a = png.pixels[i * 4 + 3] / 255;
    for (let c = 0; c < 3; c++) {
      out[i * 3 + c] = Math.round(png.pixels[i * 4 + c] * a + matte[c] * (1 - a));
    }
  }
  return { width: png.width, height: png.height, channels: 3, pixels: out };
}

/** Bilinear resample to target size. Design export often 2x, screenshot Retina 2x, sizes may differ. */
export function resample(src: DecodedPng, width: number, height: number): DecodedPng {
  if (src.width === width && src.height === height) return src;
  const out = new Uint8Array(width * height * 3);
  const xRatio = src.width / width;
  const yRatio = src.height / height;
  for (let y = 0; y < height; y++) {
    const sy = Math.min(src.height - 1, (y + 0.5) * yRatio - 0.5);
    const y0 = Math.max(0, Math.floor(sy));
    const y1 = Math.min(src.height - 1, y0 + 1);
    const fy = sy - y0;
    for (let x = 0; x < width; x++) {
      const sx = Math.min(src.width - 1, (x + 0.5) * xRatio - 0.5);
      const x0 = Math.max(0, Math.floor(sx));
      const x1 = Math.min(src.width - 1, x0 + 1);
      const fx = sx - x0;
      for (let c = 0; c < 3; c++) {
        const p00 = src.pixels[(y0 * src.width + x0) * src.channels + c];
        const p01 = src.pixels[(y0 * src.width + x1) * src.channels + c];
        const p10 = src.pixels[(y1 * src.width + x0) * src.channels + c];
        const p11 = src.pixels[(y1 * src.width + x1) * src.channels + c];
        const top = p00 + (p01 - p00) * fx;
        const bot = p10 + (p11 - p10) * fx;
        out[(y * width + x) * 3 + c] = Math.round(top + (bot - top) * fy);
      }
    }
  }
  return { width, height, channels: 3, pixels: out };
}

function luma(png: DecodedPng, idx: number): number {
  const o = idx * png.channels;
  return 0.299 * png.pixels[o] + 0.587 * png.pixels[o + 1] + 0.114 * png.pixels[o + 2];
}

// ── 1. Grid heatmap: locate diff to blocks ──

export interface GridCell {
  row: number;
  col: number;
  /** Avg channel diff (0-255) for this cell */
  delta: number;
  /** This cell exceeded-threshold pixel ratio */
  changedRatio: number;
}

export function gridDiff(a: DecodedPng, b: DecodedPng, grid: number, threshold: number): GridCell[] {
  const cells: GridCell[] = [];
  const cellW = a.width / grid;
  const cellH = a.height / grid;
  for (let row = 0; row < grid; row++) {
    for (let col = 0; col < grid; col++) {
      const x0 = Math.floor(col * cellW), x1 = Math.floor((col + 1) * cellW);
      const y0 = Math.floor(row * cellH), y1 = Math.floor((row + 1) * cellH);
      let sum = 0, changed = 0, count = 0;
      for (let y = y0; y < y1; y++) {
        for (let x = x0; x < x1; x++) {
          const i = y * a.width + x;
          let maxDelta = 0;
          for (let c = 0; c < 3; c++) {
            const d = Math.abs(a.pixels[i * a.channels + c] - b.pixels[i * b.channels + c]);
            sum += d;
            if (d > maxDelta) maxDelta = d;
          }
          if (maxDelta > threshold) changed++;
          count++;
        }
      }
      if (count === 0) continue;
      cells.push({ row, col, delta: sum / (count * 3), changedRatio: changed / count });
    }
  }
  return cells;
}

/** ASCII heatmap. space=match, larger digits=more diff, # worst. */
export function renderHeatmap(cells: GridCell[], grid: number): string {
  const rows: string[] = [];
  for (let r = 0; r < grid; r++) {
    let line = "";
    for (let c = 0; c < grid; c++) {
      const cell = cells.find((x) => x.row === r && x.col === c);
      const v = cell ? cell.changedRatio : 0;
      line += v === 0 ? " ·" : v < 0.05 ? " 1" : v < 0.15 ? " 2" : v < 0.3 ? " 4"
        : v < 0.5 ? " 6" : v < 0.75 ? " 8" : " #";
    }
    rows.push(line);
  }
  return rows.join("\n");
}

// ── 2. Edge projection: translate diff into 'pixels offset' ──

/**
 * Content boundary projection. For each row/col compute "non-background pixel" count, yield content distribution curve.
 * Curve misalignment between images = layout offset, maps directly to padding/gap/margin errors.
 */
export function projection(png: DecodedPng, axis: "row" | "col", bgLuma: number): number[] {
  const n = axis === "row" ? png.height : png.width;
  const m = axis === "row" ? png.width : png.height;
  const out = new Array<number>(n).fill(0);
  for (let i = 0; i < n; i++) {
    let count = 0;
    for (let j = 0; j < m; j++) {
      const idx = axis === "row" ? i * png.width + j : j * png.width + i;
      if (Math.abs(luma(png, idx) - bgLuma) > 24) count++;
    }
    out[i] = count;
  }
  return out;
}

/** Estimate background brightness: median of corners and edge midpoints. */
export function estimateBackgroundLuma(png: DecodedPng): number {
  const pts = [
    [0, 0], [png.width - 1, 0], [0, png.height - 1], [png.width - 1, png.height - 1],
    [Math.floor(png.width / 2), 0], [0, Math.floor(png.height / 2)],
  ];
  const vals = pts.map(([x, y]) => luma(png, y * png.width + x)).sort((p, q) => p - q);
  return vals[Math.floor(vals.length / 2)];
}

/** Cross-correlation for best overall shift (±maxShift), return shift amount and residual at that shift. */
export function bestShift(a: number[], b: number[], maxShift: number): { shift: number; residual: number } {
  let best = { shift: 0, residual: Infinity };
  for (let s = -maxShift; s <= maxShift; s++) {
    let sum = 0, count = 0;
    for (let i = 0; i < a.length; i++) {
      const j = i + s;
      if (j < 0 || j >= b.length) continue;
      sum += Math.abs(a[i] - b[j]);
      count++;
    }
    if (count === 0) continue;
    const residual = sum / count;
    if (residual < best.residual) best = { shift: s, residual };
  }
  return best;
}

/** Content bounding box: first/last non-background rows/cols, for comparing overall size and position. */
export function contentBounds(proj: number[]): { start: number; end: number } {
  const peak = Math.max(...proj);
  const floor = Math.max(1, peak * 0.02);
  let start = proj.findIndex((v) => v > floor);
  let end = proj.length - 1 - [...proj].reverse().findIndex((v) => v > floor);
  if (start < 0) { start = 0; end = 0; }
  return { start, end };
}

// ── 3. Palette comparison: catch 'wrong color token' ──

export interface PaletteEntry { hex: string; ratio: number; }

/** Quantize to 5 bits/channel then tabulate dominant colors. */
export function palette(png: DecodedPng, topN: number): PaletteEntry[] {
  const hist = new Map<number, number>();
  const total = png.width * png.height;
  for (let i = 0; i < total; i++) {
    const o = i * png.channels;
    const key = ((png.pixels[o] >> 3) << 10) | ((png.pixels[o + 1] >> 3) << 5) | (png.pixels[o + 2] >> 3);
    hist.set(key, (hist.get(key) ?? 0) + 1);
  }
  return [...hist.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, topN)
    .map(([key, n]) => {
      const r = ((key >> 10) & 31) << 3, g = ((key >> 5) & 31) << 3, b = (key & 31) << 3;
      const hex = "#" + [r, g, b].map((v) => v.toString(16).padStart(2, "0")).join("");
      return { hex, ratio: n / total };
    });
}

function hexToRgb(hex: string): [number, number, number] {
  return [parseInt(hex.slice(1, 3), 16), parseInt(hex.slice(3, 5), 16), parseInt(hex.slice(5, 7), 16)];
}

/** Find closest color in implementation for each design primary. Large distance = wrong color. */
export function paletteDiff(design: PaletteEntry[], actual: PaletteEntry[]) {
  return design.map((d) => {
    const [dr, dg, db] = hexToRgb(d.hex);
    let best = { hex: "", dist: Infinity };
    for (const a of actual) {
      const [ar, ag, ab] = hexToRgb(a.hex);
      const dist = Math.sqrt((dr - ar) ** 2 + (dg - ag) ** 2 + (db - ab) ** 2);
      if (dist < best.dist) best = { hex: a.hex, dist };
    }
    return { design: d.hex, designRatio: d.ratio, nearestActual: best.hex, distance: best.dist };
  });
}

// ── Summary ──

export interface DiffReport {
  designSize: string;
  actualSize: string;
  comparedAt: string;
  changedRatio: number;
  rmse: number;
  score: number;
  heatmap: string;
  worstCells: GridCell[];
  offset: { x: number; y: number; xResidual: number; yResidual: number };
  bounds: {
    design: { x: [number, number]; y: [number, number] };
    actual: { x: [number, number]; y: [number, number] };
  };
  paletteIssues: ReturnType<typeof paletteDiff>;
  hints: string[];
}

export function compare(
  designPng: DecodedPng,
  actualPng: DecodedPng,
  opts: { grid: number; threshold: number; top: number; matte?: [number, number, number] },
): DiffReport {
  // Composite alpha to same background first, must be before resampling and any diff.
  const matte = opts.matte ?? [255, 255, 255];
  const designFlat = flattenOnto(designPng, matte);
  const actualFlat = flattenOnto(actualPng, matte);

  // Unify to implementation screenshot size (preserve implementation true resolution as coordinate
  // system).
  const w = actualFlat.width, h = actualFlat.height;
  const design = resample(designFlat, w, h);
  const actual = actualFlat;

  let squared = 0, changed = 0;
  const pixelCount = w * h;
  for (let i = 0; i < pixelCount; i++) {
    let pixelChanged = false;
    for (let c = 0; c < 3; c++) {
      const d = Math.abs(design.pixels[i * design.channels + c] - actual.pixels[i * actual.channels + c]);
      squared += d * d;
      if (d > opts.threshold) pixelChanged = true;
    }
    if (pixelChanged) changed++;
  }
  const changedRatio = changed / pixelCount;
  const rmse = Math.sqrt(squared / (pixelCount * 3));

  const cells = gridDiff(design, actual, opts.grid, opts.threshold);
  const worstCells = [...cells].sort((a, b) => b.changedRatio - a.changedRatio).slice(0, opts.top);

  const dBg = estimateBackgroundLuma(design);
  const aBg = estimateBackgroundLuma(actual);
  const dRow = projection(design, "row", dBg), aRow = projection(actual, "row", aBg);
  const dCol = projection(design, "col", dBg), aCol = projection(actual, "col", aBg);
  const maxShift = Math.max(4, Math.floor(Math.min(w, h) * 0.1));
  const yShift = bestShift(dRow, aRow, maxShift);
  const xShift = bestShift(dCol, aCol, maxShift);

  const dRowB = contentBounds(dRow), aRowB = contentBounds(aRow);
  const dColB = contentBounds(dCol), aColB = contentBounds(aCol);

  const paletteIssues = paletteDiff(palette(design, 6), palette(actual, 12))
    .filter((p) => p.distance > 24);

  // Translate numbers into actionable fix suggestions.
  const hints: string[] = [];
  if (Math.abs(xShift.shift) >= 2) {
    hints.push(`整体水平偏移 ${xShift.shift > 0 ? "右" : "左"} ${Math.abs(xShift.shift)}px — 检查左右 padding / margin / justify`);
  }
  if (Math.abs(yShift.shift) >= 2) {
    hints.push(`整体垂直偏移 ${yShift.shift > 0 ? "下" : "上"} ${Math.abs(yShift.shift)}px — 检查上下 padding / align_items`);
  }
  const dW = dColB.end - dColB.start, aW = aColB.end - aColB.start;
  const dH = dRowB.end - dRowB.start, aH = aRowB.end - aRowB.start;
  if (Math.abs(dW - aW) >= 3) {
    hints.push(`内容宽度差 ${aW - dW}px（设计 ${dW} vs 实现 ${aW}）— 检查 width/flex/gap`);
  }
  if (Math.abs(dH - aH) >= 3) {
    hints.push(`内容高度差 ${aH - dH}px（设计 ${dH} vs 实现 ${aH}）— 检查 height/行高/gap`);
  }
  for (const p of paletteIssues.slice(0, 3)) {
    hints.push(`颜色偏差: 设计 ${p.design}（占 ${(p.designRatio * 100).toFixed(1)}%）最近实现色 ${p.nearestActual}，距离 ${p.distance.toFixed(0)} — 检查 token 取值`);
  }
  if (hints.length === 0 && changedRatio > 0.02) {
    hints.push("无整体位移/尺寸/配色偏差，差异集中在局部 — 看 worstCells 定位区块（可能是字体、圆角、阴影或图标）");
  }

  // Score: changedRatio and rmse combined, 100 = perfect match.
  const score = Math.max(0, 100 - changedRatio * 100 * 0.7 - Math.min(30, rmse));

  return {
    designSize: `${designPng.width}x${designPng.height}`,
    actualSize: `${actualPng.width}x${actualPng.height}`,
    comparedAt: `${w}x${h}`,
    changedRatio, rmse, score,
    heatmap: renderHeatmap(cells, opts.grid),
    worstCells,
    offset: { x: xShift.shift, y: yShift.shift, xResidual: xShift.residual, yResidual: yShift.residual },
    bounds: {
      design: { x: [dColB.start, dColB.end], y: [dRowB.start, dRowB.end] },
      actual: { x: [aColB.start, aColB.end], y: [aRowB.start, aRowB.end] },
    },
    paletteIssues,
    hints,
  };
}

// ── Self-check ──

function selfTest(): void {
  const solid = (w: number, h: number, rgb: [number, number, number]): DecodedPng => {
    const pixels = new Uint8Array(w * h * 3);
    for (let i = 0; i < w * h; i++) {
      pixels[i * 3] = rgb[0]; pixels[i * 3 + 1] = rgb[1]; pixels[i * 3 + 2] = rgb[2];
    }
    return { width: w, height: h, channels: 3, pixels };
  };
  const withRect = (
    base: DecodedPng, x0: number, y0: number, rw: number, rh: number, rgb: [number, number, number],
  ): DecodedPng => {
    const out = { ...base, pixels: new Uint8Array(base.pixels) };
    for (let y = y0; y < y0 + rh; y++) {
      for (let x = x0; x < x0 + rw; x++) {
        if (x < 0 || y < 0 || x >= base.width || y >= base.height) continue;
        const i = (y * base.width + x) * 3;
        out.pixels[i] = rgb[0]; out.pixels[i + 1] = rgb[1]; out.pixels[i + 2] = rgb[2];
      }
    }
    return out;
  };

  // 1. Identical image -> full score, no hints
  const white = solid(64, 64, [255, 255, 255]);
  const a = withRect(white, 10, 10, 20, 20, [0, 0, 0]);
  const same = compare(a, a, { grid: 8, threshold: 8, top: 3 });
  if (same.changedRatio !== 0 || same.rmse !== 0) throw new Error("identical-image self-test failed");
  if (same.score !== 100) throw new Error(`identical score should be 100, got ${same.score}`);
  if (same.hints.length !== 0) throw new Error("identical image should yield no hints");

  // 2. Pure offset -> must report correct direction and magnitude
  const shifted = withRect(white, 16, 10, 20, 20, [0, 0, 0]);
  const shiftRep = compare(a, shifted, { grid: 8, threshold: 8, top: 3 });
  if (shiftRep.offset.x !== 6) throw new Error(`expected x offset 6, got ${shiftRep.offset.x}`);
  if (shiftRep.offset.y !== 0) throw new Error(`expected y offset 0, got ${shiftRep.offset.y}`);
  if (!shiftRep.hints.some((s) => s.includes("水平偏移"))) throw new Error("shift hint missing");

  // 3. Different sizes also compare (auto resample), no throw
  const big = solid(128, 128, [255, 255, 255]);
  const bigRect = withRect(big, 20, 20, 40, 40, [0, 0, 0]);
  const scaled = compare(bigRect, a, { grid: 8, threshold: 8, top: 3 });
  if (scaled.comparedAt !== "64x64") throw new Error("resample target should be actual size");
  if (scaled.changedRatio > 0.05) throw new Error(`2x-scaled identical content should match, got ${scaled.changedRatio}`);

  // 4. Color change -> must report palette issue
  const red = withRect(white, 10, 10, 20, 20, [220, 30, 30]);
  const colorRep = compare(a, red, { grid: 8, threshold: 8, top: 3 });
  if (colorRep.paletteIssues.length === 0) throw new Error("palette diff should flag a recolor");
  if (!colorRep.hints.some((s) => s.includes("颜色偏差"))) throw new Error("color hint missing");

  // 5. Content size diff -> must report width delta
  const wider = withRect(white, 10, 10, 34, 20, [0, 0, 0]);
  const widthRep = compare(a, wider, { grid: 8, threshold: 8, top: 3 });
  if (!widthRep.hints.some((s) => s.includes("内容宽度差"))) throw new Error("width hint missing");

  // 6. Regression: transparent design vs white-bg screenshot must judge as 'nearly identical'.
  //    This is real pit from testing, fixed case reported 0.8/100, 98.9% diff pixels.
  const rgbaTransparentBg = (w2: number, h2: number): DecodedPng => {
    const pixels = new Uint8Array(w2 * h2 * 4); // All 0 = transparent and RGB black
    for (let y = 10; y < 30; y++) {
      for (let x = 10; x < 30; x++) {
        const i = (y * w2 + x) * 4;
        pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 255; // Opaque black content
      }
    }
    return { width: w2, height: h2, channels: 4, pixels };
  };
  const transparentDesign = rgbaTransparentBg(64, 64);
  const whiteBgActual = withRect(white, 10, 10, 20, 20, [0, 0, 0]);
  const alphaRep = compare(transparentDesign, whiteBgActual, { grid: 8, threshold: 8, top: 3 });
  if (alphaRep.changedRatio > 0.01) {
    throw new Error(`transparent-vs-white should match after flatten, got ${(alphaRep.changedRatio * 100).toFixed(1)}% changed`);
  }
  if (alphaRep.score < 99) throw new Error(`alpha-flatten score should be ~100, got ${alphaRep.score}`);

  console.log("design_diff self-test: PASS (6 cases)");
}

function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") return selfTest();

  // Parse positional manually: --json is bool flag, --grid/--top/--threshold each take one value.
  // Old impl `args.filter(a => !a.startsWith("--"))` would count flag's value as positional
  // (like `--grid 8`'s `8`), so `--json --grid 8` wrongly parsed as 3 positional -> exit 64.
  const valueFlags = new Set(["--grid", "--top", "--threshold"]);
  const positional: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a.startsWith("--")) {
      if (valueFlags.has(a)) i++; // Consume this flag's value
      continue;
    }
    positional.push(a);
  }
  if (positional.length !== 2) {
    console.error("usage: bun e2e/design_diff.ts DESIGN.png ACTUAL.png [--json] [--grid N] [--top N] [--threshold N]");
    console.error("       bun e2e/design_diff.ts --self-test");
    process.exit(64);
  }
  const flag = (name: string, dflt: number): number => {
    const i = args.indexOf(`--${name}`);
    return i >= 0 && args[i + 1] ? Number(args[i + 1]) : dflt;
  };
  const [designPath, actualPath] = positional;
  for (const p of [designPath, actualPath]) {
    if (!existsSync(p)) { console.error(`file not found: ${p}`); process.exit(66); }
  }

  const report = compare(decodePng(designPath), decodePng(actualPath), {
    grid: flag("grid", 8),
    threshold: flag("threshold", 8),
    top: flag("top", 5),
  });

  if (args.includes("--json")) {
    console.log(JSON.stringify(report, null, 2));
    return;
  }

  console.log(`设计稿: ${report.designSize}   实现: ${report.actualSize}   比对尺寸: ${report.comparedAt}`);
  console.log(`相似度: ${report.score.toFixed(1)}/100   差异像素: ${(report.changedRatio * 100).toFixed(2)}%   RMSE: ${report.rmse.toFixed(2)}`);
  console.log(`\n差异热力图 (· 一致 → # 严重):\n${report.heatmap}`);
  console.log(`\n内容包围盒  设计 x=[${report.bounds.design.x}] y=[${report.bounds.design.y}]`);
  console.log(`            实现 x=[${report.bounds.actual.x}] y=[${report.bounds.actual.y}]`);
  console.log(`整体位移    x=${report.offset.x}px  y=${report.offset.y}px`);
  if (report.hints.length > 0) {
    console.log(`\n可执行提示:`);
    for (const h of report.hints) console.log(`  • ${h}`);
  } else {
    console.log(`\n无显著结构差异。`);
  }
  if (report.worstCells.length > 0 && report.changedRatio > 0.005) {
    console.log(`\n差异最大的区块 (${report.worstCells.length}):`);
    for (const c of report.worstCells) {
      console.log(`  行${c.row} 列${c.col}: ${(c.changedRatio * 100).toFixed(1)}% 像素差, 平均 ${c.delta.toFixed(1)}`);
    }
  }
}

if (import.meta.main) main();
