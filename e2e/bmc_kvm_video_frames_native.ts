/** Continuous synthetic frames through the production KVM view and Metal sink.
 * No target, credentials, or remote input. Requires Python Pillow for pixel checks.
 * node e2e/bmc_kvm_video_frames_native.ts --binary PATH --out DIR
 */
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { query, request, screenshot, sleep, waitFor, waitForServerReady } from "../vendor/zenit/e2e/client.ts";

const options: Record<string, string> = {};
for (let i = 2; i < process.argv.length; i += 2) {
  assert(["--binary", "--out"].includes(process.argv[i]) && process.argv[i + 1], "Expected --binary PATH --out DIR");
  options[process.argv[i]] = process.argv[i + 1];
}
assert(options["--binary"] && options["--out"], "Expected --binary PATH --out DIR");
const out = resolve(options["--out"]), binary = resolve(options["--binary"]);
await mkdir(out, { recursive: true });
const base = await mkdtemp("/tmp/zerowork-kvm-frames-"), rpc = join(base, "rpc");
await mkdir(rpc);
process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
delete process.env.ZENIT_NO_RETAINED;
const app = spawn(binary, ["--theme=dark", "--state=controlled"], {
  env: { ...process.env, ZENIT_E2E_FILE_RPC_DIR: rpc, ZENIT_E2E_BACKGROUND: "1", ZENIT_E2E_ISOLATE_POINTER: "1", ZENIT_E2E_ISOLATE_KEYBOARD: "1" },
  stdio: "ignore",
});
const exited = new Promise<void>(done => app.once("close", () => done()));
const captures: { path: string; rgb: number[] }[] = [];
try {
  await waitForServerReady();
  const frame = await waitFor(async () => (await query("bmc.frame")).find((item: any) => item.rect?.w > 0 && item.rect?.h > 0) ?? null, 10000);
  const root = (await query("fixture.window"))[0];
  const initial = await request("GET", "/app/bmc-fixture/stats");
  assert(initial.texture && initial.frame_revision === 1, "Initial texture must be uploaded");
  const colors = [[240, 100, 40], [50, 180, 230], [0, 0, 0], [240, 100, 40], [50, 180, 230], [0, 0, 0], [50, 180, 230], [240, 100, 40]];
  for (const [i, rgb] of colors.entries()) {
    assert((await request("POST", "/app/bmc-fixture/frame", { red: rgb[0], green: rgb[1], blue: rgb[2] })).ok);
    await waitFor(async () => {
      const state = await request("GET", "/app/bmc-fixture/stats");
      return state.texture === initial.texture && state.frame_revision === i + 2 ? state : null;
    }, 10000);
    // Multiple later presentations expose stale retained surfaces that can
    // appear after the first correct rendering of each new texture update.
    await sleep(100);
    for (let j = 0; j < 3; j++) {
      const path = join(out, `frame-${i}-${j}.png`);
      assert((await screenshot(path)).ok);
      captures.push({ path, rgb });
      await sleep(60);
    }
  }
  const manifest = join(out, "captures.json");
  await writeFile(manifest, JSON.stringify({ window: root.rect, frame: frame.rect, captures }, null, 2));
  const python = `
import json, sys
from PIL import Image
with open(sys.argv[1]) as f: data = json.load(f)
window, frame = data['window'], data['frame']
for capture in data['captures']:
    with Image.open(capture['path']) as source:
        image = source.convert('RGB')
        for x, y in ((.25, .25), (.5, .5), (.75, .75)):
            point = (round((frame['x'] + frame['w'] * x) * image.width / window['w']),
                     round((frame['y'] + frame['h'] * y) * image.height / window['h']))
            actual = image.getpixel(point)
            assert max(abs(a - b) for a, b in zip(actual, capture['rgb'])) <= 2, (capture['path'], point, actual, capture['rgb'])
print('Verified', len(data['captures']), 'native presentations at three points each')
`;
  process.stdout.write(execFileSync("python3", ["-c", python, manifest], { encoding: "utf8" }));
  assert((await request("POST", "/quit")).ok);
  await Promise.race([exited, sleep(5000)]);
  assert.equal(app.exitCode, 0, "Fixture must close cleanly");
} finally {
  if (app.exitCode === null && app.signalCode === null) {
    try { await request("POST", "/quit"); } catch {}
    await Promise.race([exited, sleep(2000)]);
  }
  if (app.exitCode === null && app.signalCode === null) { app.kill("SIGTERM"); await exited; }
}
