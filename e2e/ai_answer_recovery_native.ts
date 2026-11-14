/** Production recovery renderer, isolated snapshots; manager dispatch is covered by Zig tests. */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, open, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';

const out = resolve(process.argv[2] ?? '/tmp/zerowork-answer-recovery');
await mkdir(out, { recursive: true });
const report: any = { checks: [] };
const shown = (n: any) => n && n.visible !== false && !n.hidden && n.rect?.w > 0 && n.rect?.h > 0;
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 10000);
const result = async () => (await visible('ai.recovery.preview.result')).text;

for (const fixture of ['unknown', 'cooldown', 'context', 'policy_changed']) {
  const rpc = await mkdtemp('/tmp/zw-answer-recovery-rpc-');
  process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
  const log = await open(join(out, `${fixture}.log`), 'w');
  const app = spawn(resolve('zig-out/bin/ai-recovery-preview'), [fixture], {
    env: { ...process.env, ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1' },
    stdio: ['ignore', log.fd, log.fd],
  });
  const ended = new Promise(resolve => app.once('close', resolve));
  try {
    await h.waitForServerReady(30000);
    for (const width of [600, 360]) {
      await h.resizeWindow(width, 320);
      await visible('ai.recovery');
      await h.sleep(250);
      const card = await visible('ai.recovery');
      for (const id of ['ai.recovery.answer', 'ai.recovery.edit', ...(fixture !== 'context' ? ['ai.recovery.regenerate'] : [])]) {
        const button = await visible(id);
        assert(button.rect.x >= card.rect.x && button.rect.x + button.rect.w <= card.rect.x + card.rect.w + .5);
        for (const child of button.children ?? []) if (child.text) {
          assert(child.rect.x >= button.rect.x && child.rect.x + child.rect.w <= button.rect.x + button.rect.w + .5, 'full action label fits');
        }
      }
      assert((await visible('ai.recovery.answer.hint')).text.includes('不执行命令'));
      if (fixture === 'unknown' || fixture === 'cooldown') assert((await visible('ai.recovery.regenerate.disabled_reason')).text.includes('先核实'));
      if (fixture === 'policy_changed') {
        const reason = (await visible('ai.recovery.reason')).text;
        assert(reason.includes('ZeroWork 设置在运行期间发生变化'));
        assert(!reason.includes('AiPolicyChanged'));
      }
      if (fixture === 'cooldown') assert((await visible('ai.recovery.cooldown')).text.includes('2 秒'));
      if (fixture === 'context') assert((await visible('ai.recovery.answer.disabled_reason')).text.includes('上下文压缩失败'));
      assert((await h.screenshot(join(out, `${fixture}-${width}.png`))).ok);
      await writeFile(join(out, `${fixture}-${width}.json`), JSON.stringify(card, null, 2));
    }
    await h.clickTestId('ai.recovery.answer');
    if (fixture === 'unknown') {
      await h.waitFor(async () => (await result())?.includes('仅重试答复') || null, 3000);
      await h.clickTestId('ai.recovery.regenerate');
      assert((await result())?.includes('仅重试答复'), 'disabled new plan dispatches no action');
    } else if (fixture === 'policy_changed') {
      await h.waitFor(async () => (await result())?.includes('仅重试答复') || null, 3000);
      await h.clickTestId('ai.recovery.regenerate');
      await h.waitFor(async () => (await result()) === '已请求新计划' || null, 3000);
    } else assert.equal(await result(), '等待恢复操作', 'disabled answer dispatches no action');
    await h.clickTestId('ai.recovery.details.toggle');
    const details = await visible('ai.recovery.details');
    const text = JSON.stringify(details);
    assert(text.includes(fixture === 'context' ? 'ContextCompactionFailed' : fixture === 'policy_changed' ? 'AiPolicyChanged' : 'ToolOutcomeUnknown'));
    assert(!text.includes('部分工具执行结果待核实'), 'details do not repeat the summary');
    await h.clickTestId('ai.recovery.edit');
    await h.waitFor(async () => (await result()) === '已回填问题' || null, 3000);
    report.checks.push(`${fixture}: 600/360 layout, full labels, visible reasons, action gates and diagnostics`);
  } finally {
    app.kill('SIGTERM');
    await Promise.race([ended, new Promise(resolve => setTimeout(resolve, 2000))]);
    if (app.exitCode === null && app.signalCode === null) { app.kill('SIGKILL'); await ended; }
    await log.close();
  }
}
await writeFile(join(out, 'report.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify(report));
