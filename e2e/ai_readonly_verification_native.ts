/** Isolated production verification UI; exact native-worker checks live in Zig tests. */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, open, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';
const out = resolve(process.argv[2] ?? '/tmp/zw-readonly-verification');
await mkdir(out, { recursive: true });
const checks: string[] = [];
const shown = (node: any) => node && !node.hidden && node.visible !== false && node.rect?.w > 0 && node.rect?.h > 0;
const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 10000);
for (const fixture of ['verification', 'verification_stale', 'verification_legacy']) {
  process.env.ZENIT_E2E_FILE_RPC_DIR = await mkdtemp('/tmp/zw-verify-rpc-');
  const log = await open(join(out, fixture + '.log'), 'w');
  const app = spawn(resolve('zig-out/bin/ai-recovery-preview'), [fixture], { env: { ...process.env, ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1' }, stdio: ['ignore', log.fd, log.fd] });
  const ended = new Promise(resolve => app.once('close', resolve));
  try {
    await h.waitForServerReady(30000);
    await visible('ai.verification');
    const before = (await visible('ai.recovery.preview.result')).text;
    await h.clickTestId('ai.verification.check');
    if (fixture === 'verification_legacy') assert.equal((await visible('ai.recovery.preview.result')).text, before);
    else {
      await h.waitFor(async () => (await visible('ai.recovery.preview.result')).text?.includes('原目标 #101 / 3') || null, 3000);
      const text = (await visible('ai.verification.evidence')).text;
      assert(text?.includes(fixture === 'verification' ? '退出码 0' : '原连接或服务已失效'));
    }
    const after = (await visible('ai.recovery.preview.result')).text;
    await h.clickTestId('ai.recovery.regenerate');
    assert.equal((await visible('ai.recovery.preview.result')).text, after, 'new plan stays disabled after observation');
    for (const width of [600, 360]) {
      await h.resizeWindow(width, 640);
      await h.sleep(250);
      const card = await visible('ai.verification');
      for (const id of ['ai.verification.check', 'ai.verification.evidence']) for (const node of (await h.query(id)).filter(shown)) {
        assert(node.rect.x >= card.rect.x - .5 && node.rect.x + node.rect.w <= card.rect.x + card.rect.w + .5, 'content fits supported width');
      }
      assert((await h.screenshot(join(out, `${fixture}-${width}.png`))).ok);
      await writeFile(join(out, `${fixture}-${width}.json`), JSON.stringify(card, null, 2));
    }
    checks.push(`${fixture}: original target, evidence, disabled new plan, 600/360 layout`);
  } finally {
    app.kill('SIGTERM');
    await Promise.race([ended, new Promise(resolve => setTimeout(resolve, 2000))]);
    if (app.exitCode === null && app.signalCode === null) { app.kill('SIGKILL'); await ended; }
    await log.close();
  }
}
await writeFile(join(out, 'report.json'), JSON.stringify({ status: 'passed', checks }, null, 2));
console.log(JSON.stringify({ status: 'passed', checks }));
