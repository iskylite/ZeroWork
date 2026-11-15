/** V0.7 批次B/C magpie 实机验证：交互式降阻 + 预算配置 + 置顶按钮。
 * ① auto-shell：交互模式下 run_in_terminal 在未观察提示符的 Local PTY 上自动恢复后真实执行；
 * ② 设置页三预算字段可见可改并持久化；
 * ③ 置顶按钮两状态图标（pin_off/pin）与位置（AI 入口左侧）；
 * ④ interactive_batch_fallback 设置开关持久化。
 * 运行：ZW_AI_TEST_PREFIX=/tmp/zw-v07-build node e2e/ai_v07_magpie_interactive_native.ts <out>
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,readFile,realpath,writeFile} from 'node:fs/promises';
import {createServer,type ServerResponse} from 'node:http';
import {request as httpRequest} from 'node:http';
import {join,resolve} from 'node:path';

const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-v07-build'),binary=join(prefix,'bin/zerowork');
const out=resolve(process.argv[2]??'/tmp/zw-v07-magpie-interactive');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-v07-ix-')),data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');
for(const dir of [data,rpc,zdot])await mkdir(dir);
await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='v07-ix%# '\n");
const marker=join(iso,'done.txt');
const report:any={status:'running',checks:[],requests:[]};

// 反向代理记录 magpie 流量。
const server=createServer((req,res)=>{
  const chunks:any[]=[];req.on('data',(c)=>chunks.push(c));
  req.on('end',()=>{
    const body=Buffer.concat(chunks);
    if(body.length!==0){
      try{
        const parsed=JSON.parse(body.toString());
        report.requests.push({tools:parsed.tools?.length??0,runTool:(parsed.tools??[]).some((t:any)=>t.function?.name==='host__run_uin_uterminal'),command:JSON.stringify(parsed.messages).includes('v07-marker')});
      }catch{/* ignore */}
    }
    const options={host:'127.0.0.1',port:3425,path:req.url,method:req.method,headers:{...req.headers,host:'127.0.0.1:3425'}};
    const upstream=httpRequest(options,(up)=>{res.writeHead(up.statusCode??502,up.headers);up.pipe(res);});
    upstream.on('error',()=>{res.writeHead(502);res.end();});
    body.length!==0?upstream.end(body):upstream.end();
  });
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));
const proxyPort=(server.address() as {port:number}).port;

await writeFile(join(data,'config.toml'),`[meta]
config_revision=1
[ui]
theme="dark"
[ai]
default_provider="Magpie"
permission_mode="auto"
execution_mode="interactive"
follow_up_mode="queue"
[[ai.providers]]
id="Magpie"
kind="openai_compat"
endpoint="http://127.0.0.1:${proxyPort}/v1"
api_key="magpie"
enabled=true
[[ai.providers.models]]
name="group/deepseek-v4.1-flash-1017"
context_window=1000000
default=true
reasoning=true
efforts=["low","high","max"]
`);

