import { request, clickTestId, screenshot, waitForServerReady } from "./client";
import { assert, appendLog, getSessionDir, run, test } from "./runner";
test("scope teardown: child cleanup disposing sibling runs each cleanup once", async () => {
  await waitForServerReady();
  assert((await request("POST", "/review/scope-reentry-mount", {})).ok, "setup failed");
  assert((await screenshot(`${getSessionDir()}/mounted.png`)).ok, "capture failed");
  await clickTestId("review.scope-reentry.unmount");
  const result = await request("POST", "/review/scope-reentry-state", {});
  appendLog(`scope cleanup: ${JSON.stringify(result)}`);
  assert(result.clicked === 1, "unmount callback did not run");
  assert(JSON.stringify(result.calls) === "[1,1,1]", "scope cleanup skipped or repeated");
  // The same real input path remains usable after teardown.
  await clickTestId("review.scope-reentry.unmount");
  assert((await request("POST", "/review/scope-reentry-state", {})).clicked === 2, "input failed after teardown");
});
run();
