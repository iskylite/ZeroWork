/// text-anim-jitter.test.ts: text translate animation letter-spacing stability gate
///
/// The TextAnimJitter story renders text moving uniformly at 1 logical px/s (non-integer font
/// 16.7px, so each glyph advance carries a different fraction). Per-glyph pixel snapping makes
/// glyphs cross the half-pixel rounding threshold at different times, so adjacent letter spacing
/// varies by +-1 physical pixel over time. Correct behavior: the whole line translates continuously
/// with constant spacing (sub-pixel sample noise <~0.2px).
///
/// Method: sample N screenshots at intervals -> crop wrapper region -> ink projection -> segment by
/// space -> weighted centroid per glyph -> max-min range of adjacent glyph spacing over time. Gate:
/// max range < GAP_LIMIT (physical px). Also asserts the line truly moves (prevents false pass).
///
/// Run: ZENIT_E2E_TEST_FILE=e2e/text-anim-jitter.test.ts bash scripts/run_storybook_e2e.sh
import { mkdir } from "node:fs/promises";
import {
  clickTestId,
  screenPos,
  screenshot,
  sleep,
  tree,
  waitForServerReady,
} from "./client";
import { decodePng, type DecodedPng } from "./png";

const OUT = process.env.JITTER_OUT ?? "/tmp/zenit_text_anim_jitter";
const SHOTS = Number(process.env.JITTER_SHOTS ?? "16");
const INTERVAL_MS = Number(process.env.JITTER_INTERVAL_MS ?? "400");
/// Physical pixels. Buggy ~1.0 per-pair range; fixed <0.2.
const GAP_LIMIT = Number(process.env.JITTER_GAP_LIMIT ?? "0.55");

interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/// Crop rect (logical coords x scale) region, column ink projection -> segment -> weighted centroid
/// (physical px).
function glyphCentroids(png: DecodedPng, rect: Rect, scale: number): number[] {
  const inset = 3;
  const x0 = Math.max(0, Math.round((rect.x + inset) * scale));
  const x1 = Math.min(png.width, Math.round((rect.x + rect.w - inset) * scale));
  const y0 = Math.max(0, Math.round((rect.y + inset) * scale));
  const y1 = Math.min(png.height, Math.round((rect.y + rect.h - inset) * scale));
  const cols = new Float64Array(Math.max(0, x1 - x0));
  for (let y = y0; y < y1; y++) {
    for (let x = x0; x < x1; x++) {
      const i = (y * png.width + x) * png.channels;
      const lum =
        0.299 * png.pixels[i] + 0.587 * png.pixels[i + 1] + 0.114 * png.pixels[i + 2];
      cols[x - x0] += Math.max(0, 255 - lum) / 255;
    }
  }
  let max = 0;
  for (const v of cols) max = Math.max(max, v);
  if (max <= 0) return [];
  // Low threshold segment: space column ink ≈ 0, glyph column >> threshold
  const thr = max * 0.12;
  const centroids: number[] = [];
  let start = -1;
  for (let i = 0; i <= cols.length; i++) {
    const on = i < cols.length && cols[i] > thr;
    if (on && start < 0) start = i;
    else if (!on && start >= 0) {
      if (i - start >= 2) {
        let w = 0;
        let wx = 0;
        for (let j = start; j < i; j++) {
          const v = cols[j];
          w += v;
          wx += v * j;
        }
        centroids.push(wx / w);
      }
      start = -1;
    }
  }
  return centroids;
}

await mkdir(OUT, { recursive: true });
await waitForServerReady();
await sleep(1500); // First frame + first story build complete before click (like glasschrome-shot)

const nav = await clickTestId("nav.textanimjitter");
if (!nav || (nav as any).ok === false) {
  throw new Error(`nav.textanimjitter click failed: ${JSON.stringify(nav)}`);
}
await sleep(600);

