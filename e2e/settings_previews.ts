/** Metal/Harness acceptance of production read-only planning components.
 * This controlled runner is not an additional product entry or plugin loader.
 * zig build settings-preview -Dtest-mode=true
 * node e2e/settings_previews.ts [--out DIR] [--theme sauber|dark|light]
 */
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, open, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { clickTestId, query, screenshot, sleep, stats, tree, waitFor, waitForServerReady } from "../zig-out/share/zenit/harness/client.ts";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const options: Record<string, string> = {};
for (let index = 0; index < args.length; index += 2) {
  if (!["--out", "--theme", "--binary"].includes(args[index]) || !args[index + 1]) throw new Error(`Invalid option ${args[index]}`);
  options[args[index]] = args[index + 1];
}
const theme = options["--theme"] ?? "sauber";
if (!["sauber", "dark", "light"].includes(theme)) throw new Error("Invalid theme");
const output = resolve(options["--out"] ?? join(root, `dist/ui-acceptance/settings-previews-${Date.now()}`));
const binary = resolve(options["--binary"] ?? join(root, "zig-out/bin/settings-preview-runner"));
const cases = {
  validation: ["校验示例", "0", "超时须大于 0；示例输入保留。"],
  incompatible: ["兼容性示例", "主版本不兼容时拒绝加载"],
  wait_sessions: ["等待会话结束 · 规划", "会话结束后才可重新加载"],
  acquisition: ["获取流程 · 规划"],
  loading: ["加载中 · 规划", "会话结束后才可重新加载"],
};
await mkdir(output, { recursive: true });
const report = {
  scope: "read-only planning view component acceptance; controlled model initialization; no product entry, installation, permission, or dynamic loading claim",
  entry_point: "src/settings_preview_runner.zig",
  binary,
  binary_sha256: createHash("sha256").update(await readFile(binary)).digest("hex"),
  theme,
  content_size: { width: 636, height: 628 },
  cases: [] as Record<string, unknown>[],
  status: "running",
};
function texts(node: Awaited<ReturnType<typeof tree>>): string[] {
  return [...(node.text ? [node.text] : []), ...(node.children ?? []).flatMap(texts)];
}
async function visible(id: string) {
  const node = (await query(id)).find(node => node.visible !== false && node.rect.w > 0 && node.rect.h > 0);
  if (!node) throw new Error(`Missing visible node: ${id}`);
  return node;
}
function expectText(node: Awaited<ReturnType<typeof tree>>, expected: string[]) {
  const actual = texts(node);
  for (const text of expected) if (!actual.includes(text)) throw new Error(`Missing text: ${text}`);
}
function findText(node: Awaited<ReturnType<typeof tree>>, text: string): Awaited<ReturnType<typeof tree>> | undefined {
  if (node.text === text) return node;
  for (const child of node.children ?? []) {
    const found = findText(child, text);
    if (found) return found;
  }
}
try {
  for (const [kind, expected] of Object.entries(cases)) {
    const isolated = await mkdtemp(join(tmpdir(), "zerowork-settings-preview-"));
    process.env.ZENIT_E2E_FILE_RPC_DIR = isolated;
    const log = await open(join(output, `${kind}.log`), "w");
    const child = spawn(binary, [`--preview-kind=${kind}`, `--theme=${theme}`], {
      cwd: root,
      env: { ...process.env, ZENIT_E2E_ISOLATE_POINTER: "1", ZENIT_E2E_BACKGROUND: "1" },
      stdio: ["ignore", log.fd, log.fd],
    });
    const ended = new Promise<void>(done => child.once("close", () => done()));
    const result: Record<string, unknown> = { kind, status: "running" };
    report.cases.push(result);
    try {
      await waitForServerReady();
      const before = await tree();
      const component = await visible("settings.preview.component");
      if (component.rect.w !== 636 || component.rect.h !== 628) throw new Error(`Incorrect content size: ${JSON.stringify(component.rect)}`);
      expectText(before, [...expected, "未发布", "待定义", "未授权"]);
      if ((await visible("settings.footer.state")).text !== "已保存") throw new Error("Preview dirtied settings");
      result.detail_rect = (await visible("settings.plugin.detail")).rect;
      result.footer_rect = (await visible("settings.footer")).rect;
      const facts: Record<string, unknown> = {};
      for (const field of ["version", "abi", ...(kind === "validation" ? ["example_timeout"] : [])]) {
        const rect = (await visible(`settings.plugin.fact.${field}`)).rect;
        if (rect.x !== 436 || rect.w !== 164 || rect.h !== 30) throw new Error(`Incorrect read-only well: ${JSON.stringify(rect)}`);
        facts[field] = rect;
      }
      result.readonly_fact_rects = facts;
      const summary = findText(before, "计划中");
      if (!summary || summary.rect.x !== 314 || summary.rect.w !== 266) throw new Error("Section summary does not match prototype alignment");
      result.summary_rect = summary.rect;
      await sleep(200);
      if (!(await screenshot(join(output, `${kind}.png`))).ok) throw new Error("Screenshot failed");
      await writeFile(join(output, `${kind}.tree.json`), JSON.stringify(await tree(), null, 2));
      // The real disabled native lifecycle control must leave the projection intact.
      await clickTestId("settings.plugin.lifecycle.readonly");
      expectText(await tree(), expected);
      if (!(await clickTestId("settings.plugin.back")).ok) throw new Error("Back click failed");
      await waitFor(async () => (await query("settings.plugin.detail")).length === 0 || null);
      const selected = await visible("settings.plugin.selected");
      const after = await tree();
      expectText(after, ["FTP / FTPS", "计划中", "Local · zsh", "SSH", "SFTP"]);
      if ((await visible("settings.footer.state")).text !== "已保存") throw new Error("Back navigation dirtied settings");
      await sleep(200);
      if (!(await screenshot(join(output, `${kind}-back.png`))).ok) throw new Error("Back screenshot failed");
      await writeFile(join(output, `${kind}-back.tree.json`), JSON.stringify(after, null, 2));
      result.selected_row = selected.rect;
      result.stats = await stats();
      result.status = "passed";
    } catch (error) {
      result.status = "failed";
      result.error = String(error);
      throw error;
    } finally {
      child.kill("SIGTERM");
      await ended;
      await log.close();
      await rm(isolated, { recursive: true, force: true });
    }
  }
  report.status = "passed";
} catch (error) {
  report.status = "failed";
  throw error;
} finally {
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
}
console.log(`5 planning components verified: ${output}`);
