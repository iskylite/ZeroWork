import { health, request, screenshot, waitForServerReady } from "./client";
import { assert, appendLog, getSessionDir, run, test } from "./runner";
test("texture upload: reject undersized row stride and preserve valid padded-row pixels", async () => {
  await waitForServerReady();
  const result = await request("POST", "/review/texture-stride", {});
  appendLog(`upload: ${JSON.stringify(result)}`);
  assert(result.rejection === "InvalidTextureData", `unsafe stride passed to Metal: ${result.rejection}`);
  assert(result.roundtrip === true, "valid padded rows did not read back as red/green pixels");
  assert((await screenshot(`${getSessionDir()}/alive.png`)).ok, "window failed to draw after uploads");
  assert((await health()).status === "ok", "app died after uploads");
});
run();
