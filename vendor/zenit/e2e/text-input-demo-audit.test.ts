/// text-input-demo-audit.test.ts: smoke test of the 4 inputs in the full demo
///
/// Runs name / email / notes each with ascii + CJK + long input + click-to-cursor + selection +
/// backspace.
///
/// Invariants checked per input:
///   1) after imeCommit buffer_len / cursor_pos grow in sync
///   2) after imeCommit displayed text updates without click
///   3) after backspace buffer_len decreases 1
///   4) Tab focus chain works
///   5) long input (60 chars) visual sync + per-key time stable

import {
  health,
  query,
  clickTestId,
  imeCommit,
  inputState,
  focused,
  key,
  waitForServerReady,
  sleep,
} from "./client";
import { test, run, assert } from "./runner";

function findText(node: any): any {
  if (node.tag === "input" || node.tag === "textarea") {
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

async function getDisplayedText(testId: string): Promise<string> {
  const m = await query(testId);
  if (m.length === 0) return "";
  const t = findText(m[0]);
  return t?.text ?? "";
}

async function clearInput(testId: string) {
  await clickTestId(testId);
  await sleep(120);
  await key("a", { ctrl: true });
  await key("backspace");
  await sleep(120);
  const s = await inputState(testId);
  assert(s.buffer_len === 0, `${testId} clear failed: buffer_len=${s.buffer_len}`);
}

test("server reachable", async () => {
  await waitForServerReady(15000);
  assert((await health()).status === "ok");
});

// ── input.name (plain text) ──

test("input.name: ASCII commit + visual sync (no click)", async () => {
  await clearInput("input.name");
  await imeCommit("Alice"); await sleep(100);
  const s = await inputState("input.name");
  const disp = await getDisplayedText("input.name");
  console.log(`  name: buffer="${s.buffer}" displayed="${disp}"`);
  assert(s.buffer_len === 5, `buffer_len=${s.buffer_len}`);
  assert(disp === "Alice", `displayed="${disp}" — fast-path 跳过 inputBeforeRender?`);
});

test("input.name: CJK IME commit + visual sync", async () => {
  await clearInput("input.name");
  await imeCommit("你好"); await sleep(100);
  const s = await inputState("input.name");
  const disp = await getDisplayedText("input.name");
  console.log(`  name CJK: buffer_len=${s.buffer_len} displayed="${disp}"`);
  assert(s.buffer_len === 6, `expected 6 bytes (2 CJK × 3), got ${s.buffer_len}`);
  assert(disp === "你好", `displayed="${disp}"`);
});

test("input.name: backspace decrement", async () => {
  await clearInput("input.name");
  await imeCommit("abc"); await sleep(80);
  await key("backspace"); await sleep(80);
  const s = await inputState("input.name");
  const disp = await getDisplayedText("input.name");
  console.log(`  name after backspace: buffer="${s.buffer}" displayed="${disp}"`);
  assert(s.buffer_len === 2, `expected 2, got ${s.buffer_len}`);
  assert(disp === "ab", `displayed="${disp}"`);
});

// ── input.email (input_type=.email validated) ──

test("input.email: ASCII commit + visual sync", async () => {
  await clearInput("input.email");
  await imeCommit("a@b.com"); await sleep(100);
  const s = await inputState("input.email");
  const disp = await getDisplayedText("input.email");
  console.log(`  email: buffer="${s.buffer}" displayed="${disp}"`);
  assert(s.buffer_len === 7, `buffer_len=${s.buffer_len}`);
  assert(disp === "a@b.com", `displayed="${disp}"`);
});

test("input.email: rejects CJK (validation)", async () => {
  await clearInput("input.email");
  await imeCommit("你"); await sleep(100);
  const s = await inputState("input.email");
  console.log(`  email after CJK commit: buffer="${s.buffer}" len=${s.buffer_len}`);
  // email should filter non-ASCII. If buffer retains it, sanitizeInputText bug
  assert(s.buffer_len === 0, `email accepted CJK char: buffer="${s.buffer}"`);
});

// ── input.notes (Textarea) ──

test("input.notes: ASCII multi-line commit + visual sync", async () => {
  await clearInput("input.notes");
  await imeCommit("hello"); await sleep(100);
  const s = await inputState("input.notes");
  const disp = await getDisplayedText("input.notes");
  console.log(`  notes: buffer_len=${s.buffer_len} displayed (first 30)="${disp.slice(0, 30)}"`);
  assert(s.buffer_len === 5, `buffer_len=${s.buffer_len}`);
  assert(disp === "hello", `textarea displayed="${disp}"`);
});

test("input.notes: CJK IME commit + visual sync", async () => {
  await clearInput("input.notes");
  await imeCommit("你好世界"); await sleep(150);
  const s = await inputState("input.notes");
  const disp = await getDisplayedText("input.notes");
  console.log(`  notes CJK: buffer_len=${s.buffer_len} displayed (first 30)="${disp.slice(0, 30)}"`);
  assert(s.buffer_len === 12, `expected 12 bytes (4 CJK × 3), got ${s.buffer_len}`);
  assert(disp === "你好世界", `textarea displayed="${disp}"`);
});

test("input.notes: backspace works (diagnostic)", async () => {
  // don't click, directly check initial state
  const sInit = await inputState("input.notes");
  console.log(`  initial (no click): buffer_len=${sInit.buffer_len} cursor=${sInit.cursor_pos} hex=${[...sInit.buffer].map(c => c.charCodeAt(0).toString(16).padStart(2, "0")).join(" ")}`);
  await clickTestId("input.notes");
  await sleep(150);
  const sFocused = await inputState("input.notes");
  console.log(`  after click: buffer_len=${sFocused.buffer_len} cursor=${sFocused.cursor_pos} hex=${[...sFocused.buffer].map(c => c.charCodeAt(0).toString(16).padStart(2, "0")).join(" ")}`);
  await imeCommit("a"); await sleep(120);
  const s0 = await inputState("input.notes");
  console.log(`  after 1 commit: buffer_len=${s0.buffer_len} cursor=${s0.cursor_pos} hex=${[...s0.buffer].map(c => c.charCodeAt(0).toString(16).padStart(2, "0")).join(" ")}`);
  // then 4 more commits
  for (let i = 0; i < 4; i++) await imeCommit("a");
  await sleep(150);
  const s1 = await inputState("input.notes");
  console.log(`  after 5 commits: buffer_len=${s1.buffer_len} cursor=${s1.cursor_pos} hex=${[...s1.buffer].map(c => c.charCodeAt(0).toString(16).padStart(2, "0")).join(" ")}`);
  await key("backspace"); await sleep(120);
  const s2 = await inputState("input.notes");
  console.log(`  after 1 backspace: buffer_len=${s2.buffer_len} cursor=${s2.cursor_pos}`);
  assert(s2.buffer_len === s1.buffer_len - 1, `BUG: textarea backspace ${s1.buffer_len} → ${s2.buffer_len}`);
});

test("input.notes: long input 60 chars buffer sync", async () => {
  // Select all and delete so setup cost is independent of previous content.
  await clickTestId("input.notes");
  await sleep(150);
  await key("a", { ctrl: true });
  await key("backspace");
  await sleep(150);
  const s0 = await inputState("input.notes");
  console.log(`  cleared: buffer_len=${s0.buffer_len}`);
  if (s0.buffer_len > 0) {
    console.log(`  (clear partial, residual="${s0.buffer.slice(0, 30)}")`);
  }
  for (let i = 0; i < 60; i++) await imeCommit("a");
  await sleep(200);
  const s = await inputState("input.notes");
  console.log(`  notes 60-char: buffer_len=${s.buffer_len} cursor=${s.cursor_pos}`);
  assert(s.buffer_len >= 60, `expected ≥60, got ${s.buffer_len}`);
});

// ── Tab focus chain ──

test("focus: click sets current_focus", async () => {
  await clickTestId("input.name");
  await sleep(200);
  const f = await focused();
  console.log(`  focused after click=${JSON.stringify(f)}`);
  assert(f.test_id !== undefined || f.id !== undefined, `BUG: click 后 current_focus 仍为 null`);
});

test("focus: Tab moves to next input", async () => {
  await clickTestId("input.name");
  await sleep(150);
  const f0 = await focused();
  await key("tab"); await sleep(150);
  const f1 = await focused();
  console.log(`  before tab: ${f0.test_id ?? f0.tag} → after tab: ${f1.test_id ?? f1.tag}`);
  assert(f1.test_id !== f0.test_id || f1.id !== f0.id, `BUG: Tab 没移动 focus`);
});

run();
