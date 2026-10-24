import { clickTestId, query, request, screenshot, tree, waitFor, waitForServerReady } from "./client";
import { assert, getSessionDir, run, test } from "./runner";
import { decodePng } from "./png";

async function controls() {
  const result = await request("POST", "/windows/native-input", { action: "uia-tree" });
  assert(result.ok, `system UIA tree failed: ${JSON.stringify(result)}`);
  return result.nodes.filter((node: any) => node.framework === "Zenit");
}
async function toggle(name: string, before: number, after: number) {
  const result = await request("POST", "/windows/native-input", { action: "uia-toggle", name });
  assert(result.ok && result.toggle_event && result.before_state === before && result.after_state === after && result.event_state === after,
    `system Toggle state/property notification failed: ${JSON.stringify(result)}`);
}
async function rejected(action: string, name: string, reason: string) {
  let error = "";
  try { await request("POST", "/windows/native-input", { action, name }); }
  catch (failure) { error = String(failure); }
  assert(error.includes(reason), `system ${action}(${name}) was not rejected as expected: ${error}`);
}
test("Windows system Toggle reads three states and changes real Checkbox pixels and callbacks", async () => {
  await waitForServerReady(15000);
  const foreground = await request("POST", "/windows/native-input", { action: "status" });
  await clickTestId("nav.checkbox");
  await waitFor(async () => (await query("story.checkbox.box"))[0] ?? null, 4000, 50);
  const nodes = await controls();
  for (const [name, state] of [["Unchecked", 0], ["Checked", 1], ["Indeterminate", 2]] as const) {
    const node = nodes.find((node: any) => node.name === name);
    assert(node?.role === 50002 && node.toggle_available && !node.invoke_available && node.toggle_state === state,
      `Checkbox ${name} does not expose its real Toggle state: ${JSON.stringify(node)}`);
  }
  const disabled = nodes.find((node: any) => node.name === "Disabled");
  assert(disabled && !disabled.enabled && disabled.toggle_available && disabled.toggle_state === 0, "disabled Checkbox cannot be inspected");
  await rejected("uia-toggle", "Disabled", "UIA Toggle failed");
  await rejected("uia-invoke", "Unchecked", "Control has no Invoke pattern");
  const beforePath = `${getSessionDir()}/windows-uia-checkbox-off.png`;
  assert((await screenshot(beforePath)).ok, "Checkbox baseline capture failed");
  await toggle("Unchecked", 0, 1);
  await waitFor(async () => (await query("story.checkbox.status"))[0]?.text === "changed → checked" ? true : null, 3000, 50);
  const afterPath = `${getSessionDir()}/windows-uia-checkbox-on.png`;
  assert((await screenshot(afterPath)).ok, "Checkbox checked capture failed");
  const before = decodePng(beforePath), after = decodePng(afterPath);
  const box = (await query("story.checkbox.box"))[0].children[0].rect;
  const scale = after.width / (await tree()).rect.w;
  let changed = 0;
  // Check only the actual checkbox square, excluding label and outside focus ring.
  for (let y = Math.ceil((box.y + 2) * scale); y < Math.floor((box.y + box.h - 2) * scale); y++) {
    for (let x = Math.ceil((box.x + 2) * scale); x < Math.floor((box.x + box.w - 2) * scale); x++) {
      assert(x >= 0 && y >= 0 && x < after.width && y < after.height, "Checkbox sample outside capture");
      const a = (y * after.width + x) * after.channels, b = (y * before.width + x) * before.channels;
      if ([0, 1, 2].some(c => Math.abs(after.pixels[a + c] - before.pixels[b + c]) > 8)) changed++;
    }
  }
  assert(changed >= 20, `system Toggle did not draw the checkbox square: changed=${changed}`);
  await toggle("Unchecked", 1, 0);
  await waitFor(async () => (await query("story.checkbox.status"))[0]?.text === "changed → unchecked" ? true : null, 3000, 50);
  // `indeterminate` is a parent-owned Source (the story passes constant true);
  // the view is indeterminate whenever unchecked. Toggling checks it, then
  // unchecking shows the owner's indeterminate state again (React semantics,
  // not HTML's self-clearing flag).
  await toggle("Indeterminate", 2, 1);
  await toggle("Indeterminate", 1, 2);
  const afterStatus = await request("POST", "/windows/native-input", { action: "status" });
  assert(!afterStatus.foreground && afterStatus.foreground_hwnd === foreground.foreground_hwnd, "Toggle took foreground");
  console.log(`  three states, 4 Toggle/property events, callback and ${changed} changed checkbox pixels; foreground=${foreground.foreground_hwnd}`);
});
test("Windows system Toggle changes Switch and is unavailable on Radio", async () => {
  const before = await request("POST", "/windows/native-input", { action: "status" });
  await clickTestId("nav.switch");
  await waitFor(async () => (await query("story.switch.off"))[0] ?? null, 4000, 50);
  await toggle("Off", 0, 1);
  await waitFor(async () => (await query("story.switch.status"))[0]?.text === "toggled → on" ? true : null, 3000, 50);
  await toggle("Off", 1, 0);
  await waitFor(async () => (await query("story.switch.status"))[0]?.text === "toggled → off" ? true : null, 3000, 50);
  assert((await screenshot(`${getSessionDir()}/windows-uia-switch.png`)).ok, "Switch capture failed");
  await clickTestId("nav.radio");
  await waitFor(async () => (await query("story.radio.status"))[0] ?? null, 4000, 50);
  const radios = (await controls()).filter((node: any) => node.role === 50013);
  assert(radios.length >= 2 && radios.every((node: any) => !node.toggle_available && !node.invoke_available), "Radio was exposed as Toggle or Invoke");
  await rejected("uia-toggle", "Unselected", "Control has no Toggle pattern");
  const after = await request("POST", "/windows/native-input", { action: "status" });
  assert(!after.foreground && after.foreground_hwnd === before.foreground_hwnd, "Switch/Radio acceptance took foreground");
  console.log(`  Switch Off/On/Off with property events and callbacks; ${radios.length} Radios excluded`);
});
run();
