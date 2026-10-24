import { clickTestId, inputState, key, query, tree, request, screenshot, scrollAt, type_, imePreedit, imeCommit, waitFor, waitForServerReady } from "./client";
import { assert, getSessionDir, run, test } from "./runner";
async function controls() {
  const tree = await request("POST", "/windows/native-input", { action: "uia-tree" });
  assert(tree.ok && Array.isArray(tree.nodes), "external UIA tree query failed");
  for (const node of tree.nodes) assert(node.text_available === node.text_property, "TextPattern/property disagree");
  return tree.nodes.filter((node: any) => node.framework === "Zenit");
}
async function write(name: string, value: string) {
  assert((await request("POST", "/windows/native-input", { action: "uia-set-value", name, value })).ok, "UIA Value write failed");
}
test("Windows external TextPattern discovers Unicode Input, selection and protected fields", async () => {
  await waitForServerReady(15000);
  const before = await request("POST", "/windows/native-input", { action: "status" });
  const guard = async (stage: string) => {
    const current = await request("POST", "/windows/native-input", { action: "status" });
    assert(current.foreground_hwnd === before.foreground_hwnd && !current.foreground_owned,
      `foreground changed at ${stage}: ${JSON.stringify({ before: before.foreground_hwnd, after: current.foreground_hwnd, owned: current.foreground_owned })}`);
  };
  await clickTestId("nav.input");
  await waitFor(async () => (await inputState("story.input.name"))?.buffer !== undefined ? true : null, 4000, 50);
  await guard("navigation");
  let nodes = await controls();
  await guard("initial external read");
  for (const name of ["Name", "Readonly", "Disabled"]) {
    const node = nodes.find((n: any) => n.name === name);
    assert(node?.text_available && node.text?.supported_selection === 1, `${name} lacks single-selection TextPattern`);
  }
  assert(!nodes.find((n: any) => n.name === "Password")?.text_available, "password exposes TextPattern");
  const unicode = "中文 Cafe e\u0301 🧪";
  await write("Name", unicode);
  await guard("Value write");
  await clickTestId("story.input.name");
  await guard("Input click");
  await key("a", { ctrl: true });
  await guard("Ctrl+A");
  nodes = await controls();
  await guard("selected external read");
  const name = nodes.find((n: any) => n.name === "Name");
  assert(name.text.document === unicode && name.text.length === unicode.length, "external DocumentRange differs from Unicode value");
  assert(name.text.selection.length === 1 && name.text.selection[0] === unicode, "external GetSelection differs from selected Input");
  assert(name.text.visible.some((v: string) => v.length > 0) && name.text.point_empty === true, "external visible/point ranges unavailable");
  assert(nodes.find((n: any) => n.name === "Readonly")?.text.document === "Read only value", "readonly text read failed");
  assert((await screenshot(`${getSessionDir()}/windows-uia-text-input.png`)).ok, "Input capture failed");
  const after = await request("POST", "/windows/native-input", { action: "status" });
  assert(!after.foreground && after.foreground_hwnd === before.foreground_hwnd, `TextPattern query changed foreground: ${JSON.stringify({ before: before.foreground_hwnd, after: after.foreground_hwnd, owned: after.foreground_owned, app: after.hwnd })}`);
});
test("Windows external TextPattern reads multiline Unicode and empty rows", async () => {
  const before = await request("POST", "/windows/native-input", { action: "status" });
  await clickTestId("nav.textarea");
  await waitFor(async () => (await inputState("story.textarea.box"))?.buffer !== undefined ? true : null, 4000, 50);
  const text = "第一行 🧪\n\n終わり\n";
  await write("Notes", text);
  const afterWrite = await request("POST", "/windows/native-input", { action: "status" });
  assert(!afterWrite.foreground_owned && afterWrite.foreground_hwnd === before.foreground_hwnd, "Textarea Value write changed foreground");
  const nodes = await controls();
  const notes = nodes.find((n: any) => n.name === "Notes");
  assert(notes?.text_available && notes.text.document === text, "Textarea external DocumentRange is stale");
  assert(notes.text.visible.length > 0 && !notes.text.visible_unknown, "Textarea external visible ranges missing");
  assert((await screenshot(`${getSessionDir()}/windows-uia-textarea.png`)).ok, "Textarea capture failed");
  const after = await request("POST", "/windows/native-input", { action: "status" });
  assert(!after.foreground_owned && after.foreground_hwnd === before.foreground_hwnd, "Textarea TextPattern read changed foreground");
});
test("Windows TextPattern events expose committed text and selection through the system client", async () => {
  const before = await request("POST", "/windows/native-input", { action: "status" });
  for (const [navigation, name, id, value] of [
    ["nav.input", "Name", "story.input.name", "事件 e\u0301 🧪"],
    ["nav.textarea", "Notes", "story.textarea.box", "第一行 🧪\n\n選区\n"],
  ]) {
    await clickTestId(navigation);
    await waitFor(async () => (await inputState(id))?.buffer !== undefined ? true : null, 4000, 50);
    const action = async (operation: string, text?: string) => {
      const result = await request("POST", "/windows/native-input", { action: "uia-text-action", name, operation, value: text });
      assert(result.ok && result.text && result.foreground_hwnd === before.foreground_hwnd, `${name} text action failed or took foreground`);
      return result.text;
    };
    const changed = await action("value", value);
    assert(changed.text_event && changed.event_document === value && changed.document === value, `${name} text event is stale`);
    assert((await inputState(id)).buffer === value, `${name} event differs from actual widget`);
    const selected = await action("select-all");
    assert(selected.selection_event && selected.event_selection === value && selected.selection === value, `${name} selection event is stale`);
    assert(!selected.text_event && selected.document === value, `${name} selection emitted a text-change event`);
    const state = await inputState(id);
    assert(Math.min(state.anchor, state.cursor_pos) === 0 && Math.max(state.anchor, state.cursor_pos) === Buffer.byteLength(value), `${name} selected range differs from widget`);
    const collapsed = await action("caret-end");
    assert(collapsed.selection_event && collapsed.event_selection === "" && collapsed.selection === "", `${name} caret event is stale`);
    assert(!collapsed.text_event && collapsed.document === value, `${name} caret action changed text or emitted a text-change event`);
    const caret = await inputState(id);
    assert(caret.anchor === -1 && caret.cursor_pos === Buffer.byteLength(value), `${name} collapsed range differs from widget caret`);
  }
  const after = await request("POST", "/windows/native-input", { action: "status" });
  assert(!after.foreground_owned && after.foreground_hwnd === before.foreground_hwnd, "TextPattern event acceptance changed foreground");
});
test("Windows readonly TextPattern selects text while Value remains protected", async () => {
  const before = await request("POST", "/windows/native-input", { action: "status" });
  await clickTestId("nav.input");
  await waitFor(async () => (await controls()).find((node: any) => node.name === "Readonly") ?? null, 4000, 50);
  const expected = "Read only value";
  for (const operation of ["select-all", "caret-end"]) {
    const result = await request("POST", "/windows/native-input", { action: "uia-text-action", name: "Readonly", operation });
    assert(result.ok && result.text.selection_event && result.text.document === expected, "readonly selection did not commit");
    assert(result.text.selection === (operation === "select-all" ? expected : ""), "readonly selection range is wrong");
    assert(result.foreground_hwnd === before.foreground_hwnd, "readonly UIA selection took foreground");
    assert(result.text.event_selection === (operation === "select-all" ? expected : ""), "readonly owner publication differs from selection event");
  }
  let refused = false;
  try { await write("Readonly", "changed"); } catch (error) { refused = String(error).includes("UIA SetValue failed"); }
  assert(refused, "readonly value write was accepted");
  const readonly = (await controls()).find((node: any) => node.name === "Readonly");
  assert(readonly.value_readonly && readonly.value === expected && readonly.text.document === expected, "readonly Value/TextPattern disagree");
  const after = await request("POST", "/windows/native-input", { action: "status" });
  assert(!after.foreground_owned && after.foreground_hwnd === before.foreground_hwnd, "readonly acceptance changed foreground");
});
test("Windows readonly Input accepts pointer and keyboard selection without editing", async () => {
  const before = await request("POST", "/windows/native-input", { action: "status" });
  await clickTestId("nav.input");
  const viewport = await tree();
  await scrollAt(viewport.rect.w*.7, viewport.rect.h/2, 0, -900);
  await waitFor(async () => {
    const node = (await query("story.input.readonly"))[0];
    return node && node.rect.y >= 60 && node.rect.y + node.rect.h <= viewport.rect.h ? node : null;
  }, 4000, 50);
  await clickTestId("story.input.readonly");
  await key("a", { ctrl: true });
  const expected = "Read only value";
  let state = await inputState("story.input.readonly");
  assert(state.anchor === 0 && state.cursor_pos === expected.length, "readonly pointer focus / Ctrl+A failed");
  assert((await screenshot(`${getSessionDir()}/windows-readonly-selection.png`)).ok, "readonly selection capture failed");
  await key("end");
  await key("left", { shift: true });
  state = await inputState("story.input.readonly");
  assert(state.anchor === expected.length && state.cursor_pos === expected.length - 1, "readonly shift selection failed");
  for (const name of ["backspace", "delete", "enter"]) await key(name);
  for (const name of ["x", "v", "z"]) await key(name, { ctrl: true });
  await key("z", { ctrl: true, shift: true });
  await type_("blocked");
  await imePreedit("中", 3);
  await imeCommit("中");
  state = await inputState("story.input.readonly");
  assert(state.buffer === expected && state.ime_preedit_len === 0, "readonly keyboard/IME edited text");
  const after = await request("POST", "/windows/native-input", { action: "status" });
  assert(!after.foreground_owned && after.foreground_hwnd === before.foreground_hwnd, "readonly pointer/key acceptance changed foreground");
});
run();
