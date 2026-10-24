/// glasslab-scroll-flicker.test.ts, GlassLab glass background flicker repro
///
/// User report: scrolling storybook left sidebar panel, GlassLab "Drag me" glass starts flickering
/// background. Detection: switch to glasslab -> get story.glasslab.drag rect -> idle continuous
/// shots glass region mean RGB frame jitter baseline -> scroll left sidebar continuously, sync
/// shoot -> frame jitter significantly exceeds baseline = flicker.
import {
  health,
  tree,
  query,
  clickTestId,
  scrollAt,
  screenshot,
  waitForServerReady,
  waitFor,
  sleep,
} from "./client";
import { test, run, assert, getSessionDir, appendLog } from "./runner";
import { decodePng } from "./png";

const DIR = getSessionDir();
let logicalWidth = 0;

function meanRGB(pngPath: string, rect: { x: number; y: number; w: number; h: number }): [number, number, number] {
  const png = decodePng(pngPath);
  const scale = png.width / logicalWidth; // actual native client width, including VM DPI/size clamps
  const x0 = Math.max(0, Math.round(rect.x * scale));
  const y0 = Math.max(0, Math.round(rect.y * scale));
  const x1 = Math.min(png.width, Math.round((rect.x + rect.w) * scale));
  const y1 = Math.min(png.height, Math.round((rect.y + rect.h) * scale));
  let r = 0, g = 0, b = 0, n = 0;
  for (let y = y0; y < y1; y += 2) {
    for (let x = x0; x < x1; x += 2) {
      const i = (y * png.width + x) * png.channels;
      r += png.pixels[i]; g += png.pixels[i + 1]; b += png.pixels[i + 2]; n++;
    }
  }
  assert(n > 0, "glass sample region is outside the screenshot");
  return [r / n, g / n, b / n];
}

function frameDelta(a: [number, number, number], b: [number, number, number]): number {
  return Math.max(Math.abs(a[0] - b[0]), Math.abs(a[1] - b[1]), Math.abs(a[2] - b[2]));
}

function maxDelta(series: [number, number, number][]): number {
  let m = 0;
  for (let i = 1; i < series.length; i++) m = Math.max(m, frameDelta(series[i - 1], series[i]));
  return m;
}

let glassRect: { x: number; y: number; w: number; h: number };
let idleMax = 0;

test("server reachable", async () => {
  await waitForServerReady(15000);
  assert((await health()).status === "ok");
}, { fatal: true });

test("切到 glasslab，玻璃节点就位", async () => {
  await clickTestId("nav.glasslab");
  const q = await waitFor(async () => {
    const r = await query("story.glasslab.drag");
    return r.length === 1 && r[0].rect.w > 0 ? r : null;
  }, 6000, 50);
  glassRect = q[0].rect;
  logicalWidth = (await tree()).rect.w;
  assert(logicalWidth > 0, "missing native client width");
  appendLog(`  glass rect: ${JSON.stringify(glassRect)}`);
  await sleep(800); // First frame settle
}, { fatal: true });

test("idle 基线：玻璃区帧间抖动", async () => {
  const series: [number, number, number][] = [];
  for (let i = 0; i < 6; i++) {
    const p = `${DIR}/glasslab-idle-${i}.png`;
    assert((await screenshot(p)).ok, "glass capture failed");
    series.push(meanRGB(p, glassRect));
    await sleep(120);
  }
  idleMax = maxDelta(series);
  appendLog(`  idle means: ${series.map(s => s.map(v => v.toFixed(1)).join(",")).join(" | ")}`);
  appendLog(`  idle max frame delta: ${idleMax.toFixed(2)}`);
});

test("滚动左侧 sidebar：玻璃区不应闪烁", async () => {
  // Sidebar at window left edge (≈200 logical px wide), continuous scroll in its middle, interleave
  // screenshots
  const series: [number, number, number][] = [];
  for (let i = 0; i < 10; i++) {
    await scrollAt(100, 320, 0, i % 2 === 0 ? -60 : 60);
    await sleep(60);
    const p = `${DIR}/glasslab-scroll-${i}.png`;
    assert((await screenshot(p)).ok, "glass capture failed");
    series.push(meanRGB(p, glassRect));
  }
  const scrollMax = maxDelta(series);
  appendLog(`  scroll means: ${series.map(s => s.map(v => v.toFixed(1)).join(",")).join(" | ")}`);
  appendLog(`  scroll max frame delta: ${scrollMax.toFixed(2)} (idle baseline ${idleMax.toFixed(2)})`);
  // Glass region non-overlapping sidebar: scrolling sidebar shouldn't cause glass region any
  // visible change. Threshold: idle baseline + 3 (erase screenshot noise), absolute > 6 counts
  // flicker.
  assert(
    scrollMax <= Math.max(idleMax + 3, 6),
    `BUG: 滚动 sidebar 时玻璃区帧间抖动 ${scrollMax.toFixed(2)}（idle 基线 ${idleMax.toFixed(2)}）— 背景闪烁`,
  );
});

run();
