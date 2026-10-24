/// Hold GlassSlider / GlassToggle knob 0.5s then capture full window (material calibration, compare
/// with native held frame).
/// Usage: ZENIT_E2E_TEST_FILE=e2e/glass-controls-held.test.ts ZENIT_HELD_OUT=<dir> bash
/// scripts/run_storybook_e2e.sh
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { query, clickTestId, sleep, waitForServerReady, mouseMove, mouseDown, mouseUp, screenshot } from "./client";
import { test, run, assert } from "./runner";
const out = resolve(process.env.ZENIT_HELD_OUT ?? "/tmp/zenit-controls-held");
test("held knobs", async () => {
  await waitForServerReady();
  mkdirSync(out, { recursive: true });
  await clickTestId("nav.glasscontrols"); await sleep(800);
  const st = (await query("story.glasscontrols.stage"))[0]!.rect;
  writeFileSync(`${out}/rect.json`, JSON.stringify(st));
  for (const [name, x, y] of [["slider", 320, 80], ["toggle", 311, 170]] as Array<[string, number, number]>) {
    await mouseMove(st.x + x, st.y + y); await mouseDown(st.x + x, st.y + y);
    await sleep(500);
    assert((await screenshot(`${out}/${name}.png`)).ok === true, "screenshot");
    await mouseUp(st.x + x, st.y + y); await mouseMove(-10, -10);
    await sleep(500);
  }
});
await run();
