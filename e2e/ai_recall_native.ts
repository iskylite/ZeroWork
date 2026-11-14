/** Saved assistant history is readable through the real provider tool loop. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,open,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';

const out=resolve(process.argv[2]);
const prefix=resolve(process.env.ZW_AI_TEST_PREFIX??'zig-out');
const fixture=await mkdtemp('/private/tmp/zw-recall-native-');
const data=join(fixture,'data'),rpc=join(fixture,'rpc');
await Promise.all([out,data,rpc].map(path=>mkdir(path,{recursive:true})));

const wire=(name:string)=>name.replaceAll('_','_u').replaceAll('.','__');
let fixtureError:string|undefined;
let currentRef:string|undefined;
let attempts=0;
let stage='launch';
const server=createServer(async(req,res)=>{
    if(req.method!=='POST'){
        res.end('{"data":[{"id":"recall-fixture"}]}');
        return;
    }
    res.writeHead(200,{'content-type':'text/event-stream'});
    const reply=(delta:unknown)=>res.end('data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\ndata: [DONE]\n\n');
    const call=(id:string,name:string,args:unknown)=>reply({
        tool_calls:[{index:0,id,type:'function',function:{name:wire(name),arguments:JSON.stringify(args)}}],
    });
    try {
        let raw='';
        for await(const chunk of req)raw+=chunk;
        const body=JSON.parse(raw);
        const results=new Map<string,any>(body.messages.filter((message:any)=>message.role==='tool')
            .map((message:any)=>[message.tool_call_id,JSON.parse(message.content)]));
        const read=(id:string)=>{
            const result=results.get(id);
            assert.equal(result.status,'succeeded',JSON.stringify(result));
            return JSON.parse(result.content[0].text);
        };
        if(!body.messages.some((message:any)=>message.role==='user'&&String(message.content).includes('RECALL_HISTORY'))){
            if (!body.tools?.length) { reply({content:'Saved history fixture'}); return; }
            if(!results.has('past-operation'))return call('past-operation','host.get_current_context',{});
            read('past-operation');
            reply({content:'SAVED_RESPONSE'});
            return;
        }
        attempts++;
        for(const name of ['host.list_ai_conversations','host.recall']){
            assert(body.tools?.some((tool:any)=>tool.function.name===wire(name)),name);
        }
        if(!results.has('list-history'))return call('list-history','host.list_ai_conversations',{});
        const list=read('list-history');
        assert.equal(list.conversations.length,1);
        assert.equal(list.conversations[0].is_current,true);
        assert.equal(list.conversations[0].has_saved_history,true);
        currentRef=list.conversations[0].conversation_ref;
        assert.match(currentRef!,/^[a-f0-9]{32}$/);
        if(!results.has('read-current'))return call('read-current','host.recall',{conversation_ref:currentRef,limit:2});
        const first=read('read-current');
        assert.equal(first.source,'saved_history');
        assert.equal(first.conversation_ref,currentRef);
        assert(first.entries.some((entry:any)=>entry.kind==='assistant'&&entry.text==='SAVED_RESPONSE'));
        assert(first.entries.some((entry:any)=>entry.kind==='operation'&&entry.tool==='host.get_current_context'&&entry.status==='succeeded'));
        assert(!JSON.stringify(first).includes('binding_ref'));
        if(!results.has('read-next'))return call('read-next','host.recall',{offset:first.next_offset,revision:first.revision});
        assert(read('read-next').entries.some((entry:any)=>entry.kind==='user'&&entry.text==='SAVE_HISTORY'));
        if(!results.has('read-foreign'))return call('read-foreign','host.recall',{conversation_ref:'b'.repeat(32)});
        const denied=results.get('read-foreign');
        assert.equal(denied.status,'rejected');
        assert.match(JSON.stringify(denied),/TargetNotAuthorized/);
        reply({content:'RECALL_FIXTURE_PASSED'});
    }catch(error){
        fixtureError=String(error);
        reply({content:fixtureError});
    }
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));
const port=(server.address() as {port:number}).port;
await writeFile(join(data,'config.toml'),`[meta]
config_revision=1
[ai]
default_provider="recall-fixture"
permission_mode="confirm"
[[ai.providers]]
id="recall-fixture"
kind="openai_compat"
endpoint="http://127.0.0.1:${port}/v1/chat/completions"
enabled=true
[[ai.providers.models]]
name="recall-fixture"
context_window=200000
default=true
`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const h=await import(join(prefix,'share/zenit/harness/client.ts'));
const log=await open(join(out,'app.log'),'w');
const app=spawn(join(prefix,'bin/zerowork'),[],{
    env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1'},
    stdio:['ignore',log.fd,log.fd],
});
const ended=new Promise(done=>app.once('close',done));
const shown=(node:any)=>node?.visible!==false&&!node?.hidden&&node?.rect?.w>0&&node?.rect?.h>0&&(node?.effective_opacity??1)>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
async function click(id:string){
    stage='click '+id;
    await visible(id);
    assert((await h.clickTestId(id)).ok,id);
}
async function send(text:string){
    await click('ai.prompt');
    assert((await h.type_(text)).ok);
    await click('ai.send');
}
function treeText(node:any):string{
    if(Array.isArray(node))return node.map(treeText).join(' ');
    return (node?.text??'')+(node?.children??[]).map(treeText).join(' ');
}
async function waitForText(text:string){
    stage='wait for '+text;
    await h.waitFor(async()=>{
        assert(!fixtureError,fixtureError);
        return treeText(await h.query('ai.response')).includes(text)||null;
    },30000);
}

let report:unknown;
try{
    await h.waitForServerReady(60000);
    await h.resizeWindow(1440,900);
    await click('workspace.empty.local');
    stage='wait for terminal.surface';
    await visible('terminal.surface');
    await click('toolbar.ai');
    await send('SAVE_HISTORY');
    await waitForText('SAVED_RESPONSE');
    stage='wait for first turn to settle';
    await h.waitFor(async()=>!(await h.query('ai.stop')).some(shown)||null,10000);
    await send('RECALL_HISTORY');
    await waitForText('RECALL_FIXTURE_PASSED');
    report={status:'passed',currentRef,attempts};
}catch(error){
    report={status:'failed',error:fixtureError??String(error),stage,attempts};
    await h.screenshot(join(out,'failure.png')).catch(()=>{});
    await writeFile(join(out,'conversation.json'),JSON.stringify(await h.query('ai.response').catch(()=>null)));
    process.exitCode=1;
}finally{
    try{
        await h.request('POST','/zerowork/windows',{action:'quit'});
        await h.waitFor(()=>app.exitCode!==null||app.signalCode!==null||null,10000);
    }catch{
        if(app.exitCode===null&&app.signalCode===null)app.kill('SIGTERM');
    }
    server.closeAllConnections();
    await Promise.all([ended,new Promise<void>(done=>server.close(()=>done()))]);
    await log.close();
    await writeFile(join(out,'report.json'),JSON.stringify(report,null,2));
    console.log(JSON.stringify(report));
}
