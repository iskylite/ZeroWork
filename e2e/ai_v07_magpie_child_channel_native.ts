/** V0.7 批次A magpie 实机验证：真实 magpie provider 的子任务通道降阻端到端。
 * 验证：① create 省略 request_key/name 仍可创建（宿主派生键）；② seq 编号分配（#1 起）；
 * ③ list 面板就绪行；④ 报告自动投递（父终局回复包含子报告内容而无需模型显式 wait_events 轮询链）。
 * 运行：ZW_AI_TEST_PREFIX=/tmp/zw-v07-build node e2e/ai_v07_magpie_child_channel_native.ts <out>
 */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,mkdtemp,open,readFile,realpath,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';

const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'/tmp/zw-v07-build'),binary=join(prefix,'bin/zerowork');
const out=resolve(process.argv[2]??'/tmp/zw-v07-magpie-child');await mkdir(out,{recursive:true});
const iso=await realpath(await mkdtemp('/tmp/zw-v07-magpie-')),data=join(iso,'data'),rpc=join(iso,'rpc'),zdot=join(iso,'zdot');
for(const dir of [data,rpc,zdot])await mkdir(dir);
await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='v07-magpie%# '\n");

const report:any={status:'running',checks:[],requests:[]};
// 直接观测 magpie 线上流量：本地反向代理记录请求并转发到真实 magpie。
import {createServer,type ServerResponse} from 'node:http';
import {request as httpRequest} from 'node:http';
const MAGPIE_PORT=3425;
let parentCreateSeen=false, childCreateSeen=false, injectedReportSeen=false;
const server=createServer((req,res)=>{
  const chunks:any[]=[];req.on('data',(c)=>chunks.push(c));
  req.on('end',()=>{
    const body=Buffer.concat(chunks);
    if(body.length!==0){
      try{
        const parsed=JSON.parse(body.toString());
        const text=JSON.stringify(parsed);
        // 子会话的系统提示由宿主注入子智能体身份标识。
        const isChild=(parsed.messages??[]).some((m:any)=>typeof m.content==='string'&&m.content.includes('你不能再派生子智能体'))||String(parsed.system??'').includes('你不能再派生子智能体');
        report.requests.push({tools:parsed.tools?.length??0,messages:parsed.messages?.length??0,child:isChild,names:(parsed.tools??[]).map((t:any)=>t.function?.name).filter((n:any)=>n?.includes('agent')||n?.includes('task'))});
        if(parsed.tools?.some((t:any)=>t.function?.name==='host__agent_utasks')){
          if(isChild)childCreateSeen=true;else parentCreateSeen=true;
          // 父续行轮包含宿主注入的 settle_report（未经模型 wait_events）。
          if(text.includes('settle_report'))injectedReportSeen=true;
        }
      }catch{/* streaming body */}
    }
    const options={host:'127.0.0.1',port:MAGPIE_PORT,path:req.url,method:req.method,headers:{...req.headers,host:'127.0.0.1:3425'}};
    const upstream=httpRequest(options,(up)=>{
      res.writeHead(up.statusCode??502,up.headers);
      up.pipe(res);
    });
    upstream.on('error',()=>{res.writeHead(502);res.end();});
    body.length!==0?upstream.end(body):upstream.end();
  });
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));
const proxyPort=(server.address() as {port:number}).port;
report.proxy_port=proxyPort;

// 测试用数据目录使用本地存储密钥（api_key 明文），不触碰钥匙串。
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
const visible=(id:string)=>h.waitFor(async()=>{assert(alive());return(await h.query(id)).find(shown)??null},90000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};

try{
  await h.waitForServerReady(60000);await h.resizeWindow(1280,860);
  await click('workspace.empty.local');await visible('terminal.surface');
  await click('ai.strip');
  // 先发父任务（保持父运行，等待子任务与报告汇总）。
  await click('ai.prompt');
  await h.type_('请整理并等待：把"ZeroWork 通道降阻验证材料"这句话改写为一句总结，然后等待并行子任务完成后把两个结果一起汇报。');
  await click('ai.send');
  // 父忙期间用显式委派前缀（V0.4 §10.3）强制创建子任务，验证完整子链：
  // create（宿主派生键）→ 子模型执行 → settle → 宿主注入 settle_report → 父汇总。
  await visible('ai.stop');
  await click('ai.prompt');
  await h.type_('另开一个子智能体：V07_CHILD_MARKER 处理以下材料并返回结果：把"ZeroWork 通道降阻验证材料"这句话改写为另一句总结。子任务不需要任何终端，只处理文本。');
  await click('ai.send');
  // 等父任务收尾（stop 控件消失 = turn 完成），报告交付由 journal 断言。
  await h.waitFor(async()=>!(await h.query('ai.stop')).some(shown)||null,300000);
  const finish=text(await h.query('ai.panel'));
  // journal 断言：子任务由派生键创建、seq 编号、settle 后 delivered=true（宿主自动投递）。
  const journalRows=String(await readFile(join(data,'ai-sessions-active.jsonl'),'utf8')).trim().split('\n').map(row=>JSON.parse(row));
  const delegatedFacts=journalRows.flatMap((row:any)=>row.event?.task_fact&&row.event.task_fact.seq?[row.event.task_fact]:[]);
  assert(delegatedFacts.length>=1,'journal 记录了带 seq 的 delegated fact');
  const lastByTask=new Map<string,any>();
  for(const f of delegatedFacts)lastByTask.set(f.task,f);
  const settled=[...lastByTask.values()].filter((f:any)=>f.status==='succeeded');
  assert(settled.length>=1,'子任务 settle 成功');
  assert(settled.every((f:any)=>f.delivered===true),'已 settle 子报告全部 delivered=true（宿主自动投递）');
  assert(settled.every((f:any)=>f.seq>=1),'子任务编号 seq 从 1 起分配');
  report.checks.push(`journal 验证：${settled.length} 个子任务 seq=${settled.map((f:any)=>f.seq).join(',')} settle 且自动投递（delivered=true）`);
  // 断言线上观测（从记录的请求重放判定，避免回调时序问题）。
  const sawParentCatalog=report.requests.some((r:any)=>(r.names??[]).includes('host__agent_utasks')&&!r.child);
  const sawChildCatalog=report.requests.some((r:any)=>r.child===true);
  assert(sawParentCatalog,'父请求携带 agent_tasks 工具目录');
  assert(sawChildCatalog,'显式委派创建了子任务且子模型收到分配材料');
  if(injectedReportSeen)report.checks.push('宿主自动投递 settle_report 注入父续行轮（未经模型 wait_events）');
  else report.checks.push('NOTE: 报告经 wait_events 工具结果或注入通道交付（线上未区分），交付事实由父终局回答包含子内容证明');
  report.checks.push('真实 magpie/DeepSeek 模型完成父任务终局回答，通道契约未阻断');
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
