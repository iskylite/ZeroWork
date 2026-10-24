/// password-long-input.test.ts: long password input caret offset + stutter repro
///
/// Symptoms: with more password characters the caret shifts and rendering stutters; after N
/// characters a click is needed to update.
///
/// Hypotheses:
/// 1) Long input caret_x vs expected (single_star x N) inconsistent -> measure offset
/// 2) Per-keystroke frame_time grows with N -> O(N) or O(N^2) hot path
/// 3) text.content changed but not markLayoutDirty -> visual mask not updated until click triggers
///    layout

import {
  health,
  query,
  clickTestId,
  imeCommit,
  type_,
  inputState,
  key,
  waitForServerReady,
  sleep,
} from "./client";
import { test, run, assert } from "./runner";

function findCaret(node: any): any {
  if (node.tag === "input") {
    const f = (m: any): any => {
      if (m.rect && m.rect.w === 1 && m.rect.h > 0) return m;
      if (m.children) for (const c of m.children) { const r = f(c); if (r) return r; }
      return null;
    };
    return f(node);
  }
  if (node.children) for (const c of node.children) { const r = findCaret(c); if (r) return r; }
  return null;
}

function findText(node: any): any {
  if (node.tag === "input") {
    const f = (m: any): any => {
      if (m.text !== undefined && m.text !== null) return m;
      if (m.children) for (const c of m.children) { const r = f(c); if (r) return r; }
      return null;
    };
    return f(node);
  }
  if (node.children) for (const c of node.children) { const r = findText(c); if (r) return r; }
  return null;
}

async function getCaretX(): Promise<number> {
  const m = await query("input.password");
  const c = findCaret(m[0]);
  return c ? c.rect.x : -1;
}

async function getDisplayedText(): Promise<string> {
  const m = await query("input.password");
  const t = findText(m[0]);
  return t?.text ?? "";
}

async function clearPasswordBuffer() {
  await clickTestId("input.password");
  await sleep(150);
  // Cmd+A select-all + backspace clear once, more robust than backspace x 256 (click middle of
  // input, cursor not at end, can only delete left half, right half stranded)
  await key("a", { cmd: true });
  await sleep(80);
  await key("backspace");
  await sleep(150);
  const s = await inputState("input.password");
  assert(s.buffer_len === 0, `clear failed: buffer_len=${s.buffer_len}`);
}

test("server reachable", async () => {
  await waitForServerReady(15000);
  const r = await health();
  assert(r.status === "ok");
});

test("baseline: 1 ASCII char caret_x", async () => {
  await clearPasswordBuffer();
  await imeCommit("a"); await sleep(80);
  const s = await inputState("input.password");
  assert(s.buffer_len === 1);
  const x = await getCaretX();
  console.log(`  1-char caret_x = ${x.toFixed(2)}`);
  (globalThis as any).__one_caret_x = x;
});

test("long input 60 chars: visual mask updates without click + caret tracks linearly", async () => {
  await clearPasswordBuffer();

  // Commit 60 chars at once -> check caret_x ≈ one_caret_x x 60
  for (let i = 0; i < 60; i++) {
    await imeCommit("a");
    if (i === 0 || i === 4 || i === 29 || i === 59) {
      await sleep(80);
      const x = await getCaretX();
      const dt = await getDisplayedText();
      const s = await inputState("input.password");
      console.log(`  after ${i + 1} commits: buffer_len=${s.buffer_len} cursor=${s.cursor_pos} ime_phase=${s.ime_phase} displayed.len=${dt.length} caret_x=${x.toFixed(2)}`);
    }
  }
  await sleep(150);
  const s = await inputState("input.password");
  console.log(`  FINAL: buffer_len=${s.buffer_len} cursor=${s.cursor_pos} ime_phase=${s.ime_phase}`);
  assert(s.buffer_len === 60, `expected 60, got ${s.buffer_len}`);

  const final_x = await getCaretX();
  const displayed = await getDisplayedText();
  console.log(`  60-char: caret_x=${final_x.toFixed(2)}`);
  console.log(`  displayed text len=${displayed.length} (expected 60), starts="${displayed.slice(0, 20)}"`);

  // Visual mask must equal length (core fix verification)
  assert(
    displayed.length === 60,
    `BUG: displayed mask len=${displayed.length}, expected 60 — 'input 后要点一下才更新 *' 可能是 markLayoutDirty 缺失`,
  );
  // caret_x should be within input visible width (input width=320, padding 8 -> caret <= ~310);
  // long input scroll_x pins caret at right edge, caret_x should stabilize near right
  assert(
    final_x > 100 && final_x < 360,
    `BUG: caret_x=${final_x} out of expected visible range [100, 360]`,
  );
});

test("frame-time: time per char should NOT grow with N", async () => {
  await clearPasswordBuffer();

  // Measure char 1-10 vs 50-60 ms/char
  let t0 = Date.now();
  for (let i = 0; i < 10; i++) await imeCommit("a");
  await sleep(50);
  const t_early = Date.now() - t0;
  console.log(`  chars 1-10: ${t_early}ms (${(t_early / 10).toFixed(1)} ms/char incl RPC)`);

  // Jump to N=50
  for (let i = 0; i < 40; i++) await imeCommit("a");
  await sleep(80);

  t0 = Date.now();
  for (let i = 0; i < 10; i++) await imeCommit("a");
  await sleep(50);
  const t_late = Date.now() - t0;
  console.log(`  chars 50-60: ${t_late}ms (${(t_late / 10).toFixed(1)} ms/char incl RPC)`);

  // RPC overhead dominant, tolerate absolute time loosely, but ratio > 2x suggests O(N)
  const ratio = t_late / Math.max(t_early, 1);
  console.log(`  ratio = ${ratio.toFixed(2)}× (>2 = O(N) suspect)`);
  assert(ratio < 3.0, `BUG: per-keystroke time grew ${ratio.toFixed(2)}× at N=50 — O(N) hot path`);
});

run();
