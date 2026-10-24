/// password-ime-fix-verify.test.ts: e2e verification of password mask visual width
///
/// Core assertion: after inputting N codepoints in password mode, whether ASCII or CJK, caret X
/// should **depend only on the mask character count** (N ASCII '*'), independent of original
/// character width.
///
/// visualCursorAdvance must use the mask string (ASCII single-width), not the raw buffer (CJK
/// double-width), else caret X drifts right.

import {
  health,
  query,
  clickTestId,
  imeCommit,
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

async function getCaretX(): Promise<number> {
  const m = await query("input.password");
  const c = findCaret(m[0]);
  return c ? c.rect.x : -1;
}

async function clearPasswordBuffer() {
  // Click first to focus
  await clickTestId("input.password");
  await sleep(150);
  // Clear with backspace (lots)
  for (let i = 0; i < 32; i++) {
    await key("backspace");
  }
  await sleep(100);
  const s = await inputState("input.password");
  assert(s.buffer_len === 0, `clear failed: buffer_len=${s.buffer_len} buffer="${s.buffer}"`);
}

test("server is reachable", async () => {
  await waitForServerReady(15000);
  const r = await health();
  assert(r.status === "ok");
});

test("password ASCII baseline: 3 chars 'abc' → buffer_len=3 caret_x", async () => {
  await clearPasswordBuffer();

  await imeCommit("a"); await sleep(60);
  await imeCommit("b"); await sleep(60);
  await imeCommit("c"); await sleep(120);

  const s = await inputState("input.password");
  console.log(`  buffer_len=${s.buffer_len} cursor_pos=${s.cursor_pos} buffer="${s.buffer}"`);
  assert(s.buffer_len === 3, `buffer_len=${s.buffer_len}`);
  assert(s.cursor_pos === 3, `cursor_pos=${s.cursor_pos}`);

  const caret_x = await getCaretX();
  console.log(`  ASCII 3 chars → caret.x=${caret_x.toFixed(2)}`);
  // Write global for CJK test comparison
  (globalThis as any).__ascii_caret_x = caret_x;
});

test("password CJK: 3 codepoint '你好世' should have same caret_x as ASCII 3 chars", async () => {
  await clearPasswordBuffer();

  await imeCommit("你"); await sleep(60);
  await imeCommit("好"); await sleep(60);
  await imeCommit("世"); await sleep(120);

  const s = await inputState("input.password");
  console.log(`  buffer_len=${s.buffer_len} cursor_pos=${s.cursor_pos} buffer="${s.buffer}"`);
  assert(s.buffer_len === 9, `expected 9 bytes (3 CJK × 3 bytes UTF-8), got buffer_len=${s.buffer_len}`);
  assert(s.cursor_pos === 9, `cursor_pos=${s.cursor_pos}`);

  const caret_x = await getCaretX();
  const ascii_x = (globalThis as any).__ascii_caret_x;
  const dx = Math.abs(caret_x - ascii_x);
  console.log(`  CJK 3 codepoints → caret.x=${caret_x.toFixed(2)} (ASCII baseline=${ascii_x.toFixed(2)}, Δ=${dx.toFixed(2)}px)`);
  assert(
    dx < 1.5,
    `caret X mismatch: ASCII ${ascii_x.toFixed(2)} vs CJK ${caret_x.toFixed(2)} (Δ${dx.toFixed(2)}px) → BUG: visualCursorAdvance 用 raw buffer 而非 mask`
  );
});

test("password mixed: 1 ASCII + 2 CJK → caret_x like 3 ASCII", async () => {
  await clearPasswordBuffer();

  await imeCommit("a"); await sleep(60);
  await imeCommit("好"); await sleep(60);
  await imeCommit("世"); await sleep(120);

  const s = await inputState("input.password");
  console.log(`  buffer_len=${s.buffer_len} buffer="${s.buffer}"`);
  // 1 ASCII + 2 CJK = 1 + 6 = 7 bytes
  assert(s.buffer_len === 7, `expected 7 bytes, got ${s.buffer_len}`);

  const caret_x = await getCaretX();
  const ascii_x = (globalThis as any).__ascii_caret_x;
  const dx = Math.abs(caret_x - ascii_x);
  console.log(`  mixed 1A+2C → caret.x=${caret_x.toFixed(2)} (ASCII baseline=${ascii_x.toFixed(2)}, Δ=${dx.toFixed(2)}px)`);
  assert(
    dx < 1.5,
    `mixed caret X mismatch: ASCII ${ascii_x.toFixed(2)} vs mixed ${caret_x.toFixed(2)} (Δ${dx.toFixed(2)}px) → BUG`
  );
});

run();
