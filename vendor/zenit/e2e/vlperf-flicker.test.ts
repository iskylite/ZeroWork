/// vlperf-flicker.test.ts, virtual_list_perf flicker repro
///
/// User report: "100k Virtual List left-center flickering unknown strings, scroll once and
/// discovered"
/// Hypothesis: renderItem dupe idx_text/title via cx.frame_arena, but row node is pool-reused
/// across frames -> next frame arena reset -> text.content dangling -> flicker

import { health, tree, screenPos, mouseDown, mouseMove, mouseUp, waitForServerReady, sleep } from "./client";
import { test, run, assert } from "./runner";

function collectRowTexts(node: any, out: string[]) {
  if (node.text !== undefined && node.text !== null) {
    if (node.text.startsWith("#") || node.text.startsWith("Item ")) out.push(node.text);
  }
  if (node.children) for (const c of node.children) collectRowTexts(c, out);
}

test("server reachable", async () => {
  await waitForServerReady(15000);
  assert((await health()).status === "ok");
});

test("idle: row texts well-formed", async () => {
  await sleep(800);
  const t = await tree();
  const rows: string[] = [];
  collectRowTexts(t, rows);
  console.log(`  idle row sample: ${rows.slice(0, 6).join(" | ")}`);
  // Each row should have #N + "Item N, Lorem..." two lines -> total = 2 x visible rows
  assert(rows.length >= 10, `太少 row: ${rows.length}`);
  // Find mis-formatted rows
  const bad = rows.filter(t => !/^#\d+$/.test(t) && !/^Item \d+ — Lorem/.test(t));
  console.log(`  malformed: ${bad.length} samples=${bad.slice(0, 3).map(t => JSON.stringify(t)).join(", ")}`);
  assert(bad.length === 0, `BUG: idle 状态就有 malformed row texts (${bad.length} 个)`);
});

test("after scroll: row texts well-formed (no dangling pointer)", async () => {
  // Do several drag scrolls in list range; default window 720x600, header 48, list at (0,48) ~
  // (720,600); use mouse drag simulating trackpad scroll
  for (let i = 0; i < 5; i++) {
    await mouseDown(360, 400);
    await mouseMove(360, 200);
    await mouseUp(360, 200);
    await sleep(80);
  }
  await sleep(300);
  const t = await tree();
  const rows: string[] = [];
  collectRowTexts(t, rows);
  console.log(`  scrolled row sample: ${rows.slice(0, 6).join(" | ")}`);
  console.log(`  total rows: ${rows.length}`);
  const bad = rows.filter(t => !/^#\d+$/.test(t) && !/^Item \d+ — Lorem/.test(t));
  console.log(`  malformed: ${bad.length}`);
  if (bad.length > 0) {
    console.log(`    samples: ${bad.slice(0, 5).map(t => JSON.stringify(t)).join(", ")}`);
  }
  assert(
    bad.length === 0,
    `BUG: 滚动后 ${bad.length} 个 row text 不符合 #N / Item N 格式 — 悬垂指针写到 frame_arena`,
  );
});

test("repeat snapshot 5×: same row should give same text", async () => {
  await sleep(300);
  const snapshots: string[][] = [];
  for (let i = 0; i < 5; i++) {
    const t = await tree();
    const rows: string[] = [];
    collectRowTexts(t, rows);
    snapshots.push(rows);
    await sleep(100);
  }
  // Compare all snapshot lengths consistent + content consistent (idle shouldn't change)
  for (let i = 1; i < snapshots.length; i++) {
    if (snapshots[i].length !== snapshots[0].length) {
      console.log(`  snapshot ${i} length=${snapshots[i].length} (snapshot 0=${snapshots[0].length})`);
    }
    for (let j = 0; j < Math.min(snapshots[i].length, snapshots[0].length); j++) {
      if (snapshots[i][j] !== snapshots[0][j]) {
        console.log(`  snap ${i} row ${j}: "${snapshots[i][j]}" != "${snapshots[0][j]}" (snap 0)`);
      }
    }
  }
  // Baseline: snapshot 0 and snapshot 4 should have at least some rows consistent (idle state)
  const diff = snapshots[0].filter((t, j) => snapshots[4][j] !== t).length;
  console.log(`  diff count between snapshot 0 and 4: ${diff}`);
  assert(diff === 0, `BUG: idle 状态下 5 帧之间 ${diff} 个 row 文本不一致 → 帧间闪烁`);
});

run();
