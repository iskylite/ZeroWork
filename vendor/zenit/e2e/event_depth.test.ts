import { request, clickTestId, screenshot, waitForServerReady } from "./client";
import { assert, appendLog, getSessionDir, run, test } from "./runner";
test("event depth: root capture blocks clicks beyond 128 ancestors", async () => {
  await waitForServerReady();
  const setup = await request("POST", "/review/event-depth-mount", {});
  assert(setup.ok, `scene setup failed: ${JSON.stringify(setup)}`);
  await clickTestId("review.event-depth.shallow");
  const control = await request("POST", "/review/event-depth-state", {});
  assert(control.shallow_capture === 1 && control.shallow_clicks === 0, `shallow control failed: ${JSON.stringify(control)}`);
  // Exercise dispatch independently of hit testing: deep layout/hit coverage
  // is a separate contract and cannot mask a propagation defect.
  assert((await request("POST", "/review/event-depth-dispatch", {})).ok, "dispatch probe failed");
  const result = await request("POST", "/review/event-depth-state", {});
  appendLog(`depth: ${JSON.stringify(result)}`);
  assert((await screenshot(`${getSessionDir()}/depth.png`)).ok, "capture failed");
  assert(result.deep_capture === 1 && result.deep_clicks === 0, "deep tree bypassed ancestor capture");
});
run();
