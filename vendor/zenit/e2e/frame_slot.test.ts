import { health, request, screenshot, waitForServerReady } from "./client";
import { assert, appendLog, getSessionDir, run, test } from "./runner";
test("frame slots: failed C cannot let D overwrite GPU-pending A or B", async () => {
  await waitForServerReady();
  const result = await request("POST", "/review/frame-slot-failure", {});
  appendLog(`gpu: ${JSON.stringify(result)}`);
  assert(result.failure === "InjectedFrameFailure" && result.sampled_bytes > 0, "probe did not submit A/B and abort C");
  assert(result.d_slot !== result.a_slot && result.d_slot !== result.b_slot, "retry reused a still-pending slot");
  assert(result.gpu_changed_bytes === 0, `GPU observed ${result.gpu_changed_bytes} overwritten bytes in A`);
  assert((await screenshot(`${getSessionDir()}/alive.png`)).ok, "window failed after slot probe");
  assert((await health()).status === "ok", "app died after slot probe");
});
run();