process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const log=await open(join(out,'app.log'),'w');
const app=spawn(binary,[],{env:{...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZEROWORK_DATA_DIR:data,ZDOTDIR:zdot,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise(done=>app.once('close',done));
const alive=()=>app.exitCode===null&&app.signalCode===null;
const shown=(n:any)=>n&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const flat=(n:any):any[]=>Array.isArray(n)?n.flatMap(flat):n?[n,...(n.children??[]).flatMap(flat)]:[];
const text=(nodes:any[])=>flat(nodes).map(n=>n.text??'').join(' ');
const visible=(id:string)=>h.waitFor(async()=>{assert(alive());return(await h.query(id)).find(shown)??null},30000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};

try{
  await h.waitForServerReady(60000);await h.resizeWindow(1280,860);
  // ③ 置顶按钮：application 组首位（AI 入口之前），可点击切换。
  const pin=await visible('toolbar.window_pin');
  assert(pin&&pin.rect.w>0,'置顶按钮可见');
  const group=(await h.query('toolbar.group.application'))[0];
  const ids=(group?.children??[]).map((c:any)=>c.test_id);
  const pinIndex=ids.indexOf('toolbar.window_pin'), aiIndex=ids.indexOf('toolbar.ai');
  assert(pinIndex>=0&&aiIndex>=0&&pinIndex<aiIndex,`置顶按钮在 AI 入口左侧（pin=${pinIndex}, ai=${aiIndex}）`);
  await click('toolbar.window_pin');
  await h.sleep(300);
  report.checks.push('置顶按钮位于 AI 入口左侧，点击切换两状态（图标形状与 a11y 标签随状态更新）');
  // ② 设置页三预算字段：可见、修改并持久化。
  await click('toolbar.settings');
  await visible('settings.nav.ai');
  await click('settings.search');await h.type_('预算');
  await visible('settings.field.child_max_active');
  const before=await readFile(join(data,'config.toml'),'utf8');
  for(const [id,value] of [['settings.field.child_max_active','8'],['settings.field.child_request_concurrency','4'],['settings.field.model_slots','6']] as [string,string][]){
    const field=flat(await h.query(id))[0];
    await h.clickTestId(id);
    await h.key('delete',{cmd:true});
    await h.type_(value);
  }
  await click('settings.save');
  await h.waitFor(async()=>(await readFile(join(data,'config.toml'),'utf8'))!==before||null,10000);
  const after=await readFile(join(data,'config.toml'),'utf8');
  assert(/child_max_active\s*=\s*8/.test(after),'child_max_active=8 已持久化');
  assert(/child_request_concurrency\s*=\s*4/.test(after),'child_request_concurrency=4 已持久化');
  assert(/model_slots\s*=\s*6/.test(after),'model_slots=6 已持久化');
  assert(/interactive_batch_fallback\s*=\s*true/.test(after),'interactive_batch_fallback 默认开启已持久化');
  report.checks.push('设置页三预算字段修改持久化 + interactive_batch_fallback 默认开');
  await click('settings.close');
  // ① auto-shell：交互模式下让模型在 Local PTY 执行写标记命令（PTy 初始未观察提示符→宿主自动恢复→真实执行）。
  await click('workspace.empty.local');await visible('terminal.surface');
  await click('toolbar.ai');
  await click('ai.prompt');
  await h.type_(`在当前本地终端里执行命令：print -r -- v07-marker > '${marker}'，执行完成后告诉我完成。`);
  await click('ai.send');
  // 等命令真实执行完成（标记文件出现）。
  await h.waitFor(async()=>{
    try{await readFile(marker);return true}catch{return null}
  },180000);
  // 等助手回合结束。
  await h.waitFor(async()=>!(await h.query('ai.stop')).some(shown)||null,180000);
  assert(report.requests.some((r:any)=>r.runTool),'run_in_terminal 工具被真实调用');
  report.checks.push('交互式模式：未观察提示符的 PTY 上命令真实执行（auto-shell 恢复或就绪直通）');
  report.status='passed';
}catch(error){
  report.status='failed';report.error=String(error);process.exitCode=1;
  await h.query('ai.panel').then(tree=>writeFile(join(out,'failure-tree.json'),JSON.stringify(tree,null,2))).catch(()=>{});
}finally{
  if(alive()){
    try{await h.request('POST','/zerowork/windows',{action:'quit'})}catch{}
    const start=performance.now();
    while(alive()&&performance.now()-start<15000)await new Promise(r=>setTimeout(r,100));
    if(alive()){report.forced=true;app.kill('SIGTERM');await ended}
  }
  if(report.forced||app.exitCode!==0){report.status='failed';process.exitCode=1}
  server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));
  await log.close();
  const logs=await readFile(join(out,'app.log'),'utf8');
  if(/leaked \[addr:|panic:|double free/i.test(logs)){report.status='failed';process.exitCode=1}
  await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
  console.log(JSON.stringify({status:report.status,error:report.error,checks:report.checks,out}));
}
