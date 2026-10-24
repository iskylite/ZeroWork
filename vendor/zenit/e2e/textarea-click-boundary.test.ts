/// textarea-click-boundary.test.ts: repro for click landing in the middle of a UTF-8 sequence
///
/// 4 CJK chars in a textarea (12 bytes, boundaries 0/3/6/9/12): click -> cursor=11 -> insert 'a'
/// splits the 4th CJK char (U+754C) into bytes e7 95 + 'a' + 8c, JSON-encoded as a corrupted
/// string.
///
/// Expected: textarea click hit-test always lands on a codepoint boundary

import {
  health,
  query,
  clickTestId,
  imeCommit,
  type_,
  inputState,
  screenPos,
  clickAt,
  mouseDown,
  mouseUp,
  key,
  waitForServerReady,
  sleep,
} from "./client";
import { test, run, assert } from "./runner";

async function clearNotes() {
  await clickTestId("input.notes");
  await sleep(150);
  // Cmd+A select-all then backspace
  await key("a", { cmd: true }); await sleep(100);
  await key("backspace"); await sleep(150);
  // backspace a few times defensively
  for (let i = 0; i < 30; i++) await key("backspace");
  await sleep(200);
  const s = await inputState("input.notes");
  console.log(`  [clear] buffer_len=${s.buffer_len} cursor=${s.cursor_pos}`);
}

function isCodepointBoundary(bytes: number[], offset: number): boolean {
  if (offset === 0 || offset === bytes.length) return true;
  // UTF-8 continuation byte: 0b10xxxxxx
  return (bytes[offset] & 0xC0) !== 0x80;
}

test("server reachable", async () => {
  await waitForServerReady(15000);
  assert((await health()).status === "ok");
});

test("textarea: click 在 CJK 中间，cursor 应落 codepoint 边界", async () => {
  await clearNotes();
  // type 4 CJK chars (12 bytes)
  await imeCommit("你好世界");
  await sleep(150);
  const s0 = await inputState("input.notes");
  console.log(`  before click: buffer_len=${s0.buffer_len} cursor=${s0.cursor_pos}`);

  // get textarea geometry
  const pos = await screenPos("input.notes");
  console.log(`  textarea rect: x=${pos.x} y=${pos.y} w=${pos.w} h=${pos.h}`);

  // click at slightly-left position in textarea
  const click_x = pos.x + 30;
  const click_y = pos.y + 40; // avoid label area (~22px) + some padding
  console.log(`  clicking at (${click_x.toFixed(1)}, ${click_y.toFixed(1)})`);
  await clickAt(click_x, click_y);
  await sleep(200);

  const s1 = await inputState("input.notes");
  console.log(`  after click: cursor=${s1.cursor_pos} buffer_len=${s1.buffer_len}`);

  // s1.buffer is JSON-decoded string, may have fffd from partial UTF-8 but we care about whether
  // cursor_pos is on codepoint boundary. 4 CJK = boundaries [0, 3, 6, 9, 12]
  const validBoundaries = [0, 3, 6, 9, 12];
  console.log(`  valid codepoint boundaries: ${validBoundaries.join(",")}`);
  assert(
    validBoundaries.includes(s1.cursor_pos),
    `BUG: cursor=${s1.cursor_pos} 不在 codepoint 边界 (valid: ${validBoundaries.join(",")}) — textarea hitTestAt snap 失效`,
  );
});

test("textarea: insert 后 buffer 是合法 UTF-8 (无 fffd)", async () => {
  await clearNotes();
  await imeCommit("你好世界");
  await sleep(150);
  const sBefore = await inputState("input.notes");
  console.log(`  before insert: buffer_len=${sBefore.buffer_len} cursor=${sBefore.cursor_pos} hex=${[...sBefore.buffer].map(c => c.charCodeAt(0).toString(16)).join(" ")}`);

  const pos = await screenPos("input.notes");
  await clickAt(pos.x + 20, pos.y + 40);
  await sleep(150);
  const sClick = await inputState("input.notes");
  console.log(`  after click: cursor=${sClick.cursor_pos} buffer_len=${sClick.buffer_len}`);

  // try type_ (text_input event) instead of imeCommit, see if same character loss
  await type_("a");
  await sleep(150);
  const s = await inputState("input.notes");
  console.log(`  after click+type_('a'): buffer="${s.buffer}" buffer_len=${s.buffer_len} cursor=${s.cursor_pos}`);
  console.log(`  hex bytes: ${[...s.buffer].map(c => c.charCodeAt(0).toString(16).padStart(4, "0")).join(" ")}`);

  const hasFFFD = s.buffer.includes("�");
  assert(!hasFFFD, `BUG: buffer 内有 U+FFFD ("${s.buffer}") — insert 在 codepoint 中间撕碎 UTF-8`);
});

run();
