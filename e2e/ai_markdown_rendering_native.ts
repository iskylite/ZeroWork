/** Native AI Markdown regression. Uses an isolated data directory and loopback provider.
 * node e2e/ai_markdown_rendering_native.ts <test-mode binary> <output directory>
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtemp, mkdir, open, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
const binary = resolve(process.argv[2]), output = resolve(process.argv[3]);
const { waitForServerReady, waitFor, query, tree, clickTestId, key, type_, resizeWindow, screenshot, request, mouseDown, mouseMove, mouseUp, scrollAt, sleep } =
  await import(join(dirname(binary), "../share/zenit/harness/client.ts"));
const isolated = await realpath(await mkdtemp(join(tmpdir(), "zerowork-markdown-native-")));
const data = join(isolated,"data"), rpc = join(isolated,"rpc"), zdot = join(isolated,"zdot");
await Promise.all([mkdir(data),mkdir(rpc),mkdir(zdot),mkdir(output,{recursive:true})]);
await writeFile(join(zdot,".zshrc"),"PS1='markdown-test%# '\n");
const source = "# Markdown 回归验证\n\n- 父项\n  - 子项\n    - 孙项\n\n  ```sh\n  echo nested\n  ```\n\n> ## 引用标题\n> 引用正文\n\n" +
  "| A\\|B | C |\n| --- | --- |\n| a\\|b | **保留** |\n| `x\\|y` | 最后一列 |\n\n[组合 **链接 `code`**](https://example.com/a_(b))\n\nMARKDOWN_NATIVE_DONE";
const frame = (content: string) => `data: ${JSON.stringify({choices:[{index:0,delta:{content}}]})}\n\n`;
let requests = 0;
const server = createServer(async(req,res)=>{
  if(req.method==="GET") return res.end(JSON.stringify({data:[{id:"markdown-fixture"}]}));
  let raw=""; for await (const chunk of req) raw+=chunk;
  const body=JSON.parse(raw);
  res.writeHead(200,{"Content-Type":"text/event-stream"});
  if(body.messages[0]?.content?.startsWith("将用户的问题概括")) return res.end(frame("Markdown regression")+"data: [DONE]\n\n");
  requests++;
  // Exercise the real streaming path across a blank inside the list item.
  const split=source.indexOf("  ```sh");
  res.write(frame(source.slice(0,split)));
  setTimeout(()=>res.end(frame(source.slice(split))+"data: [DONE]\n\n"),100);
});
await new Promise<void>(done=>server.listen(0,"127.0.0.1",done));
const address=server.address(); assert(address&&typeof address!=="string");
await writeFile(join(data,"config.toml"),`[meta]
config_revision = 1
[ui]
theme = "dark"
[ui.materials.background]
enabled = false
[ai]
default_provider = "markdown-fixture"
permission_mode = "confirm"
[[ai.providers]]
id = "markdown-fixture"
kind = "openai_compat"
endpoint = "http://127.0.0.1:${address.port}/v1/chat/completions"
enabled = true
[[ai.providers.models]]
name = "markdown-fixture"
context_window = 200000
default = true
`);
const env={...process.env,ZENIT_E2E_FILE_RPC_DIR:rpc,ZENIT_E2E_BACKGROUND:"1",ZENIT_E2E_ISOLATE_POINTER:"1",ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:"0",ZDOTDIR:zdot,OPENAI_API_KEY:"",ANTHROPIC_API_KEY:""};
for(const name of ["ZEROWORK_AI_MOCK","ZEROWORK_AI_ENDPOINT","ZEROWORK_AI_MODEL","ZEROWORK_AI_PROVIDER"]) delete env[name];
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(output,"app.log"),"w");
const child=spawn(binary,[],{cwd:process.cwd(),env,stdio:["ignore",log.fd,log.fd]});
const ended=new Promise<void>(done=>child.once("close",()=>done()));
const report:any={status:"running",binary,pid:child.pid,checks:[],screenshots:[]};
const shown=(n:any)=>n?.rect&&n.hidden!==true&&n.visible!==false&&(n.effective_opacity??1)>0&&n.rect.w>0&&n.rect.h>0;
const flat=(n:any):any[]=>!n?[]:[n,...(n.children??[]).flatMap(flat)];
async function visible(id:string):Promise<any>{return waitFor(async()=>(await query(id)).find(shown)??null,20000)}
async function click(id:string){report.last_action=id;await visible(id);const result=await clickTestId(id);assert(result.ok,JSON.stringify({id,result}))}
async function capture(name:string){const path=join(output,name+".png");assert((await screenshot(path)).ok);report.screenshots.push(path);await writeFile(join(output,name+".tree.json"),JSON.stringify((await query("ai.panel")).find(shown)??await tree(),null,2))}
let failure:unknown;
try {
  await waitForServerReady();
  assert.equal(Number(JSON.parse(await readFile(join(rpc,"owner.json"),"utf8")).pid),child.pid);
  assert((await resizeWindow(1440,1000)).ok);
  await click("workspace.empty.local"); await visible("terminal.surface"); await click("toolbar.ai"); await click("ai.maximize");
  await click("ai.prompt"); assert((await type_("Render the Markdown fixture without tools")).ok); await click("ai.send");
  await waitFor(async()=>{
    const nodes=flat(await visible("ai.panel"));
    return !(await query("ai.stop")).some(shown)&&nodes.some(n=>n.text==="MARKDOWN_NATIVE_DONE")||null;
  },30000);
  const panel=await visible("ai.panel"), nodes=flat(panel);
  const t=(value:string)=>{const node=nodes.find(n=>n.text===value);assert(node,`Actual native text ${value}`);return node};
  assert(t("子项").rect.x>t("父项").rect.x); assert(t("孙项").rect.x>t("子项").rect.x);
  assert(t("echo nested").rect.x>t("父项").rect.x);
  for(const value of ["引用标题","引用正文","A|B","a|b","保留","x|y","最后一列","组合 链接 code"]) t(value);
  const quote=nodes.find(n=>n.test_id==="ai.message.quote");assert(quote);assert(quote.children[0].rect.h>20,"Quote bar stretches over the quote body");
  report.checks.push("Nested list indentation, nested code, quote heading/body and escaped table cells render in the real window");
  await capture("01-wide");
  await click("ai.maximize");
  const handle=await visible("ai.float.resize.e"), card=await visible("ai.panel");
  const x=handle.rect.x+handle.rect.w/2,y=handle.rect.y+handle.rect.h/2;
  assert((await mouseDown(x,y)).ok); assert((await mouseMove(x+520-card.rect.w,y)).ok); assert((await mouseUp(x+520-card.rect.w,y)).ok);
  await waitFor(async()=>Math.abs((await visible("ai.panel")).rect.w-520)<1||null,5000);
  await capture("02-narrow-bottom");
  const scroll=await visible("ai.conversation.viewport");
  assert((await scrollAt(scroll.rect.x+scroll.rect.w-12,scroll.rect.y+scroll.rect.h/2,0,3000)).ok);
  await waitFor(async()=>{
    const heading=flat(await visible("ai.panel")).find(n=>n.text==="Markdown 回归验证");
    return heading&&heading.rect.y>=scroll.rect.y-1&&heading.rect.y+heading.rect.h<=scroll.rect.y+scroll.rect.h||null;
  },5000);
  await capture("03-narrow-top");
  report.checks.push("Native message remains present after shrinking the assistant to 520px");
  assert.equal(requests,1);
  assert((await request("POST","/zerowork/windows",{action:"quit"})).ok);
  await waitFor(async()=>{
    if(child.exitCode!==null||child.signalCode!==null)return true;
    const confirmation=await Promise.race([query("local.close.accept"),ended.then(()=>[])]);
    if(confirmation.some(shown))await clickTestId("local.close.accept");
    return null;
  },15000);
  assert.equal(child.exitCode,0);report.status="passed";
} catch(error){failure=error;report.status="failed";report.error=String(error);if(child.exitCode===null)try{await capture("failure")}catch{}}
finally {
  // Only this script's disposable process/data are eligible for cleanup.
  if(child.exitCode===null&&child.signalCode===null)child.kill("SIGTERM");
  await Promise.race([ended,sleep(2000)]);
  server.closeAllConnections();await new Promise<void>(done=>server.close(()=>done()));
  await log.close();await rm(isolated,{recursive:true,force:true});
  report.exit_code=child.exitCode;await writeFile(join(output,"report.json"),JSON.stringify(report,null,2));
}
console.log(`${report.status}: ${join(output,"report.json")}`);
if(failure)throw failure;
