import { clickAt, clickTestId, focused, health, query, screenPos, screenshot, sleep, waitForServerReady } from "./client";
import { test, run, assert, getSessionDir } from "./runner";

async function click(id: string) {
  const result = await clickTestId(id);
  assert(result.ok === true, `click failed for ${id}: ${JSON.stringify(result)}`);
}

async function status(): Promise<string> {
  await sleep(100);
  return (await query("lifecycle.status"))[0]?.text ?? "";
}
async function expectStatus(...parts: string[]) {
  let value = "";
  for (let attempt = 0; attempt < 20; attempt++) {
    value = await status();
    if (parts.every(part => value.includes(part))) return;
  }
  for (const part of parts) assert(value.includes(part), `expected ${part}; got ${value}`);
}

test("interaction lifecycle fixture opens in native storybook", async () => {
  await waitForServerReady(15000);
  assert((await health()).status === "ok");
  assert((await clickTestId("nav.interactionlifecycle")).ok === true);
  await sleep(250);
  assert((await query("lifecycle.status")).length === 1);
});

test("click destruction prevents followup handler", async () => {
  await click("lifecycle.click-remove");
  await expectStatus("removed=1", "followups=0", "cache=true");
  assert((await query("lifecycle.click-remove")).length === 0);
});

test("blur redirect settles once and synchronizes cached focus", async () => {
  await click("lifecycle.blur-source");
  await click("lifecycle.attempted");
  assert((await focused()).test_id === "lifecycle.destination");
  await expectStatus("blurs=1", "cache=true", "focus=lifecycle.destination");
});

test("focus redirect uses settled destination", async () => {
  await click("lifecycle.attempted");
  assert((await focused()).test_id === "lifecycle.attempted", "redirect must start from a different focus owner");
  await click("lifecycle.redirect");
  assert((await focused()).test_id === "lifecycle.destination");
  await expectStatus("cache=true", "focus=lifecycle.destination");
});

test("focus destruction leaves no cached owner", async () => {
  await click("lifecycle.focus-remove");
  assert((await query("lifecycle.focus-remove")).length === 0);
  await expectStatus("cache=true", "focus=none");
  assert(!(await focused()).test_id);
});

test("failed path replacement preserves inside and outside hit regions", async () => {
  const pos = await screenPos("lifecycle.path");
  assert((await clickAt(pos.x + 30, pos.y + 18)).ok === true);
  await expectStatus("oom=true", "path=1");
  assert((await clickAt(pos.x + 160, pos.y + 18)).ok === true);
  await expectStatus("path=1");
  assert((await clickAt(pos.x + 30, pos.y + 18)).ok === true);
  await expectStatus("path=2");
  assert((await screenshot(`${getSessionDir()}/interaction-lifecycle.png`)).ok === true);
});

run();
