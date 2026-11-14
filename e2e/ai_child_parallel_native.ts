/** The child borrows an idle PTY or creates a private PTY while the original PTY runs. */
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer, type ServerResponse} from 'node:http';
import {access,mkdir,mkdtemp,open,readFile,writeFile} from 'node:fs/promises';
import {join,resolve} from 'node:path';
import * as h from '../zig-out/share/zenit/harness/client.ts';

const out=resolve(process.argv[2]);
const reuse=process.argv[3]==='reuse';
await mkdir(out,{recursive:true});
const fixture=await mkdtemp('/private/tmp/zw-parallel-native-');
const data=join(fixture,'data'),rpc=join(fixture,'rpc'),zdot=join(fixture,'zdot');
await Promise.all([data,rpc,zdot].map(path=>mkdir(path)));
await writeFile(join(zdot,'.zshrc'),"bindkey -e\nPS1='parallel-fixture%# '\n");
const mainStarted=join(fixture,'main-started'),release=join(fixture,'release-main');
const mainFinished=join(fixture,'main-finished'),childStarted=join(fixture,'child-started');
const seen=(file:string)=>access(file).then(()=>true,()=>false);
const wire=(name:string)=>name.replaceAll('_','_u').replaceAll('.','__');
const frame=(delta:unknown)=>'data: '+JSON.stringify({choices:[{index:0,delta}]})+'\n\n';
function reply(res:ServerResponse,delta:unknown){
    res.end(frame(delta)+'data: [DONE]\n\n');
}
function tool(res:ServerResponse,id:string,name:string,args:unknown){
    reply(res,{tool_calls:[{index:0,id,type:'function',function:{name:wire(name),arguments:JSON.stringify(args)}}]});
}
let fixtureError:string|undefined,mainRef:string|undefined,childRef:string|undefined;
let existingId:number|undefined;
let rootRequests=0,childRequests=0;
let calls:string[]=[];
const server=createServer(async(req,res)=>{
    try {
        if(req.method!=='POST'){res.end('{"data":[{"id":"parallel-fixture"}]}');return;}
        let raw='';
        for await(const chunk of req)raw+=chunk;
        const body=JSON.parse(raw);
        res.writeHead(200,{'content-type':'text/event-stream'});
        res.flushHeaders();
        const root=body.messages.some((item:any)=>item.role==='user'&&String(item.content).includes('MAIN_WORK_IN_PROGRESS'));
        const results=new Map<string,any>();
        for(const message of body.messages.filter((m:any)=>m.role==='tool')){
            const result=JSON.parse(message.content);
            const decoded=result.content?.[0]?.text ? JSON.parse(result.content[0].text) : result;
            if(['rejected','failed','cancelled_unsent','outcome_unknown'].includes(result.status)) throw Error(message.tool_call_id+' '+JSON.stringify(decoded));
            results.set(message.tool_call_id,decoded);
        }
        if(!body.tools?.length){reply(res,{content:'fixture final response'});return;}
        const call=(id:string,name:string,args:unknown)=>{calls.push(id);tool(res,id,name,args);};
        if(root){
            rootRequests++;
            if(!results.has('main-context'))return call('main-context','host.get_current_context',{});
            if(reuse&&!results.has('main-members'))return call('main-members','host.list_sessions',{});
            if(reuse){
                const members=results.get('main-members').sessions;
                assert.equal(members.length,2);
                mainRef=members.find((item:any)=>item.session_id!==existingId).session_ref;
            }else mainRef=results.get('main-context').binding_ref;
            for(let poll=0;poll<24;poll++){
                const id='main-ready-'+poll;
                if(!results.has(id)){
                    if(poll)await new Promise(r=>setTimeout(r,250));
                    return call(id,'host.get_session',{session_ref:mainRef});
                }
                if(results.get(id).session.capabilities.trusted_pty_execution)break;
            }
            if(!results.has('main-run'))return call('main-run','host.run_in_terminal',{
                session_ref:mainRef,request_key:'parallel-main',wait_ms:30000,
                command:`print -r -- started > '${mainStarted}'; zmodload zsh/zselect; while [[ ! -f '${release}' ]]; do zselect -t 5; done; print -r -- finished > '${mainFinished}'`});
            let watermark=0;
            for(let poll=0;poll<10;poll++){
                const id='reports-'+poll;
                if(!results.has(id))return call(id,'host.agent_tasks',{action:'wait_events',after_sequence:watermark,wait_ms:1000});
                const event=results.get(id);
                if(JSON.stringify(event).includes('CHILD_WORK_DONE')){reply(res,{content:'PARENT_WORK_AND_CHILD_REPORT_DONE'});return;}
                watermark=event.watermark;
            }
            throw Error('Child completion was absent from the root reports');
        }
        childRequests++;
        const prompt=body.messages.filter((m:any)=>m.role==='user').map((m:any)=>String(m.content)).join(' ');
        assert.match(prompt,/CHILD_WORK_IN_PARALLEL/);
        if(reuse){
            if(!results.has('child-members'))return call('child-members','host.list_sessions',{});
            const members=results.get('child-members').sessions;
            assert.equal(members.length,1);
            assert.equal(members[0].session_id,existingId,'the assigned target is the other existing PTY');
            childRef=members[0].session_ref;
            if(!results.has('child-run'))return call('child-run','host.run_in_terminal',{
                session_ref:childRef,request_key:'parallel-child',wait_ms:5000,
                command:`print -r -- started > '${childStarted}'`});
            reply(res,{content:'CHILD_WORK_DONE'});
            return;
        }
        if(!results.has('child-context'))return call('child-context','host.get_current_context',{});
        const source=results.get('child-context').binding_ref;
        if(!results.has('child-group'))return call('child-group','host.create_group',{initial_session_ref:source,name:'子任务独立组',request_key:'parallel-group'});
        if(!results.has('child-open'))return call('child-open','host.open_session',{
            group_ref:results.get('child-group').group_ref,source_ref:source,connection_policy:'new_only',request_key:'parallel-open',retention:'keep'});
        const opened=results.get('child-open');
        childRef=opened.session_ref;
        assert.notEqual(childRef?.split(':').at(-2),mainRef?.split(':').at(-2));
        for(let poll=0;poll<20;poll++){
            const id='child-ready-'+poll;
            if(!results.has(id)){
                if(poll)await new Promise(r=>setTimeout(r,250));
                return call(id,'host.wait_session_ready',{operation_ref:opened.operation_ref,wait_ms:1000});
            }
            if(results.get(id).state==='ready' && results.get(id).execution_readiness==='ready')break;
        }
        if(!results.has('child-run'))return call('child-run','host.run_in_terminal',{
            session_ref:childRef,request_key:'parallel-child',wait_ms:5000,
            command:`print -r -- started > '${childStarted}'`});
        reply(res,{content:'CHILD_WORK_DONE'});
    } catch(e) {
        fixtureError=String(e);
        reply(res,{content:fixtureError});
    }
});
await new Promise<void>(done=>server.listen(0,'127.0.0.1',done));
const port=(server.address() as {port:number}).port;
await writeFile(join(data,'config.toml'),`[meta]
config_revision=1
[ui]
theme="dark"
[ai]
default_provider="parallel-fixture"
permission_mode="confirm"
execution_mode="attached_pty"
follow_up_mode="queue"
[[ai.providers]]
id="parallel-fixture"
kind="openai_compat"
endpoint="http://127.0.0.1:${port}/v1/chat/completions"
enabled=true
[[ai.providers.models]]
name="parallel-fixture"
context_window=200000
default=true
`);
process.env.ZENIT_E2E_FILE_RPC_DIR=rpc;
const log=await open(join(out,'app.log'),'w');
const app=spawn(resolve('zig-out/bin/zerowork'),[],{
    env:{...process.env,ZEROWORK_DATA_DIR:data,ZEROWORK_AUTOCONNECT:'0',ZENIT_E2E_BACKGROUND:'1',ZENIT_E2E_ISOLATE_POINTER:'1',ZDOTDIR:zdot},
    stdio:['ignore',log.fd,log.fd],
});
const ended=new Promise(done=>app.once('close',done));
const running=()=>app.exitCode===null&&app.signalCode===null;
const shown=(node:any)=>node?.visible!==false&&!node?.hidden&&node?.rect?.w>0&&node?.rect?.h>0&&(node?.effective_opacity??1)>0;
const visible=(id:string)=>h.waitFor(async()=>(await h.query(id)).find(shown)??null,15000);
async function click(id:string){
    await visible(id);
    assert((await h.clickTestId(id)).ok,id);
}
async function send(text:string){
    await click('ai.prompt');
    assert((await h.type_(text)).ok);
    await click('ai.send');
}
function treeText(node:any):string{
    return (node?.text??'')+(node?.children??[]).map(treeText).join(' ');
}
function flatten(node:any):any[]{
    return node ? [node,...(node.children??[]).flatMap(flatten)] : [];
}
async function setupExistingGroup(){
    await click('toolbar.new_session');
    await click('session.menu.local');
    const nodes=await h.waitFor(async()=>{
        const strip=(await h.query('tabs.strip')).find(shown);
        const tabs=flatten(strip).filter(node=>/^tabs\.tab\.\d+$/.test(node.test_id??''));
        return tabs.length===2 ? tabs : null;
    },15000);
    const [first,second]=nodes;
    const x=second.rect.x+second.rect.w/2,y=second.rect.y+second.rect.h/2;
    const tx=first.rect.x+first.rect.w/2,ty=first.rect.y+first.rect.h/2;
    assert((await h.mouseDown(x,y)).ok);
    for(let step=1;step<=8;step++){
        assert((await h.mouseMove(x+(tx-x)*step/8,y+(ty-y)*step/8)).ok);
        await h.sleep(35);
    }
    assert((await h.mouseUp(tx,ty)).ok);
    await visible('groups.workspace');
    existingId=2;
    const main=await visible('groups.pane.1');
    await visible('groups.pane.2');
    assert((await h.clickAt(main.rect.x+main.rect.w/2,main.rect.y+main.rect.h/2)).ok);
}
async function waitForFile(file:string, approvals:string[]){
    const until=Date.now()+45000;
    while(Date.now()<until){
        assert(!fixtureError,fixtureError);
        if(await seen(file))return;
        for(const id of approvals){
            if((await h.query(id)).some(shown))await click(id);
        }
        await h.sleep(60);
    }
    throw Error('Missing execution marker '+file);
}
let outcome:unknown;
try {
    await h.waitForServerReady(60000);
    await h.resizeWindow(1350,900);
    await click('workspace.empty.local');
    if(reuse)await setupExistingGroup();
    await click('toolbar.ai');
    await send('MAIN_WORK_IN_PROGRESS');
    await waitForFile(mainStarted,['ai.interaction.approve','ai.host_approval.accept']);
    const terminal=await visible('terminal.surface');
    const parent=await visible('ai.panel');
    await send('另开一个子智能体：CHILD_WORK_IN_PARALLEL');
    assert(!(await h.query('ai.child.dialog')).some(shown),'launch keeps the child dialog in the background');
    const childRow=await (async()=>{
        await click('ai.children');
        const list=await visible('ai.children.list');
        const find=(node:any):any=>/^ai\.child\.[0-9a-f]{32}$/.test(node.test_id??'') ? node : (node.children??[]).map(find).find(Boolean);
        return find(list);
    })();
    assert(childRow,'the explicit follow-up must launch a visible independent child');
    await click(childRow.test_id);
    await waitForFile(childStarted,['ai.child.host_approval.accept','ai.child.interaction.approve','ai.interaction.approve','ai.host_approval.accept']);
    assert(!(await seen(mainFinished)),'foreground process must still be running when the child command starts');
    assert.equal((await visible('terminal.surface')).id,terminal.id,'the child must not switch the foreground terminal');
    assert.equal((await visible('ai.panel')).id,parent.id,'the main assistant remains mounted');
    assert(mainRef&&childRef);
    assert.notEqual(mainRef.split(':').at(-2),childRef.split(':').at(-2));
    await h.screenshot(join(out,'parallel.png'));
    await writeFile(release,'release\n');
    await h.waitFor(async()=>treeText(await visible('ai.panel')).includes('PARENT_WORK_AND_CHILD_REPORT_DONE')||null,45000);
    assert(await seen(mainFinished));
    outcome={status:'passed',reuse,mainRef,childRef,rootRequests,childRequests,calls};
} catch(e) {
    outcome={status:'failed',error:fixtureError??String(e),mainRef,childRef,rootRequests,childRequests,calls};
    await h.screenshot(join(out,'failure.png')).catch(()=>{});
    await writeFile(join(out,'tree.json'),JSON.stringify(await h.tree().catch(()=>null)));
    process.exitCode=1;
} finally {
    await writeFile(release,'release\n');
    if(running())app.kill('SIGTERM');
    server.closeAllConnections();
    await Promise.all([ended,new Promise<void>(done=>server.close(()=>done()))]);
    await log.close();
    await writeFile(join(out,'report.json'),JSON.stringify(outcome,null,2));
    console.log(JSON.stringify(outcome));
}
