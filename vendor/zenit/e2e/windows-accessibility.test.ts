import { clickTestId, query, request, screenshot, tree, waitFor, waitForServerReady } from "./client";
import { assert, getSessionDir, run, test } from "./runner";
import { decodePng } from "./png";

async function nativeTree() {
  const result = await request("POST", "/windows/native-input", { action: "uia-tree" });
  assert(result.ok && Array.isArray(result.nodes), `native UIA query failed: ${JSON.stringify(result)}`);
  return result;
}
test("Windows system UI Automation reads the projected App tree without taking foreground", async () => {
  await waitForServerReady(15000);
  const before = await request("POST", "/windows/native-input", { action: "status" });
  const first = await nativeTree();
  const zenit = first.nodes.filter((node: any) => node.framework === "Zenit");
  assert(zenit.length > 5, `UIA did not expose virtual controls: ${JSON.stringify(first.nodes)}`);
  const noise = zenit.find((node: any) => node.name === "Noise");
  assert(noise && noise.role === 50000 && noise.enabled && noise.focusable && noise.invoke_available, `Noise is not an invokable accessible Button: ${JSON.stringify(noise)}`);
  const root = first.nodes[0];
  const logicalRoot = await tree();
  const scale = root.width / logicalRoot.rect.w;
  assert(scale >= 1 && scale <= 4, `invalid native coordinate scale ${scale}`);
  const logical = (await query("gallery.noise"))[0].rect;
  for (const [actual, expected] of [
    [noise.x - root.x, logical.x * scale], [noise.y - root.y, logical.y * scale],
    [noise.width, logical.w * scale], [noise.height, logical.h * scale],
  ]) assert(Math.abs(actual - expected) <= 2, `UIA physical bounds differ: ${actual} vs ${expected}`);
  const ids = zenit.map((node: any) => JSON.stringify(node.runtime_id));
  assert(new Set(ids).size === ids.length, "UIA runtime IDs are not unique");
  await clickTestId("gallery.noise");
  const shown = await nativeTree();
  const shownNoise = shown.nodes.find((node: any) => node.framework === "Zenit" && node.name === "Noise");
  assert(JSON.stringify(shownNoise.runtime_id) === JSON.stringify(noise.runtime_id), "unchanged control runtime ID changed after projection");
  assert(!shownNoise.focused, "background logical focus was incorrectly exposed as native keyboard focus");
  assert(shown.foreground_hwnd === before.foreground_hwnd, "UIA query or RPC click changed foreground");
  assert((await screenshot(`${getSessionDir()}/windows-uia-noise.png`)).ok, "App failed to render with UIA enabled");
  const after = await request("POST", "/windows/native-input", { action: "status" });
  assert(after.foreground_hwnd === before.foreground_hwnd && !after.foreground, "UIA test took foreground");
  console.log(`  native UIA controls=${zenit.length}, scale=${scale}, foreground=${after.foreground_hwnd}`);
});
test("Windows system UI Automation invokes a real Button and receives its event in background", async () => {
  const before = await request("POST", "/windows/native-input", { action: "status" });
  const invoked = await request("POST", "/windows/native-input", { action: "uia-invoke", name: "Show paths" });
  assert(invoked.ok && invoked.invoked_event, `system Invoke/event failed: ${JSON.stringify(invoked)}`);
  await waitFor(async () => {
    const path = (await query("path.cubic"))[0];
    return path && path.visible !== false && path.rect.w > 0 && path.rect.h > 0 ? true : null;
  }, 4000, 50).catch(async error => {
    await screenshot(`${getSessionDir()}/windows-uia-invoke-failure.png`);
    console.log(`  failed path state: ${JSON.stringify(await query("path.cubic"))}`);
    throw error;
  });
  const captured = `${getSessionDir()}/windows-uia-invoked-paths.png`;
  assert((await screenshot(captured)).ok, "invoked state capture failed");
  const png = decodePng(captured);
  const scale = png.width / (await tree()).rect.w;
  const rect = (await query("path.cubic"))[0].rect;
  const at = (Math.floor((rect.y + 60) * scale) * png.width + Math.floor((rect.x + 50) * scale)) * png.channels;
  assert([0, 1, 2].every(channel => png.pixels[at + channel] >= 250), "system invocation did not render the cubic path fill");
  const after = await request("POST", "/windows/native-input", { action: "status" });
  assert(!after.foreground && after.foreground_hwnd === before.foreground_hwnd, "UIA Invoke/event changed foreground");
  console.log(`  native Invoke + Invoked event, actual path pixels verified, foreground=${after.foreground_hwnd}`);
});
test("Windows system Invoke preserves the background SDK dialog gate", async () => {
  const before = await request("POST", "/windows/native-input", { action: "status" });
  assert((await request("POST", "/windows/native-input", { action: "uia-invoke", name: "Native dialogs" })).invoked_event,
    "system client did not open the isolated dialog fixture");
  for (const name of ["Open", "Save", "Folder"]) {
    const invoked = await request("POST", "/windows/native-input", { action: "uia-invoke", name });
    assert(invoked.ok && invoked.invoked_event, `system ${name} dispatch/event failed`);
    await waitFor(async () => (await query("dialog.status"))[0]?.text === "InvalidState" ? true : null, 3000, 50);
    const after = await request("POST", "/windows/native-input", { action: "status" });
    assert(!after.foreground_owned && after.foreground_hwnd === before.foreground_hwnd, `system ${name} escaped the background SDK guard`);
  }
  console.log(`  UIA Invoke reached all 3 SDK dialog kinds; background refusal preserved, foreground=${before.foreground_hwnd}`);
});
run();