const rootRect = (await tree()).rect;
const wrap = await screenPos("story.textanimjitter.wrap");
if (!wrap || !(wrap.w > 0)) throw new Error(`wrap not found: ${JSON.stringify(wrap)}`);

const shotPaths: string[] = [];
for (let i = 0; i < SHOTS; i++) {
  const p = `${OUT}/frame-${String(i).padStart(2, "0")}.png`;
  const r = await screenshot(p);
  if (!r.ok) throw new Error(`screenshot ${i} failed: ${JSON.stringify(r)}`);
  shotPaths.push(p);
  await sleep(INTERVAL_MS);
}

const first = decodePng(shotPaths[0]);
const scale = first.width / rootRect.w;
console.log(`scale=${scale.toFixed(2)} wrap=${JSON.stringify(wrap)} shots=${SHOTS}`);

const perShot: number[][] = shotPaths.map((p, idx) => {
  const png = idx === 0 ? first : decodePng(p);
  return glyphCentroids(png, wrap, scale);
});

// Count only screenshots matching mode segment count (drop some with adhesion/edge crop, but keep
// >=2/3 valid)
const countFreq = new Map<number, number>();
for (const c of perShot) countFreq.set(c.length, (countFreq.get(c.length) ?? 0) + 1);
const modalCount = [...countFreq.entries()].sort((a, b) => b[1] - a[1])[0][0];
const valid = perShot.filter((c) => c.length === modalCount);
console.log(
  `segments per shot: [${perShot.map((c) => c.length).join(",")}] modal=${modalCount} valid=${valid.length}/${SHOTS}`,
);
if (modalCount < 8) throw new Error(`glyph segmentation too coarse: modal=${modalCount} (<8)`);
if (valid.length < Math.ceil((SHOTS * 2) / 3)) {
  throw new Error(`too few consistent shots: ${valid.length}/${SHOTS}`);
}

// Prevent false pass: line must truly move (1 logical px/s x sample duration x scale, tolerance
// ±60%)
const meanX = (c: number[]) => c.reduce((s, v) => s + v, 0) / c.length;
const travel = meanX(valid[valid.length - 1]) - meanX(valid[0]);
const expectedTravel = ((SHOTS - 1) * INTERVAL_MS) / 1000 /* px/s */ * scale;
console.log(`travel=${travel.toFixed(2)}px expected≈${expectedTravel.toFixed(2)}px`);
if (travel < expectedTravel * 0.4) {
  throw new Error(
    `text does not appear to be animating: travel=${travel.toFixed(2)} expected≈${expectedTravel.toFixed(2)}`,
  );
}

// Core metric: max-min range of adjacent glyph spacing over time
const gapCount = modalCount - 1;
let worst = 0;
let worstGap = -1;
const ranges: number[] = [];
for (let g = 0; g < gapCount; g++) {
  let lo = Infinity;
  let hi = -Infinity;
  for (const c of valid) {
    const gap = c[g + 1] - c[g];
    lo = Math.min(lo, gap);
    hi = Math.max(hi, gap);
  }
  const range = hi - lo;
  ranges.push(range);
  if (range > worst) {
    worst = range;
    worstGap = g;
  }
}
console.log(`gap ranges (physical px): [${ranges.map((r) => r.toFixed(2)).join(", ")}]`);
console.log(`worst gap range = ${worst.toFixed(3)}px (gap #${worstGap}), limit = ${GAP_LIMIT}px`);

if (worst > GAP_LIMIT) {
  console.log("Results: 0 passed, 1 failed, 0 aborted (jitter detected)");
  throw new Error(
    `TEXT ANIMATION JITTER DETECTED: gap #${worstGap} varies by ${worst.toFixed(3)} physical px over time (limit ${GAP_LIMIT}). ` +
      `Per-glyph pixel snapping is discretizing a continuous translate.`,
  );
}
console.log("Results: 1 passed, 0 failed, 0 aborted");
console.log(`TEXT ANIMATION STABLE: worst gap variation ${worst.toFixed(3)}px <= ${GAP_LIMIT}px`);
