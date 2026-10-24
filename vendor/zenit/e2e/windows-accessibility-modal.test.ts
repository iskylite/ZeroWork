import { clickTestId, query, request, screenshot, waitFor, waitForServerReady } from "./client";
import { assert, getSessionDir, run, test } from "./runner";

async function control(name: string) {
  const snapshot = await request("POST", "/windows/native-input", { action: "uia-tree" });
  assert(snapshot.ok, `system UIA tree failed: ${JSON.stringify(snapshot)}`);
  return snapshot.nodes.find((node: any) => node.framework === "Zenit" && node.name === name);
}
test("Windows UI Automation respects Modal isolation and restores background controls", async () => {
  await waitForServerReady(15000);
  const before = await request("POST", "/windows/native-input", { action: "status" });
  await clickTestId("nav.modal");
  await waitFor(async () => (await query("story.modal.open"))[0] ?? null, 5000, 50);
  assert((await control("Open Modal"))?.enabled, "closed Modal disabled its trigger");
  const opened = await request("POST", "/windows/native-input", { action: "uia-invoke", name: "Open Modal" });
  assert(opened.ok && opened.invoked_event, "system invocation did not open Modal");
  await waitFor(async () => {
    const dialog = (await query("story.modal.dialog"))[0];
    return dialog && dialog.visible !== false ? true : null;
  }, 4000, 50);
  // The shared accessibility projection prunes background nodes while a Modal
  // is open (the same isolation VoiceOver gets): the trigger is unreachable,
  // not merely disabled, and naming it through UIA must fail.
  await waitFor(async () => (await control("Open Modal")) === undefined ? true : null, 4000, 50);
  let rejection = "";
  try {
    const blocked = await request("POST", "/windows/native-input", { action: "uia-invoke", name: "Open Modal" });
    assert(!blocked.ok && !blocked.invoked_event, `background control bypassed Modal: ${JSON.stringify(blocked)}`);
    rejection = JSON.stringify(blocked);
  } catch (error) {
    rejection = String(error);
  }
  assert(rejection.includes("UIA Invoke failed"), `Modal rejection was not a system provider error: ${rejection}`);
  assert((await control("OK"))?.enabled, "Modal disabled its own Button");
  assert((await screenshot(`${getSessionDir()}/windows-uia-modal-open.png`)).ok, "Modal screenshot failed");
  const inside = await request("POST", "/windows/native-input", { action: "uia-invoke", name: "OK" });
  console.log("  Modal content Invoke and Invoked event delivered");
  assert(inside.ok && inside.invoked_event, `Modal content cannot be invoked: ${JSON.stringify(inside)}`);
  await waitFor(async () => (await query("story.modal.dialog"))[0]?.visible === false ? true : null, 4000, 50);
  await waitFor(async () => (await control("Open Modal"))?.enabled ? true : null, 4000, 50);
  console.log("  confirmed closed, trigger reenabled");
  const reopened = await request("POST", "/windows/native-input", { action: "uia-invoke", name: "Open Modal" });
  assert(reopened.ok && reopened.invoked_event, "background control did not recover after Modal close");
  await waitFor(async () => {
    const dialog = (await query("story.modal.dialog"))[0];
    return dialog && dialog.visible !== false && dialog.rect.w > 0 ? true : null;
  }, 4000, 50);
  console.log("  reopened visible; dismissing");
  assert((await clickTestId("modal.close")).ok, "Modal close command failed");
  await waitFor(async () => (await query("story.modal.dialog"))[0]?.visible === false ? true : null, 4000, 50);
  assert((await screenshot(`${getSessionDir()}/windows-uia-modal-closed.png`)).ok, "closed Modal screenshot failed");
  const after = await request("POST", "/windows/native-input", { action: "status" });
  assert(!after.foreground && after.foreground_hwnd === before.foreground_hwnd, "Modal UIA acceptance took foreground");
  console.log(`  Modal open/block/inside/close/reopen accepted by system UIA; foreground=${before.foreground_hwnd}`);
});
run();
