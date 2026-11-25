/** Native, background-only acceptance for the standalone AI Files inspector.
 * Build with -Dtest-mode=true. No production provider, SSH, real Keychain, saved user
 * preferences or system-wide UI scripting. Fixtures are removed on exit. */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { mkdir, mkdtemp, readFile, readdir, realpath, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { createServer, type ServerResponse } from 'node:http';
import { join, resolve } from 'node:path';

const diffTrial = process.argv.includes('--workspace-turn-diff');
const diffPrompt = 'Write an isolated verification marker';
const nextPrompt = 'Explain the last status without doing any work';
const diffBody = 'verified file change from this turn\n';
let diffWrites = 0;
const referenceSwitch = process.argv.includes('--workspace-reference-switch');
const referenceTrial = referenceSwitch || process.argv.includes('--workspace-reference');
const originalText = 'Original preview sentence.\nUTF-8: 已经预览。\n';
const changedText = 'Latest preview sentence.\nUTF-8: 发这个版本。\n';
const approved: string[] = [];
let failTrial = false;

const prefix = resolve(process.env.ZW_AI_TEST_PREFIX ?? 'zig-out');
const root = await realpath(await mkdtemp(join(tmpdir(), 'zw-inspector-')));
let child: ReturnType<typeof spawn> | undefined;
let shutdown: Promise<unknown> | undefined;
let log = '';
const holds = new Map<string, ServerResponse>();
const prompts: Record<string,string> = { A: 'private prompt for page Alpha', B: 'private prompt for page Beta' };
const imageFixture = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAACgAAAAYCAYAAACIhL/AAAAAN0lEQVR4nO3OMREAIAAAIbtYyPTW0RTeOzCwM/Zc52ejDggK1gFBwTogKFgHBAXrgKBgHRB87QJEpo55DU5mIwAAAABJRU5ErkJggg==', 'base64');
const frame = (content:string) => 'data: ' + JSON.stringify({choices:[{index:0,delta:{content}}]}) + '\n\n';
const fixtureErrors: string[] = [];
const server = createServer(async (req,res) => {
  try {
    if (req.method !== 'POST') { res.setHeader('content-type','application/json'); res.end(JSON.stringify({data:[{id:'fixture'}]})); return; }
    let raw = ''; for await (const data of req) raw += data;
    const body = JSON.parse(raw);
    const messageEnvelope = JSON.stringify(body.messages || []);
    assert(!messageEnvelope.includes('preview-fixture.png') && !messageEnvelope.includes('data:image/'), 'opening an image must not attach it or send its path to the model');
    const user = body.messages?.filter((m:any) => m.role === 'user') || [];
    const wire = JSON.stringify(user);
    const lastUser = user.at(-1)?.content;
    if (diffTrial && body.tools?.length) {
      const prompt = user.findLast((item:any) => [diffPrompt, nextPrompt].includes(item.content))?.content;
      res.writeHead(200, {'content-type': 'text/event-stream'});
      if (prompt === nextPrompt) { res.end(frame('WORKSPACE_DIFF_NEXT')+'data: [DONE]\n\n'); return; }
      assert.equal(prompt, diffPrompt);
      const writeTool = 'host__local_uwrite_utext';
      assert(body.tools.some((item:any) => item.function.name === writeTool), 'group must advertise authorized Local workspace write');
      const result = body.messages.find((message:any) => message.role === 'tool' && message.tool_call_id === 'diff-real-write');
      if (result) {
        const wireResult = JSON.parse(result.content);
        assert.equal(wireResult.status, 'succeeded');
        assert(result.content.includes('managed_local_file_tools'));
        diffWrites += 1;
        res.end(frame('WORKSPACE_DIFF_COMPLETE')+'data: [DONE]\n\n');
        return;
      }
      res.end('data: '+JSON.stringify({choices:[{index:0,delta:{tool_calls:[{index:0,id:'diff-real-write',type:'function',function:{name:writeTool,arguments:JSON.stringify({path:'src/created.txt',mode:'create',text:diffBody,request_key:'diff-real-write'})}}]}}]})+'\n\ndata: [DONE]\n\n');
      return;
    }
    if (referenceTrial && typeof lastUser === 'string' && lastUser.includes('<workspace_text_attachment>')) {
      assert.equal(req.headers.authorization, undefined, 'the file trial cannot use a model credential');
      assert.equal((body.tools || []).length, 0, 'the file trial cannot offer agent tools');
      assert(!wire.includes(root), 'the model must not receive the absolute workspace path');
      const match = lastUser.match(/<workspace_text_attachment>\nrelative_path="src\/guide.txt"\nbytes=(\d+)\ntext:\n([\s\S]*)\n<\/workspace_text_attachment>$/);
      assert(match, 'expected one exact file attachment body');
      assert.equal(Buffer.byteLength(match[2]), Number(match[1]));
      approved.push(match[2]);
      if (failTrial) { res.writeHead(429, {'retry-after':'0'}); res.end('synthetic limit'); return; }
      res.writeHead(200, {'content-type':'text/event-stream'});
      res.end(frame('WORKSPACE_TRIAL_COMPLETE')+'data: [DONE]\n\n');
      return;
    }
    assert(!wire.includes(originalText) && !wire.includes(changedText), 'raw text leaked outside its bounded provider request');
    const matched = Object.keys(prompts).filter(k => wire.includes(prompts[k]));
    res.writeHead(200,{'content-type':'text/event-stream'});
    if (!body.tools?.length && (!matched.length || holds.has(matched[0]))) {res.end(frame('Fixture title')+'data: [DONE]\n\n');return;}
    if (matched.length !== 1 || holds.has(matched[0])) {throw new Error('duplicate or cross-page model request: '+JSON.stringify(matched));}
    const key = matched[0]; holds.set(key, res); res.write(frame(key+'_STREAM_START'));
  } catch (e) { fixtureErrors.push(String(e)); res.end(); }
});
try {
  const data = join(root, 'data'), rpc = join(root, 'rpc'), project = join(root, 'Example');
  for (const path of [data, rpc, project, join(project, 'src'), join(data, 'credentials')]) await mkdir(path, { mode: 0o700 });
  await writeFile(join(data, 'credentials', '.local-storage'), '1', { mode: 0o600 });
  await writeFile(join(project, 'src', 'example.zig'), 'const answer = 42;\n// from the selected directory\n');
  if (referenceTrial) await writeFile(join(project, 'src', 'guide.txt'), originalText);
  await writeFile(join(root, 'private.txt'), 'out-of-scope marker');
  await symlink(join(root, 'private.txt'), join(project, 'alias'));
  // Restore one explicitly selected workspace on the first tab. A second
  // freshly created AI tab must not inherit the root or rendered source.
  const port = await new Promise<number>((ok,fail)=>{server.once('error',fail);server.listen(0,'127.0.0.1',()=>ok((server.address() as {port:number}).port));});
  // The only model is a controlled loopback fixture. It holds two responses
  // open together; distinct prompts and response markers verify real routing.
  await writeFile(join(data, 'config.toml'), '[meta]\nconfig_revision=1\n[ai]\ndefault_provider="fixture"\n[[ai.providers]]\nid="fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:'+port+'/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="fixture"\ncontext_window=200000\ndefault=true\n');
  const identity = await stat(project), agent = randomBytes(16).toString('hex'), conversation = randomBytes(16).toString('hex');
  const baseline = [
    { schema: 1, event: { kind: 'create', conversation, agent, owner: diffTrial ? {group:1} : { session: 1 }, revision: 2 } },
    { schema: 4, event: { kind: 'workspace_update', conversation, agent, revision: 2,
      workspace: { revision: 2, availability: 'ready', directory: project, resolved_directory: project, directory_identity: { device: identity.dev, inode: identity.ino } },
      workspace_change: { before_revision: 1, reason: 'set' } } },
    { schema: 1, event: { kind: 'checkpoint', conversation, agent, revision: 2, turn: 1 }, messages: [{ role: 'user', content: 'fixture' }] },
  ];
  await writeFile(join(data, 'ai-sessions.jsonl'), baseline.map(v => JSON.stringify(v)).join('\n') + '\n', {mode: 0o600});
  process.env.ZENIT_E2E_FILE_RPC_DIR = rpc;
  const h = await import(join(prefix, 'share/zenit/harness/client.ts'));
  const trialEndpoint = referenceTrial ? 'http://127.0.0.1:'+port+'/v1/chat/completions' : '';
  child = spawn(join(prefix, 'bin/zerowork'), [], { env: {
    ...process.env, ZEROWORK_DATA_DIR: data, ZEROWORK_AUTOCONNECT: '0',
    ZENIT_E2E_BACKGROUND: '1', ZENIT_E2E_ISOLATE_POINTER: '1', ZW_TEST_CREDENTIAL_RESPONSE: 'cancel',
    OPENAI_API_KEY: '', ANTHROPIC_API_KEY: '', ZDOTDIR: root,
    ...(referenceTrial ? { ZW_TEST_WORKSPACE_FILE_ENDPOINT: trialEndpoint } : {}),
  }, stdio: ['ignore', 'ignore', 'pipe'] });
  child.stderr?.on('data', (bytes: Buffer) => { log = (log + String(bytes)).slice(-4500); });
  shutdown = new Promise(done => child!.once('close', done));
  const shown = (n: any) => !n.hidden && n.visible !== false && (n.effective_opacity ?? 1) > 0 && n.rect?.w > 0 && n.rect?.h > 0;
  const visible = (id: string) => h.waitFor(async () => (await h.query(id)).find(shown) ?? null, 12000);
  const flatten = (n: any): any[] => Array.isArray(n) ? n.flatMap(flatten) : n ? [n, ...(n.children ?? []).flatMap(flatten)] : [];
  const content = (n: any) => flatten(n).filter(shown).map(n => n.text || '').join(' ');
  let step = '';
  const click = async (id: string) => {
    step = id;
    const node = await visible(id);
    const located = referenceTrial && id.startsWith('ai.workspace.file.')
      ? await h.clickAt(node.rect.x + node.rect.w / 2, node.rect.y + node.rect.h / 2)
      : await h.clickTestId(id);
    assert(located.ok, JSON.stringify(located));
  };
  try {
    await h.waitForServerReady(16000);
    assert.equal(Number(JSON.parse(await readFile(join(rpc, 'owner.json'), 'utf8')).pid), child.pid);
    await h.resizeWindow(diffTrial ? 1660 : 1280, diffTrial ? 1000 : 800);
    if (diffTrial) {
      await click('workspace.empty.local');
      await visible('terminal.surface');
      const chooseContext = async (node:any) => {
        const point = {x:node.rect.x+node.rect.w/2, y:node.rect.y+node.rect.h/2, button:'right'};
        assert((await h.request('POST','/mouse_down',point)).ok);
        assert((await h.request('POST','/mouse_up',point)).ok);
      };
      const localTab = flatten((await h.query('tabs.strip')).find(shown)).find(n=>shown(n)&&/^tabs\.tab\.\d+$/.test(n.test_id||''));
      assert(localTab);
      await click(localTab.test_id);
      await chooseContext(await visible(localTab.test_id));
      await click('context.menu.join_session_group');
      await click('groups.join.name'); assert((await h.type_('Diff test group')).ok);
      await click('groups.join.accept');
      await click('groups.tab');
      await visible('groups.workspace');
      await click('toolbar.ai');
      await click('ai.sessions');
      await click('ai.session.restore.2');
      step = 'restored group data authority';
      await h.waitFor(async () => content(await h.query('ai.workspace.name')).includes('Example') || null, 16000);
      await click('toolbar.new_session');
      await click('session.menu.ai');
      await visible('ai.workspace.shell');
      const aiTab = await h.waitFor(async () => flatten((await h.query('tabs.strip')).find(shown))
        .find(n=>shown(n) && /^tabs\.tab\.\d+$/.test(n.test_id||'') && content(n).includes('AI Agent')) ?? null, 12000);
      await chooseContext(aiTab);
      await click('context.menu.join_session_group');
      await click('groups.join.existing');
      await click('groups.tab');
      await visible('ai.workspace.shell');
      step = 'actual group AI workspace binding';
      await h.waitFor(async () => content(await h.query('ai.workspace.workspace')).includes('Example') || null, 16000);
      const submitDiff = async (prompt:string) => {
        await click('ai.prompt');
        assert((await h.type_(prompt)).ok);
        assert((await h.key('return')).ok);
      };
      await submitDiff(diffPrompt);
      step = 'explicit actual managed write approval';
      await h.waitFor(async () => content(await h.query('ai.interaction.target')).includes(join(project, 'src', 'created.txt')) || null, 18000);
      await assert.rejects(stat(join(project, 'src', 'created.txt')), {code:'ENOENT'});
      await click('ai.interaction.approve');
      step = 'actual write confirmed with real provider tool receipt';
      await h.waitFor(async () => content(await h.query('ai.workspace.shell')).includes('WORKSPACE_DIFF_COMPLETE') && diffWrites === 1 || null, 18000);
      assert.equal(await readFile(join(project,'src','created.txt'),'utf8'), diffBody);
      assert(!(await h.query('ai.workspace.preview.diff')).some(shown), 'Diff requires an active text preview');
      if (!(await h.query('ai.workspace.inspector')).some(shown)) await click('ai.workspace.inspector.toggle');
      await click('ai.workspace.files.refresh');
      await click('ai.workspace.file.0');
      step = 'new managed file visible';
      await h.waitFor(async () => content(await h.query('ai.workspace.files')).includes('created.txt') || null, 12000);
      await click('ai.workspace.file.1');
      step = 'source text still shown before choosing Diff';
      await h.waitFor(async () => content(await h.query('ai.workspace.preview')).includes(diffBody.trimEnd()) || null, 12000);
      assert(!content(await h.query('ai.workspace.preview')).includes('+1'));
      await click('ai.workspace.preview.diff');
      step = 'verified one-operation Diff visible';
      await h.waitFor(async () => content(await h.query('ai.workspace.preview')).includes('+1 '+diffBody.trimEnd()) || null, 12000);
      assert(content(await h.query('ai.workspace.preview.diff.status')).includes('不代表整个回合'));
      await click('ai.workspace.preview.source');
      await click('ai.workspace.file.2');
      step = 'another file remains source';
      await h.waitFor(async () => content(await h.query('ai.workspace.preview')).includes('const answer = 42') || null, 12000);
      await click('ai.workspace.preview.diff');
      await h.waitFor(async () => content(await h.query('ai.workspace.preview.diff.status')).includes('已保留源码') || null, 12000);
      assert(content(await h.query('ai.workspace.preview')).includes('const answer = 42'));
      assert(!content(await h.query('ai.workspace.preview')).includes(diffBody.trimEnd()));
      await click('ai.workspace.inspector.close');
      await submitDiff(nextPrompt);
      step = 'older receipt is not reachable from the new visible turn';
      await h.waitFor(async () => content(await h.query('ai.workspace.shell')).includes('WORKSPACE_DIFF_NEXT') || null, 15000);
      await click('ai.workspace.inspector.toggle');
      await visible('ai.workspace.preview');
      assert(!(await h.query('ai.workspace.preview.diff')).some(shown));
      assert(content(await h.query('ai.workspace.preview')).includes('const answer = 42'));
      assert.deepEqual(fixtureErrors, []);
      assert(!/keychain-access|keychain prompt/i.test(log));
      console.log('PASS: authorized real managed write → current visible group AI turn → verified single-operation Diff; different file keeps source; next turn revokes access; isolated Local credentials.');
    } else {
    await click('toolbar.new_session');
    await click('session.menu.ai');
    await visible('ai.workspace.shell');
    assert(!(await h.query('ai.workspace.file.0')).some(shown), 'historical root must not leak into new conversation');
    await click('ai.workspace.history');
    await click('ai.session.restore.2'); // explicit user recovery, never assume a saved binding is live
    await click('ai.workspace.file.0'); // src (directory)
    if (referenceTrial) {
      const previewText = async (label: string) => {
        await visible('ai.workspace.file.0');
        if (!content(await h.query('ai.workspace.files')).includes('guide.txt')) await click('ai.workspace.file.0');
        await h.waitFor(async () => content(await h.query('ai.workspace.files')).includes('guide.txt') || null, 12000);
        await click('ai.workspace.file.2');
        step = 'preview exact text: ' + label;
        await h.waitFor(async () => content(await h.query('ai.workspace.preview')).includes(label) || null, 10000);
        await visible('ai.workspace.preview.insert');
      };
      const attach = async () => {
        await click('ai.workspace.preview.insert');
        step = 'confirmation adds path only';
        await h.waitFor(async () => (await h.inputState('ai.prompt')).buffer === '@file: src/guide.txt' || null, 10000);
      };
      const rejected = async () => await h.waitFor(async () => content(await h.query('ai.feedback.text')).includes('请重新预览并引用') || null, 16000);
      const pressSend = async () => assert((await h.key('return')).ok);
      await previewText('Original preview sentence.');
      await attach();
      assert.deepEqual(approved, [], 'preview and attaching a draft must not send bytes');
      await writeFile(join(project, 'src', 'guide.txt'), changedText);
      step = 'changed between preview and Send';
      await pressSend();
      await rejected();
      assert.deepEqual(approved, []);
      await previewText('Latest preview sentence.');
      await attach();
      step = 'send fresh selection';
      await pressSend();
      await h.waitFor(async () => content(await h.query('ai.workspace.shell')).includes('WORKSPACE_TRIAL_COMPLETE') || null, 16000);
      assert.deepEqual(approved, [changedText]);

      if (referenceSwitch) {
        // A second tentative draft is revoked by leaving the bound AI surface.
        await previewText('Latest preview sentence.');
        await attach();
        await click('toolbar.new_session');
        await click('session.menu.ai');
        const tabs = flatten((await h.query('tabs.strip')).find(shown)).filter(n=>/^tabs\.tab\.\d+$/.test(n.test_id||'')).sort((x,y)=>x.rect.x-y.rect.x);
        assert.equal(tabs.length, 2);
        await click(tabs[0].test_id);
        step = 'restored UI draft does not retain file permission';
        await click('ai.prompt');
        await h.waitFor(async () => (await h.inputState('ai.prompt')).buffer === '@file: src/guide.txt' || null, 10000);
        await pressSend();
        await rejected();
        assert.deepEqual(approved, [changedText]);

      } else {
        // A retryable network result must not replay an authorized file body.
        await previewText('Latest preview sentence.');
        await attach();
        step = 'provider 429 must not replay the file';
        failTrial = true;
        await pressSend();
        await h.waitFor(() => approved.length === 2 || null, 16000);
        await rejected();
        await new Promise(resolve => setTimeout(resolve, 1500));
        assert.deepEqual(approved, [changedText, changedText]);

      }

      for (const entry of await readdir(data)) {
        if (!/^ai-sessions.*\.jsonl$/.test(entry)) continue;
        const journal = await readFile(join(data, entry), 'utf8');
        assert(!journal.includes('Original preview sentence.') && !journal.includes('Latest preview sentence.'), 'implicit journal must not contain file text');
        assert(!journal.includes('<workspace_text_attachment>'), 'provider-only content leaked to disk');
      }
      assert.deepEqual(fixtureErrors, []);
      assert(!/keychain-access|keychain prompt/i.test(log));
      console.log('PASS: real app previews and adds only a draft reference; changed file rejects; new selection sends exact UTF-8 once; no journal attachment body.');
      console.log(referenceSwitch ? 'PASS: leaving/reopening the originating AI tab does not restore the draft permission.' : 'PASS: retryable model result does not resend the attachment body.');
    } else {
    step = 'expanded source'; await h.waitFor(async () => content(await h.query('ai.workspace.files')).includes('example.zig') || null, 12000);
    await click('ai.workspace.file.1');
    step = 'disk text'; await h.waitFor(async () => content(await h.query('ai.workspace.preview')).includes('const answer = 42') || null, 12000);
    await click('ai.workspace.file.2'); // alias (symlink)
    step = 'symlink refusal'; await h.waitFor(async () => content(await h.query('ai.workspace.preview')).includes('不打开符号链接') || null, 12000);
    assert(!content(await h.query('ai.workspace.preview')).includes('out-of-scope marker'));
    await writeFile(join(project, 'src', 'preview-fixture.png'), imageFixture);
    await click('ai.workspace.files.refresh');
    step = 'fresh image row'; await h.waitFor(async () => content(await h.query('ai.workspace.files')).includes('preview-fixture.png') || null, 12000);
    await click('ai.workspace.file.2');
    step = 'native image preview';
    await h.waitFor(async () => (await h.query('ai.workspace.preview.image')).some(n => shown(n) && Math.abs(n.rect.w - 40) < 1 && Math.abs(n.rect.h - 24) < 1) || null, 12000);
    assert(!(await h.query('ai.image')).some(shown), 'preview must not make an attachment');
    await click('ai.workspace.file.1');
    step = 'return from raster to text';
    await h.waitFor(async () => content(await h.query('ai.workspace.preview')).includes('const answer = 42') || null, 12000);
    assert(!(await h.query('ai.workspace.preview.image')).some(shown), 'replacing the preview must remove the raster');
    await click('ai.workspace.file.2'); await visible('ai.workspace.preview.image');
    await click('ai.workspace.inspector.close');
    await h.waitFor(async () => !(await h.query('ai.workspace.inspector')).some(shown) || null, 12000);
    await click('toolbar.new_session'); await click('session.menu.ai');
    await visible('ai.workspace.shell');
    step = 'second tab isolation'; await h.waitFor(async () => !(await h.query('ai.workspace.file.0')).some(shown) || null, 12000);
    assert(!content(await h.query('ai.workspace.shell')).includes('const answer = 42'));
    assert(!(await h.query('ai.workspace.preview.image')).some(shown), 'a second tab must not inherit the raster');
    const tabs = flatten((await h.query('tabs.strip')).find(shown)).filter(n=>/^tabs\.tab\.\d+$/.test(n.test_id||'')).sort((x,y)=>x.rect.x-y.rect.x);
    assert.equal(tabs.length, 2);
    const send = async (key:string) => {
      await click('ai.prompt'); assert((await h.type_(prompts[key])).ok);
      await h.waitFor(async()=>(await h.inputState('ai.prompt')).buffer === prompts[key] || null,5000);
      step = 'send '+key; assert((await h.key('return')).ok);
      step = 'waiting on loopback request '+key;
      await h.waitFor(()=>holds.has(key) || null,16000);
    };
    await click(tabs[0].test_id);
    step = 'explicitly closed inspector stays closed on return';
    await h.waitFor(async () => content(await h.query('ai.workspace.workspace')).includes('Example') || null, 12000);
    assert(!(await h.query('ai.workspace.inspector')).some(shown), 'returning to the same workspace reopened a manually closed inspector');
    await send('A');
    await click(tabs[1].test_id); await send('B');
    assert(!holds.get('A')!.writableEnded && !holds.get('A')!.destroyed, 'A was canceled by switching tabs');
    for(const key of ['B','A']) holds.get(key)!.end(frame(key+'_ONLY_COMPLETE')+'data: [DONE]\n\n');
    for(const [index,id] of [[1,'B'],[0,'A']] as const) {
      await click(tabs[index].test_id);
      step = 'awaiting terminal response '+id;
      const actual = await h.waitFor(async()=>{const text=content(await h.query('ai.workspace.shell')); return text.includes(id+'_ONLY_COMPLETE') ? text : null;},15000);
      assert(!actual.includes((id==='A'?'B':'A')+'_ONLY_COMPLETE'), 'foreign response rendered');
    }
    assert.deepEqual(fixtureErrors,[]);
    console.log('PASS: authorized PNG renders at its natural aspect; a new file and tab clear it; no image or path enters the model request.');
    console.log('PASS: two independent real app tabs have overlapping loopback provider requests; reversed completion stays in its originating tab.');

    // The standalone history button is not a path out of a group's scope.
    const first = await visible(tabs[0].test_id);
    const point = {x:first.rect.x+10, y:first.rect.y+first.rect.h/2, button:'right'};
    await h.request('POST','/mouse_down',point); await h.request('POST','/mouse_up',point);
    await click('context.menu.join_session_group');
    await click('groups.join.name'); assert((await h.type_('Preview scope fixture')).ok);
    await click('groups.join.accept');
    await click('groups.tab');
    step = 'group history restriction';
    await h.waitFor(async () => content(await h.query('ai.workspace.shell')).includes('会话组 AI') || null, 12000);
    assert(!(await h.query('ai.workspace.history')).some(shown), 'global history must not be visible inside the group');
    console.log('PASS: the same AI tab moved into a real group no longer exposes global history.');

    assert(!/keychain-access|keychain prompt/i.test(log), 'unexpected credential use');
    console.log('PASS: actual app menu → standalone AI → directory → disk text; symlink refused, second tab isolated; local-only credentials.');
    }
    }
  } catch (e) {
    const tree = await h.tree().catch(() => null);
    const ids = flatten((tree as any)?.root ?? (tree as any)?.tree ?? tree).filter(shown).map(n => n.test_id).filter(Boolean);
    const details = await Promise.all(['ai.workspace.shell','ai.empty.configured','ai.empty.recent','ai.workspace.workspace','ai.sessions','ai.workspace.preview','ai.workspace.files','ai.workspace.file.0','ai.feedback.text','context.menu.join_session_group','groups.workspace','ai.interaction.target'].map(async id => [id,(await h.query(id)).map((n:any) => ({shown:shown(n),text:content(n).slice(0,220)}))]));
    throw new Error(`native step ${step || 'startup'}: ${e}; accepted file requests: ${approved.length}; fixture error: ${fixtureErrors.join("; ")}; sections: ${JSON.stringify(details)}; visible: ${ids.slice(0,90).join(',')}; ${log}`);
  }
} finally {
  if (child && child.exitCode == null && child.signalCode == null) child.kill('SIGTERM');
  if (shutdown) await shutdown;
  if (server.listening) {server.closeAllConnections(); await new Promise<void>(resolve => server.close(()=>resolve()));}
  await rm(root, {recursive:true, force:true});
}
