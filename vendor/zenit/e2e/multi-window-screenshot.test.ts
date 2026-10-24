// Run on the existing Storybook app on macOS or Windows. These operations use
// the actual submitted window surfaces and never change screenshot binding.
import { clickTestId, focused, query, request, screenshot, sleep, waitFor, waitForServerReady, windows } from "./client";
import { decodePng } from "./png";
import { assert, getSessionDir, run, test } from "./runner";

async function capture(name: string, id?: string) {
  const path = `${getSessionDir()}/${name}.png`;
  assert((await screenshot(path, id)).ok, `capture ${name} failed`);
  return decodePng(path);
}
async function activation() {
  if (process.platform === "win32") {
    const state = await request("POST", "/windows/native-input", { action: "status", inventory_only: true });
    assert(state.ok && state.windows.length === 2, "native multi-window foreground observation failed");
    return state.foreground_hwnd;
  }
  return (await request("POST", "/window", { action: "status" })).active;
}

test("multi-window screenshots select immutable instances without rebinding or activation", async () => {
  await waitForServerReady(15000);
  const initial = (await windows()).windows;
  assert(initial.length === 1 && initial[0].bound, `expected a fresh Storybook: ${JSON.stringify(initial)}`);
  const main = initial[0];
  assert((await clickTestId("storybook.devtools")).ok, "cannot open DevTools");
  await waitFor(async () => (await query("devtools.header.shell"))[0] ?? null, 8000, 50);
  const opened = await waitFor(async () => {
    const list = (await windows()).windows;
    return list.length === 2 ? list : null;
  }, 8000, 50);
  const panel = opened.find(w => w.window_id !== main.window_id)!;
  assert(panel.bound, "DevTools must be the default bound target for this check");
  await sleep(350);
  const focusBefore = await focused();
  const activeBefore = await activation();
  const a = await capture("multi-main-explicit", main.window_id);
  const b = await capture("multi-panel-explicit", panel.window_id);
  const legacy = await capture("multi-panel-default");
  assert(a.width !== b.width || a.height !== b.height, "distinct window surfaces have identical dimensions");
  assert(legacy.width === b.width && legacy.height === b.height, "explicit main capture changed the default target");
  let different = 0;
  for (let y = 0; y < Math.min(a.height, b.height); y += 7) {
    for (let x = 0; x < Math.min(a.width, b.width); x += 7) {
      const ai = (y * a.width + x) * a.channels, bi = (y * b.width + x) * b.channels;
      if ([0, 1, 2].some(c => Math.abs(a.pixels[ai + c] - b.pixels[bi + c]) > 15)) different++;
    }
  }
  assert(different > 100, `window pixels did not distinguish the two surfaces: ${different}`);
  const after = (await windows()).windows;
  assert(after.find(w => w.bound)?.window_id === panel.window_id, "screenshot rebound input/tree target");
  assert((await query("devtools.header.shell")).length === 1, "tree target changed after capture");
  assert(JSON.stringify(await focused()) === JSON.stringify(focusBefore), "capture changed UI focus");
  assert(await activation() === activeBefore, "capture changed native activation");

  assert((await clickTestId("devtools.close")).ok, "cannot close DevTools");
  await waitFor(async () => (await windows()).windows.length === 1, 8000, 50);
  const stale = await request("POST", "/screenshot", { path: `${getSessionDir()}/must-not-capture-closed.png`, window_id: panel.window_id });
  assert(stale.code === "window-not-found" && !stale.ok, `closed target silently fell back: ${JSON.stringify(stale)}`);
  assert((await windows()).windows[0].bound, "survivor not rebound after panel close");
  const survivor = await capture("multi-main-survivor");
  assert(survivor.width === a.width && survivor.height === a.height, "surviving default capture has wrong surface");

  assert((await clickTestId("storybook.devtools")).ok, "cannot recreate DevTools");
  await waitFor(async () => (await query("devtools.header.shell"))[0] ?? null, 8000, 50);
  const replacement = (await windows()).windows.find(w => w.window_id !== main.window_id)!;
  assert(replacement.window_id !== panel.window_id, "recreated window reused stale identity");
  const staleAgain = await request("POST", "/screenshot", { path: `${getSessionDir()}/must-not-capture-replacement.png`, window_id: panel.window_id });
  assert(staleAgain.code === "window-not-found" && !staleAgain.ok, "stale identity captured replacement window");
  await capture("multi-panel-recreated", replacement.window_id);
  assert((await clickTestId("devtools.close")).ok, "cannot close recreated DevTools");
  await waitFor(async () => (await windows()).windows.length === 1, 8000, 50);
});

await run();
