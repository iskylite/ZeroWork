import { health, request, screenshot, waitForServerReady } from "./client";
import { assert, appendLog, getSessionDir, run, test } from "./runner";
test("atlas initialization: first texture failure releases both real Metal samplers", async () => {
  await waitForServerReady();
  const result = await request("POST", "/review/atlas-init-failure", {});
  appendLog(`init: ${JSON.stringify(result)}`);
  assert(result.failure === "TextureCreationFailed" && result.samplers_created === 2, "fault did not reach first page after both samplers");
  assert(result.samplers_live === 0, `constructor leaked ${result.samplers_live} real sampler owners`);
  assert((await screenshot(`${getSessionDir()}/alive.png`)).ok, "window capture failed after atlas init fault");
  assert((await health()).status === "ok", "app died after atlas init fault");
});
run();
