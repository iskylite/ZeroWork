import { clickTestId, inputState, query, request, screenshot, waitFor, waitForServerReady } from "./client";
import { assert, getSessionDir, run, test } from "./runner";

async function controls() {
  const result = await request("POST", "/windows/native-input", { action: "uia-tree" });
  assert(result.ok, `native Value query failed: ${JSON.stringify(result)}`);
  return result.nodes.filter((node: any) => node.framework === "Zenit");
}
async function setValue(name: string, value: string) {
  const result = await request("POST", "/windows/native-input", { action: "uia-set-value", name, value });
  assert(result.ok && result.value_event, `system SetValue/property event failed: ${JSON.stringify(result)}`);
}
async function rejected(name: string) {
  let failure = "";
  try { await request("POST", "/windows/native-input", { action: "uia-set-value", name, value: "rejected-synthetic-text" }); }
  catch (error) { failure = String(error); }
  assert(failure.includes("UIA SetValue failed"), `${name} unexpectedly accepted system SetValue: ${failure}`);
}
test("Windows system Value writes Unicode Input and preserves readonly/disabled/password contracts", async () => {
  await waitForServerReady(15000);
  const before = await request("POST", "/windows/native-input", { action: "status" });
  await clickTestId("nav.input");
  await waitFor(async () => (await query("story.input.name"))[0] ?? null, 4000, 50);
  const first = await controls();
  const name = first.find((node: any) => node.name === "Name");
  assert(name?.value_available && !name.value_readonly && name.value === "", `Name lacks writable Value: ${JSON.stringify(name)}`);
  const readonly = first.find((node: any) => node.name === "Readonly");
  assert(readonly?.value_available && readonly.value_readonly && readonly.value === "Read only value", `Readonly Value is incorrect: ${JSON.stringify(readonly)}`);
  const disabled = first.find((node: any) => node.name === "Disabled");
  assert(disabled?.value_available && !disabled.enabled, "Disabled Value is missing");
  const password = first.find((node: any) => node.name === "Password");
  assert(password?.password && password.value_available && !password.value, "password contents were exported through Value");
  for (const protectedName of ["Readonly", "Disabled", "Password"]) await rejected(protectedName);
  const offscreen = first.find((node: any) => node.name === "With error");
  assert(offscreen?.offscreen && offscreen.value === "bad value" && !offscreen.value_readonly, "offscreen Input metadata is unavailable before paint");
  await setValue("With error", "屏幕外の値 🧪");
  assert((await inputState("story.input.error")).buffer === "屏幕外の値 🧪", "offscreen SetValue did not reach the Input model");
  const unicode = "中文入力 Café e\u0301 🧪";
  await setValue("Name", unicode);
  const actual = await inputState("story.input.name");
  assert(actual.buffer === unicode && actual.buffer_len === Buffer.byteLength(unicode), `Input buffer differs from system SetValue: ${JSON.stringify(actual)}`);
  assert((await screenshot(`${getSessionDir()}/windows-uia-value-unicode.png`)).ok, "Unicode Input capture failed");
  await setValue("Name", "long-text-".repeat(90) + "END");
  await waitFor(async () => (await inputState("story.input.name")).scroll_x > 0 ? true : null, 3000, 50);
  assert((await screenshot(`${getSessionDir()}/windows-uia-value-long.png`)).ok, "long Input capture failed");
  await setValue("Name", "");
  assert((await inputState("story.input.name")).buffer === "", "empty SetValue did not clear Input");
  const final = await controls();
  assert(final.find((node: any) => node.name === "Readonly")?.value === "Read only value", "readonly value changed after rejected write");
  assert(!final.find((node: any) => node.name === "Password")?.value, "password Value became visible");
  const after = await request("POST", "/windows/native-input", { action: "status" });
  assert(!after.foreground && after.foreground_hwnd === before.foreground_hwnd, "Value acceptance took foreground");
  console.log(`  Unicode, long text/caret scrolling, empty text, protected fields; foreground=${before.foreground_hwnd}`);
});
test("Windows system Value sets multiline Textarea without native keyboard input", async () => {
  const before = await request("POST", "/windows/native-input", { action: "status" });
  await clickTestId("nav.textarea");
  await waitFor(async () => (await query("story.textarea.box"))[0] ?? null, 4000, 50);
  const notes = "第一行 🧪\nsecond line\n終わり";
  await setValue("Notes", notes);
  const state = await inputState("story.textarea.box");
  assert(state.buffer === notes, `Textarea did not receive multiline Unicode Value: ${JSON.stringify(state)}`);
  assert((await controls()).find((node: any) => node.name === "Notes")?.value === notes, "Textarea system Value is stale");
  assert((await screenshot(`${getSessionDir()}/windows-uia-value-multiline.png`)).ok, "multiline Value capture failed");
  const after = await request("POST", "/windows/native-input", { action: "status" });
  assert(!after.foreground && after.foreground_hwnd === before.foreground_hwnd, "Textarea Value took foreground");
  console.log("  multiline Unicode Value and committed property event agree with Textarea buffer");
});
run();
