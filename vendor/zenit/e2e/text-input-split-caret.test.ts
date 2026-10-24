/// text-input-split-caret.test.ts: a controlled input rewritten by its parent doesn't jump
/// the caret to the end (real window)
///
/// text_input demo's `input.code` is bound via `ui.split`; the parent uppercases each
/// proposal. Treating "landed != buffer" as an external write replaces everything, moves
/// the caret to the end and clears undo, which breaks mid-insertion typing and Cmd+Z.
///
/// Asserts: after mid-insertion the caret stays past the insert point, text is uppercase,
/// Cmd+Z undoes one step to pre-edit; a screenshot is saved for visual cursor position
/// verification (pixel asserts can't catch "where the cursor is drawn").

import { mkdir, stat } from "node:fs/promises";
import { clickTestId, imeCommit, imePreedit, inputState, key, screenshot, sleep, type_, waitForServerReady } from "./client";
import { assert, run, test } from "./runner";

const ID = "input.code";
const OUT = process.env.SPLIT_CARET_OUT ?? "/tmp/split-caret";

async function shot(name: string) {
  await mkdir(OUT, { recursive: true });
  const path = `${OUT}/${name}.png`;
  const r = await screenshot(path);
  assert(r.ok === true, `screenshot ${name} not ok: ${JSON.stringify(r)}`);
  const size = (await stat(path)).size;
  assert(size > 3000, `screenshot ${name} suspiciously small (${size} bytes)`);
  console.log(`  shot ${name} -> ${path}`);
}

/// Place cursor after nth byte (all ASCII text)
async function caretAt(n: number) {
  await key("home");
  for (let i = 0; i < n; i++) await key("right");
  await sleep(80);
}

test("server reachable", async () => {
  await waitForServerReady();
  await sleep(800);
});

test("中间插入被大写化：光标停在插入点之后，不跳到末尾", async () => {
  const r = await clickTestId(ID);
  assert((r as any).ok !== false && (r as any).hit !== false, `click ${ID} did not hit: ${JSON.stringify(r)}`);
  await sleep(200);
  const s0 = await inputState(ID);
  assert(s0.buffer === "ABCD", `initial buffer="${s0.buffer}"`);
  await caretAt(2);
  assert((await inputState(ID)).cursor_pos === 2, "caret not placed at 2");

  await type_("x");
  await sleep(120);
  const s1 = await inputState(ID);
  console.log(`  after "x": buffer="${s1.buffer}" cursor=${s1.cursor_pos}`);
  assert(s1.buffer === "ABXCD", `buffer="${s1.buffer}"`);
  assert(s1.cursor_pos === 3, `caret jumped: cursor=${s1.cursor_pos} (want 3)`);

  await type_("y");
  await sleep(120);
  const s2 = await inputState(ID);
  console.log(`  after "y": buffer="${s2.buffer}" cursor=${s2.cursor_pos}`);
  assert(s2.buffer === "ABXYCD", `buffer="${s2.buffer}"`);
  assert(s2.cursor_pos === 4, `caret jumped: cursor=${s2.cursor_pos} (want 4)`);
  await shot("after-insert");
});

test("Cmd+Z 一步回到编辑前，光标回到编辑前位置", async () => {
  await key("z", { cmd: true });
  await sleep(150);
  const s = await inputState(ID);
  console.log(`  after undo: buffer="${s.buffer}" cursor=${s.cursor_pos}`);
  assert(s.buffer === "ABCD", `undo buffer="${s.buffer}"`);
  assert(s.cursor_pos === 2, `undo cursor=${s.cursor_pos} (want 2)`);
  await key("z", { cmd: true, shift: true });
  await sleep(150);
  const r = await inputState(ID);
  assert(r.buffer === "ABXYCD" && r.cursor_pos === 4, `redo buffer="${r.buffer}" cursor=${r.cursor_pos}`);
});

test("IME 组字提交在中间被大写化：光标在提交内容之后", async () => {
  await caretAt(1);
  await imePreedit("q", 1);
  await sleep(80);
  await imeCommit("q");
  await sleep(150);
  const s = await inputState(ID);
  console.log(`  after IME commit: buffer="${s.buffer}" cursor=${s.cursor_pos}`);
  assert(s.buffer === "AQBXYCD", `buffer="${s.buffer}"`);
  assert(s.cursor_pos === 2, `cursor=${s.cursor_pos} (want 2)`);
  await shot("after-ime");
});

run();
