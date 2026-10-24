import { request, screenshot, waitForServerReady } from "./client";
import { assert, appendLog, getSessionDir, run, test } from "./runner";
for (const nested of [false, true]) test(`cleanup reentry: ${nested ? "nested" : "direct"} self detach preserves sibling cleanup and unlink`, async () => {
  await waitForServerReady();
  assert((await request("POST", nested ? "/review/cleanup-nested-mount" : "/review/cleanup-mount", {})).ok, "scene setup failed");
  assert((await screenshot(`${getSessionDir()}/mounted-${nested}.png`)).ok, "capture failed");
  const result = await request("POST", "/review/cleanup-remove", {});
  appendLog(`cleanup: ${JSON.stringify(result)}`);
  assert(result.mounted, "probe children were not mounted");
  assert(JSON.stringify(result.calls) === "[1,1,1]", "cleanup skipped or duplicated a sibling");
  assert(result.detached, "a removed child still points at its old parent");
});
run();
