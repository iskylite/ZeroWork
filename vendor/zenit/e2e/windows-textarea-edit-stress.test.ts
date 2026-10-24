// Minimal reproduction for editing ASCII then CJK in the same Windows Textarea.
import { clickTestId, imeCommit, inputState, key, query, sleep, waitForServerReady } from "./client";
import { assert, run, test } from "./runner";

test("Textarea repeated deletion followed by ASCII and UTF-8 edits", async () => {
  await waitForServerReady(15000);
  await clickTestId("input.notes");
  await sleep(120);
  const repeats = Number(process.env.ZENIT_WINDOWS_BACKSPACE_REPEAT ?? "300");
  assert(Number.isInteger(repeats) && repeats >= 5 && repeats <= 1000, "invalid backspace repeat count");
  for (let i = 0; i < repeats; i++) await key("backspace");
  await sleep(120);
  console.log(`Initially cleared: ${JSON.stringify(await inputState("input.notes"))}`);
  await imeCommit("hello");
  await sleep(100);
  console.log(`ASCII: ${JSON.stringify(await inputState("input.notes"))}`);
  await query("input.notes");
  await clickTestId("input.notes");
  await sleep(120);
  for (let i = 0; i < repeats; i++) await key("backspace");
  await sleep(120);
  const cleared = await inputState("input.notes");
  console.log(`Cleared: ${JSON.stringify(cleared)}`);
  assert(cleared.buffer_len === 0 && cleared.cursor_pos === 0, "delete did not clear document");
  assert(cleared.selection_rects?.length === 0, "stale selection after deletion");
  await imeCommit("你好世界");
  await sleep(150);
  const state = await inputState("input.notes");
  console.log(`CJK: ${JSON.stringify(state)}`);
  const tree = await query("input.notes");
  console.log(`Tree nodes: ${tree.length}`);
  if (state.buffer !== "你好世界" || state.buffer_len !== 12) throw new Error("Textarea state mismatch");
  assert(state.cursor_pos === 12 && state.cursor_rect !== null, "UTF-8 caret mismatch");
});

run();
