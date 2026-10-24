import { clickTestId, query, request, screenshot, tree, waitFor, waitForServerReady } from "./client";
import { assert, getSessionDir, run, test } from "./runner";
import { decodePng } from "./png";

async function controls() {
  const result = await request("POST", "/windows/native-input", { action: "uia-tree" });
  assert(result.ok, `RangeValue system query failed: ${JSON.stringify(result)}`);
  return result.nodes.filter((node: any) => node.framework === "Zenit");
}
async function setRange(selector: {name: string} | {automation_id: string}, value: number, expected: number) {
  const result = await request("POST", "/windows/native-input", { action: "uia-set-range", ...selector, value });
  assert(result.ok && result.range_event && result.after_value === expected && result.event_value === expected,
    `RangeValue setter/event disagrees: ${JSON.stringify(result)}`);
}
async function rejected(automation_id: string, value: number) {
  let failure = "";
  try { await request("POST", "/windows/native-input", { action: "uia-set-range", automation_id, value }); }
  catch (error) { failure = String(error); }
  assert(failure.includes("UIA RangeValue failed"), `invalid RangeValue write was accepted: ${failure}`);
}
test("Windows system RangeValue changes snapped and continuous Slider values and actual fill pixels", async () => {
  await waitForServerReady(15000);
  const before = await request("POST", "/windows/native-input", { action: "status" });
  await clickTestId("nav.slider");
  await waitFor(async () => (await query("story.slider.stepped.track"))[0] ?? null, 4000, 50);
  const nodes = await controls();
  const stepped = nodes.find((node: any) => node.name === "Stepped slider");
  assert(stepped?.range_available && stepped.range.value === 5 && stepped.range.min === 0 && stepped.range.max === 10 &&
    stepped.range.small === 1 && stepped.range.large === null && !stepped.range.readonly, `stepped RangeValue metadata incorrect: ${JSON.stringify(stepped)}`);
  const continuous = nodes.find((node: any) => node.name === "Continuous slider");
  assert(continuous?.range.small === 0 && continuous.range.value === 5, "continuous RangeValue metadata incorrect");
  const disabled = nodes.find((node: any) => node.name === "Disabled slider");
  assert(disabled?.range_available && !disabled.enabled && disabled.range.value === 30, "disabled Slider range cannot be inspected");
  await rejected(disabled.automation_id, 40);
  await rejected(stepped.automation_id, -1);
  await rejected(stepped.automation_id, 11);
  const beforePath = `${getSessionDir()}/windows-uia-range-before.png`;
  assert((await screenshot(beforePath)).ok, "range baseline screenshot failed");
  await setRange({name: "Stepped slider"}, 7.3, 7);
  await waitFor(async () => (await query("story.slider.feedback.status"))[0]?.text?.includes("stepped: 7.0") ? true : null, 3000, 50);
  const afterPath = `${getSessionDir()}/windows-uia-range-after.png`;
  assert((await screenshot(afterPath)).ok, "range changed screenshot failed");
  const initial = decodePng(beforePath), changed = decodePng(afterPath);
  const track = (await query("story.slider.stepped.track"))[0].rect;
  const scale = changed.width / (await tree()).rect.w;
  const x = Math.floor((track.x + track.w * .6) * scale), y = Math.floor((track.y + track.h / 2) * scale);
  const a = (y * changed.width + x) * changed.channels, b = (y * initial.width + x) * initial.channels;
  assert(x >= 0 && y >= 0 && x < changed.width && y < changed.height, "Slider pixel sample outside image");
  assert([0, 1, 2].some(c => Math.abs(changed.pixels[a + c] - initial.pixels[b + c]) > 30), "system RangeValue did not draw changed slider fill");
  await setRange({name: "Continuous slider"}, 6.25, 6.25);
  await waitFor(async () => {
    const value = Number((await query("story.slider.feedback.status"))[0]?.text?.match(/continuous: ([\d.]+)/)?.[1]);
    return Math.abs(value - 6.25) <= .051 ? true : null;
  }, 3000, 50);
  const final = await controls();
  assert(final.find((node: any) => node.name === "Stepped slider")?.range.value === 7, "Slider accessible name or value changed incorrectly");
  const after = await request("POST", "/windows/native-input", { action: "status" });
  assert(!after.foreground && after.foreground_hwnd === before.foreground_hwnd, "numeric UIA changed foreground");
  console.log(`  snapped 7.3→7, continuous 6.25, callbacks and fill pixels; foreground=${before.foreground_hwnd}`);
});
test("Windows RangeValue reads readonly ProgressBar and sets a bounded NumberStepper", async () => {
  const before = await request("POST", "/windows/native-input", { action: "status" });
  await clickTestId("nav.progress");
  await waitFor(async () => (await controls()).some((node: any) => node.role === 50012) ? true : null, 4000, 50);
  const progress = (await controls()).find((node: any) => node.role === 50012 && node.range?.value === 25);
  assert(progress?.range_available && progress.range.readonly && progress.range.min === 0 && progress.range.max === 100, "ProgressBar lacks readonly RangeValue");
  await rejected(progress.automation_id, 30);
  await clickTestId("nav.stepper");
  await waitFor(async () => (await query("story.stepper.basic"))[0] ?? null, 4000, 50);
  const stepper = (await controls()).find((node: any) => node.role === 50016 && node.range?.min === 0 && node.range?.max === 10);
  assert(stepper?.range_available && !stepper.range.readonly && stepper.range.small === 1, "bounded NumberStepper range is incorrect");
  await setRange({automation_id: stepper.automation_id}, 8, 8);
  assert((await controls()).find((node: any) => node.automation_id === stepper.automation_id)?.range.value === 8, "NumberStepper value remained stale");
  assert((await screenshot(`${getSessionDir()}/windows-uia-range-stepper.png`)).ok, "NumberStepper capture failed");
  const after = await request("POST", "/windows/native-input", { action: "status" });
  assert(!after.foreground && after.foreground_hwnd === before.foreground_hwnd, "Progress/Stepper acceptance took foreground");
  console.log("  ProgressBar readonly, bounded NumberStepper write and committed value event");
});
run();
