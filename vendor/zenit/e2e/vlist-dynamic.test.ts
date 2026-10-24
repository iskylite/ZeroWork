/// vlist-dynamic.test.ts: VirtualList dynamic variable height (measure_items), real window check.
///
/// Unit tests only prove 'ledger consistency'; whether row heights truly follow content and
/// whether scrolling jumps must be seen in a real window. This test checks:
///   1. Row height truly **varies**; equal height = measure never activated (degenerates)
///   2. Row height **correlates with** content length; longer text needs taller row
///   3. After scrolling, heights stay consistent and don't collapse to the estimate (44)
/// Screenshots saved for manual review (pixel assertions miss 'looks wrong').
import {
  health,
  tree,
  clickTestId,
  screenshot,
  waitForServerReady,
  sleep,
  scrollAt,
} from "./client";
import { test, run, assert, getSessionDir, appendLog } from "./runner";

const DIR = getSessionDir();
const ESTIMATE = 44; // story's estimate_item_height setting

/// Collect VirtualList slot (height, text length).
///
/// Must **stop recursing after hitting a row**: a row has text children, so continuing counts the
/// same text twice, and the outer container (whole content column) gets misread as a row when
/// 'first child text starts with #', producing a fake 408px-tall row that inverts the
/// 'longer text taller' comparison.
function collectRows(node: any, out: { h: number; text: string }[]) {
  if (!node.children) return;
  for (const c of node.children) {
    const text = firstText(c);
    const h = c.rect?.h ?? c.h ?? 0;
    // Row detection: directly attached text starting with # (not deep in subtree).
    if (text && text.startsWith("#") && h > 0 && isDirectTextOwner(c)) {
      out.push({ h, text });
      continue; // Hit, stop recursion
    }
    collectRows(c, out);
  }
}

/// Does node 'directly' own that text (self is text node, or one layer separated).
function isDirectTextOwner(node: any): boolean {
  if (typeof node.text === "string" && node.text.length > 0) return true;
  if (!node.children) return false;
  return node.children.some(
    (c: any) => typeof c.text === "string" && c.text.length > 0,
  );
}

function firstText(node: any): string | null {
  if (typeof node.text === "string" && node.text.length > 0) return node.text;
  if (node.children) {
    for (const c of node.children) {
      const t = firstText(c);
      if (t) return t;
    }
  }
  return null;
}

test("server reachable", async () => {
  await waitForServerReady(15000);
  assert((await health()).status === "ok");
});

test("dynamic story: rows have genuinely different heights", async () => {
  const ok = await clickTestId("nav.virtuallistdynamic");
  assert(ok, "切换到 VirtualList (Dynamic) story 失败 —— test_id 不存在？");
  await sleep(600);

  const rows: { h: number; text: string }[] = [];
  collectRows(await tree(), rows);
  appendLog(`  收集到 ${rows.length} 行`);
  for (const r of rows.slice(0, 8)) {
    appendLog(`    h=${r.h.toFixed(1)}  ${r.text.slice(0, 40)}`);
  }
  assert(rows.length >= 4, `可见行太少（${rows.length}），story 可能没渲染`);

  const heights = rows.map((r) => r.h);
  const uniq = new Set(heights.map((h) => Math.round(h)));
  appendLog(`  不同高度值: ${[...uniq].sort((a, b) => a - b).join(", ")}`);
  // Core assertion: row heights must be **multiple kinds**. All equal = measure never took effect.
  assert(uniq.size >= 2, `所有行等高（${[...uniq]}）—— 动态测量没有生效`);

  // And not all are estimate (that means measured values never filled in).
  const allEstimate = heights.every((h) => Math.abs(h - ESTIMATE) < 1);
  assert(!allEstimate, `所有行都还是 estimate=${ESTIMATE} —— 测量值没回填`);

  await screenshot(`${DIR}/vlist-dynamic-initial.png`);
});

test("dynamic story: taller rows carry longer text", async () => {
  const rows: { h: number; text: string }[] = [];
  collectRows(await tree(), rows);
  assert(rows.length >= 4, "行数不足");

  // Find longest and shortest text rows; longer text must be taller after wrapping.
  const sorted = [...rows].sort((a, b) => a.text.length - b.text.length);
  const shortest = sorted[0];
  const longest = sorted[sorted.length - 1];
  appendLog(`  最短: len=${shortest.text.length} h=${shortest.h.toFixed(1)}`);
  appendLog(`  最长: len=${longest.text.length} h=${longest.h.toFixed(1)}`);
  assert(
    longest.h > shortest.h,
    `长文本行(${longest.h})并不比短文本行(${shortest.h})高 —— 高度不是由内容决定的`,
  );
});

test("dynamic story: still consistent after scrolling", async () => {
  // Scroll several times in list area (story panel roughly center window).
  for (let i = 0; i < 6; i++) {
    await scrollAt(400, 300, 0, -240);
    await sleep(120);
  }
  await sleep(400);

  const rows: { h: number; text: string }[] = [];
  collectRows(await tree(), rows);
  appendLog(`  滚动后 ${rows.length} 行`);
  for (const r of rows.slice(0, 8)) {
    appendLog(`    h=${r.h.toFixed(1)}  ${r.text.slice(0, 40)}`);
  }
  assert(rows.length >= 4, `滚动后可见行太少（${rows.length}）—— 可能整块空白`);

  const uniq = new Set(rows.map((r) => Math.round(r.h)));
  assert(uniq.size >= 2, "滚动后行高退化成等高");
  const allEstimate = rows.every((r) => Math.abs(r.h - ESTIMATE) < 1);
  assert(!allEstimate, "滚动后行高塌回 estimate —— 新进入视口的行没被测量");

  await screenshot(`${DIR}/vlist-dynamic-scrolled.png`);
  appendLog(`  截图: ${DIR}/vlist-dynamic-*.png`);
});

run();
