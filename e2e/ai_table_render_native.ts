/** Native Markdown table clipping regression, using an isolated local provider. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,open,writeFile,rm} from 'node:fs/promises';
import {join,resolve} from 'node:path';

const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'zig-out');
const out=resolve(process.argv[2]??'/tmp/zw-ai-table-evidence');
await mkdir(out,{recursive:true});
const iso=await mkdtemp('/private/tmp/zw-ai-table-'),data=join(iso,'data'),rpc=join(iso,'rpc');
await mkdir(data);await mkdir(rpc);process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const answer='目录里大致是：\n\n| 文件 | 看起来是什么 |\n| --- | --- |\n'+
 '| `clusconf-4.5.2-11.20260915+git9751ee03.x86_64.rpm`、`clusconf.yaml` | 集群配置工具及其配置 |\n'+
 '| `clusbench-4.5.1-1120.x86_64.rpm`、`clusbench.yaml` | 集群基准测试包及其配置 |\n'+
 '| `cluskit-0.6.2-1...run`、`cluskit-0.6.2-3...run` | 两个版本的 cluskit 安装脚本 |\n'+
 '| `hpc-26.07.0-48.mlnx.x86_64.rpm` | Mellanox/NVIDIA HPC 相关包 |\n'+
 '| `x.py` | 一个 Python 脚本，用途从文件名看不出来 |\n\nTABLE_COMPLETE：核对安装材料。';
let requests=0;
const server=createServer(async(req,res)=>{
 for await(const _ of req){}
 if(req.method!=='POST')return res.end('{"data":[{"id":"table-fixture"}]}');
 requests++;
 res.writeHead(200,{'content-type':'text/event-stream'});
 res.end('data: '+JSON.stringify({choices:[{index:0,delta:{content:answer}}]})+'\n\ndata: [DONE]\n\n');
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));
await writeFile(join(data,'config.toml'),`[meta]\nconfig_revision=1\n[ui]\ntheme="sauber"\nfont_size=14\n[ai]\ndefault_provider="fixture"\n[[ai.providers]]\nid="fixture"\nkind="openai_compat"\nendpoint="http://127.0.0.1:${(server.address()as any).port}/v1/chat/completions"\nenabled=true\n[[ai.providers.models]]\nname="table-fixture"\ncontext_window=200000\ndefault=true\n`);
const log=await open(join(out,'app.log'),'w');
const app=spawn(join(prefix,'bin/zerowork'),[],{env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},stdio:['ignore',log.fd,log.fd]});
const ended=new Promise<void>(done=>app.once('close',()=>done()));
const shown=(n:any)=>n&&n.visible!==false&&!n.hidden&&(n.effective_opacity??1)>0&&n.rect?.w>0&&n.rect?.h>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
const click=async(id:string)=>{await visible(id);assert((await h.clickTestId(id)).ok,id)};
const text=(n:any):string=>n?[n.text??'',...(n.children??[]).map(text)].join(' '):'';
const report:any={status:'running',checks:[]};
try{
 await h.waitForServerReady();await h.resizeWindow(1440,1000);
 await click('workspace.empty.local');await click('toolbar.ai');await click('ai.prompt');
 await h.type_('检查目录文件');await click('ai.send');
 await h.waitFor(async()=>text((await h.query('ai.conversation')).find(shown)).includes('TABLE_COMPLETE')||null,20000);
 await h.waitFor(async()=>!(await h.query('ai.stop')).some(shown)||null,15000);
 for(const [width,height] of [[1440,1000],[860,700]]){
  await h.resizeWindow(width,height);
  const table=await visible('ai.message.table');
  const content=table.children[0];assert.equal(content.children.length,6);
  for(const row of content.children){
   for(const cell of row.children){
    for(const paragraph of cell.children[0].children??[]){
     assert(paragraph.rect.y+paragraph.rect.h<=cell.rect.y+cell.rect.h-6+.2,'wrapped text must fit inside cell padding');
    }
   }
  }
  assert(Math.abs(content.rect.h-table.rect.h)<.2,'horizontal viewport must contain full table height');
  await writeFile(join(out,`table-${width}.json`),JSON.stringify(table,null,2));
  await h.mouseMove(1,1);assert((await h.screenshot(join(out,`table-${width}.png`))).ok);
  report.checks.push({width,height,table:table.rect,rows:content.children.map((n:any)=>n.rect.h)});
 }
 assert.equal(requests,1);report.status='passed';
}catch(error){report.status='failed';report.error=String(error);process.exitCode=1;await h.screenshot(join(out,'failure.png')).catch(()=>{});}
finally{
 app.kill('SIGTERM');await Promise.race([ended,h.sleep(2000)]);
 if(app.exitCode===null&&app.signalCode===null){app.kill('SIGKILL');await ended;}
 await log.close();await new Promise<void>(done=>server.close(()=>done()));await rm(iso,{recursive:true,force:true});
 await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
}
console.log(report.status+': '+join(out,'report.json'));
