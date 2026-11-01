/** Runs the production prototype handlers in isolation; no browser or user data. */
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source=path=>readFileSync(new URL('../docs/UI_V3/'+path,import.meta.url),'utf8');
const workspace=source('workspace/app.js');
const start=workspace.indexOf('function workspaceShortcut(event)');
const end=workspace.indexOf('\nfunction quickConnectDialog()',start);
assert(start>=0&&end>start,'production workspace shortcut handlers must be present');

function workspaceFixture(saved={}){
 const calls=[],timers=[],nodes=new Map(),session={id:1,type:'ssh',state:'online',draft:'keep draft',log:[]};
 for(const id of ['#modal-root','#context-menu'])nodes.set(id,{hidden:true});
 const context={
  localStorage:{getItem(){return JSON.stringify({values:saved});}},
  document:{addEventListener(type,callback){assert.equal(type,'keydown');context.keydown=callback;}},
  $:selector=>nodes.get(selector)||{},current:()=>session,sessions:[session],
  setTimeout(fn){timers.push(fn);},sidebarCollapsed:false,assistantOpen:true,aiPinned:true,
 };
 for(const name of ['tabSessionMenu','renderContent','renderOtherPalette','quickConnectDialog','render','hidePopover','renderAssistant','broadcastPopover','authDialog','toast'])context[name]=(...args)=>calls.push({name,args});
 vm.createContext(context);vm.runInContext(workspace.slice(start,end),context);
 const target=(assistant=false,command=false,sessionId=1)=>({dataset:{session:String(sessionId)},closest(selector){return assistant&&selector==='#assistant'?{}:null;},classList:{contains(name){return command&&name==='command-input';}}});
 const press=(key,code,options={})=>{
  const event={key,code,metaKey:true,ctrlKey:false,shiftKey:false,altKey:false,isComposing:false,target:target(),preventDefault(){this.prevented=true;},stopImmediatePropagation(){this.stopped=true;},...options};
  context.keydown(event);return event;
 };
 return {context,calls,timers,nodes,session,target,press};
}

test('saved Cmd+Shift+R reaches its configured action from the AI input',()=>{
 const f=workspaceFixture({key_new_tab:'⌘⇧R'});
 const event=f.press('R','KeyR',{shiftKey:true,target:f.target(true)});
 assert(event.prevented&&event.stopped);
 assert.equal(f.calls[0].name,'tabSessionMenu');
});

test('AI input keeps global shortcuts while completion remains owned by terminal input',()=>{
 for(const [key,code,action] of [['t','KeyT','tabSessionMenu'],['b','KeyB','render'],['j','KeyJ','renderAssistant'],['k','KeyK','quickConnectDialog'],['i','KeyI','broadcastPopover']]){
  const f=workspaceFixture();
  assert(f.press(key,code,{shiftKey:key==='i',target:f.target(true)}).prevented);
  assert.equal(f.calls[0].name,action);
  if(key==='j')assert.equal(f.context.assistantOpen,false);
 }
 const f=workspaceFixture();
 assert(!f.press(';','Semicolon',{target:f.target(true)}).prevented);
 assert.equal(f.calls.length,0);
 assert(f.press(';','Semicolon',{target:f.target(false,true)}).prevented);
 assert.equal(f.calls[0].name,'renderOtherPalette');
});

test('modal, context menu, IME and remote Control retain ownership of shortcuts',()=>{
 for(const selector of ['#modal-root','#context-menu']){
  const f=workspaceFixture();f.nodes.get(selector).hidden=false;
  assert(!f.press('t','KeyT').prevented);assert.equal(f.calls.length,0);
 }
 for(const options of [{isComposing:true},{ctrlKey:true},{metaKey:false},{shiftKey:true}]){
  const f=workspaceFixture();assert(!f.press('t','KeyT',options).prevented);assert.equal(f.calls.length,0);
 }
});

test('saved Space combinations match physical events and retire the previous binding',()=>{
 for(const options of [{shiftKey:true,chord:'⌘⇧Space'},{altKey:true,chord:'⌘⌥Space'}]){
  const f=workspaceFixture({key_new_tab:options.chord});
  assert(f.press(' ','Space',options).prevented);
  assert.equal(f.calls[0].name,'tabSessionMenu');
  assert(!f.press('t','KeyT').prevented);
  assert(!f.press(' ','Space',{metaKey:false}).prevented);
 }
});

test('reconnect rejects live sessions and permits one retry for failed or ended SSH',()=>{
 for(const state of ['online','connecting','failed','exited']){
  const f=workspaceFixture();f.session.state=state;
  f.press('r','KeyR');
  const allowed=['failed','exited'].includes(state);
  assert.equal(f.session.state,allowed?'connecting':state);
  assert.equal(f.timers.length,allowed?1:0);
  assert.equal(f.session.draft,'keep draft');assert.deepEqual(f.session.log,[]);
  if(allowed){
   f.press('r','KeyR');assert.equal(f.timers.length,1,'a second key press cannot start another attempt');
   f.timers[0]();assert.equal(f.calls.filter(c=>c.name==='authDialog').length,1);
  }else assert.equal(f.calls.filter(c=>c.name==='render').length,0);
 }
 for(const type of ['local','sftp','history']){
  const f=workspaceFixture();Object.assign(f.session,{type,state:'failed'});f.press('r','KeyR');
  assert.equal(f.session.state,'failed');assert.equal(f.timers.length,0);
 }
});

function notificationFixture(){
 const nodes=[],located=[];
 const renderer={update(node,payload){node.payload=payload;return node;},updateSource(node,source){node.payload.source=source;},show(payload){
  const node={removed:false,get isConnected(){return !this.removed;},payload,remove(){this.removed=true;},querySelector(){return {addEventListener(){}};}};
  nodes.push(node);return node;
 }};
 const window={V3Feedback:renderer};
 vm.runInNewContext(source('shared/notification-policy.js'),{
  window,parent:window,location:{search:'',origin:'http://localhost'},URL,URLSearchParams,
  document:{currentScript:{src:'http://localhost/notification-policy.js'},head:{append(){}},createElement(){return {}; }},
 });
 const event={key:'connection:1',revision:1,kind:'connection_failed',title:'Connection needs attention',requiresAction:true,timeSensitive:true,locate:()=>located.push('first')};
 const publish=(changes={},context={})=>renderer.publish({...event,...changes},{focused:true,sourceVisible:false,...context});
 return {nodes,located,publish,renderer};
}

for(const [name,changes,context] of [
 ['local',{}, {sourceVisible:true}],['system',{}, {focused:false}],
 ['quiet',{}, {quietHours:true}],['indicator',{requiresAction:false},{}],
 ['resolved',{phase:'resolved'},{}],
])test('notification '+name+' revision removes the obsolete banner and invalidates its action',()=>{
 const f=notificationFixture(),first=f.publish();
 const next=f.publish({revision:2,...changes},context);
 assert(first.node.removed);assert.equal(next.node,null);
 first.node.payload.action();assert.deepEqual(f.located,[]);
});

test('in-app notification replacement accepts only the current action, once',()=>{
 const f=notificationFixture(),first=f.publish(),oldAction=first.node.payload.action;
 const next=f.publish({revision:2,locate:()=>f.located.push('current')});
 assert.equal(first.node,next.node);assert(!next.node.removed);
 oldAction();assert.deepEqual(f.located,[]);
 next.node.payload.action();next.node.payload.action();assert.deepEqual(f.located,['current']);
});

test('duplicates and unrelated incidents do not expire a still-current critical banner',()=>{
 const f=notificationFixture(),first=f.publish({kind:'application_risk'});
 assert.equal(f.publish().channel,'duplicate');
 f.publish({key:'connection:2',locate:()=>f.located.push('second')});
 assert(!first.node.removed);
 first.node.payload.action();assert.deepEqual(f.located,['first']);
});

test('another member of the same incident cannot expire its current banner',()=>{
 for(const [changes,context] of [[{}, {sourceVisible:true}],[{}, {focused:false}],[{}, {quietHours:true}],[{phase:'resolved'},{}]]){
  const f=notificationFixture();f.publish({incidentKey:'group'});
  const current=f.publish({key:'connection:2',incidentKey:'group',locate:()=>f.located.push('second')});
  f.publish({incidentKey:'group',key:'connection:2',revision:2,...changes},context);
  assert(!current.node.removed);
  current.node.payload.action();assert.deepEqual(f.located,['first']);
 }
});

test('moving a fact retains its critical banner and invalidates its old action',()=>{
 const f=notificationFixture(),first=f.publish({kind:'application_risk',incidentKey:'old'}),oldAction=first.node.payload.action;
 const next=f.publish({kind:'application_risk',revision:2,incidentKey:'new'});
 assert.equal(first.node,next.node);assert(!next.node.removed);
 oldAction();assert.deepEqual(f.located,[]);
 next.node.payload.action();assert.deepEqual(f.located,['first']);
 assert.equal(f.renderer.notificationSnapshot().pending,1);
 assert.equal(f.renderer.notificationSnapshot().items.length,1);
});

test('moving an already dismissed fact updates membership without reviving its banner',()=>{
 const f=notificationFixture(),first=f.publish({incidentKey:'old'});first.node.payload.action();
 const next=f.publish({revision:2,incidentKey:'new'});
 assert.equal(next.node,null);assert.equal(f.nodes.length,1);
 const state=f.renderer.notificationSnapshot();assert.equal(state.items.length,1);assert.equal(state.items[0].id,'new');assert.equal(state.pending,1);
 assert.equal(state.unread,0);
});

test('resolving the current incident representative selects a remaining pending source',()=>{
 const f=notificationFixture();
 f.publish({incidentKey:'group',title:'First source',detail:'First detail',source:'A',target:{value:'A'}});
 const second=f.publish({incidentKey:'group',key:'connection:2',title:'Second source',detail:'Second detail',source:'B',target:{value:'B'},locate:()=>f.located.push('second')});
 f.publish({incidentKey:'group',revision:2,phase:'resolved',title:'First resolved'});
 const state=f.renderer.notificationSnapshot(),item=state.items[0];
 assert.equal(state.pending,1);assert.equal(item.title,'Second source');assert.equal(item.detail,'Second detail');assert.equal(item.target.value,'B');
 item.locate();assert.deepEqual(f.located,['second']);
 assert(second.node.removed);second.node.payload.action();assert.deepEqual(f.located,['second']);
 f.publish({incidentKey:'group',key:'connection:2',revision:2,phase:'resolved',title:'All resolved'});
 assert.equal(f.renderer.notificationSnapshot().pending,0);
 f.renderer.clearResolved();assert.equal(f.renderer.notificationSnapshot().items.length,0);
});

test('local and indicator revisions reconcile action state before choosing delivery',()=>{
 for(const context of [{},{sourceVisible:true}]){
  const f=notificationFixture();const old=f.publish();
  f.publish({revision:2,requiresAction:false,title:'No action needed'},context);
  assert.equal(f.renderer.notificationSnapshot().pending,0);
  assert(old.node.removed);old.node.payload.action();assert.deepEqual(f.located,[]);
 }
});

test('a locally delivered member remains in an existing incident after its other source resolves',()=>{
 const f=notificationFixture();f.publish({incidentKey:'group',source:'A'});
 f.publish({incidentKey:'group',key:'connection:2',source:'B',title:'Local source',target:{value:'B'},locate:()=>f.located.push('second')},{sourceVisible:true});
 f.publish({incidentKey:'group',revision:2,phase:'resolved',title:'First resolved'});
 const item=f.renderer.notificationSnapshot().items[0];
 assert.equal(item.count,2);assert.equal(item.pending,true);assert.equal(item.title,'Local source');assert.equal(item.target.value,'B');
 item.locate();assert.deepEqual(f.located,['second']);
 f.publish({incidentKey:'group',key:'connection:2',revision:2,requiresAction:false},{sourceVisible:true});
 assert.equal(f.renderer.notificationSnapshot().pending,0);
});

test('completion uses its focused input owner instead of the previously active pane',()=>{
 const f=workspaceFixture(),second={id:2,type:'ssh',state:'online',draft:'pwd',log:[]};
 f.context.sessions.push(second);
 const input=f.target(false,true,2),panel={hidden:true};f.nodes.set('#palette-2',panel);
 f.press(';','Semicolon',{target:input});
 const call=f.calls.find(c=>c.name==='renderOtherPalette');
 assert.equal(call.args[0],second);assert.equal(call.args[1],input);assert.equal(call.args[2],panel);
 const before=f.calls.length;f.press(';','Semicolon',{target:f.target(false,true,999)});
 assert.equal(f.calls.length,before,'a missing input owner never falls back to the active session');
});

function retainedFocusFixture(kind,changeOwner=false){
 const body={id:'body'},document={activeElement:body};let owner='s1',conversation=7;
 function input(id,command){return {id,value:'draft unchanged',dataset:{session:'1',aiOwner:owner,aiConversation:String(conversation)},selectionStart:2,selectionEnd:8,selectionDirection:'backward',scrollTop:24,scrollLeft:3,classList:{contains(name){return command&&name==='command-input';}},focus(){document.activeElement=this;},setSelectionRange(start,end,direction){this.selectionStart=start;this.selectionEnd=end;this.selectionDirection=direction;}};}
 let ai=input('ai-input',false),terminal=input('',true);const old=kind==='ai'?ai:terminal;document.activeElement=old;
 document.querySelector=selector=>selector==='#ai-input'?ai:selector.startsWith('.command-input')?terminal:null;
 const context={document,$:selector=>document.querySelector(selector)||{},all:()=>[],sidebarToggle:{},assistantOpen:true,assistantOwner:()=>owner,aiData:()=>({id:conversation})};
 for(const name of ['renderTabs','renderHosts','renderStatus','syncSidebarVisibility','applyIcons','positionPopover','icon'])context[name]=()=>{};
 const replace=node=>{if(document.activeElement===node)document.activeElement=body;const replacement=input(node.id,node===terminal);Object.assign(replacement,{selectionStart:0,selectionEnd:0,selectionDirection:'none',scrollTop:0,scrollLeft:0});return replacement;};
 context.renderContent=()=>{terminal=replace(terminal);};
 context.renderAssistant=()=>{ai=replace(ai);if(changeOwner){owner='s2';conversation=8;}};
 const helpers=workspace.indexOf('function captureInputFocus(){');
 const start=helpers>=0?helpers:workspace.indexOf('function render(){'),end=workspace.indexOf('\nfunction renderTabs()',start);
 assert(start>=0&&end>start);vm.createContext(context);vm.runInContext(workspace.slice(start,end),context);
 return {context,document,body,old,current:()=>kind==='ai'?ai:terminal,changeOwner(){owner='s2';conversation=8;}};
}

test('production render restores AI focus, selection direction and scroll after rebuilding its DOM',()=>{
 const f=retainedFocusFixture('ai');f.context.render();const input=f.current();
 assert.notEqual(input,f.old);assert.equal(f.document.activeElement,input);
 assert.equal(input.selectionStart,2);assert.equal(input.selectionEnd,8);assert.equal(input.selectionDirection,'backward');
 assert.equal(input.scrollTop,24);assert.equal(input.scrollLeft,3);assert.equal(input.value,'draft unchanged');
});

test('production render preserves terminal focus without moving AI focus into another owner',()=>{
 const terminal=retainedFocusFixture('terminal');terminal.context.render();
 assert.equal(terminal.document.activeElement,terminal.current());assert.equal(terminal.current().selectionStart,2);assert.equal(terminal.current().selectionEnd,8);
 const changed=retainedFocusFixture('ai',true);changed.context.render();assert.equal(changed.document.activeElement,changed.body);
});

test('an owner changed before render cannot borrow the previous AI input selection',()=>{
 const f=retainedFocusFixture('ai');f.changeOwner();f.context.render();
 assert.equal(f.document.activeElement,f.body);assert.equal(f.current().selectionStart,0);assert.equal(f.current().selectionEnd,0);
});

test('notification representative follows original fact order through updates and migration',()=>{
 const f=notificationFixture();
 f.publish({incidentKey:'old',title:'First fact',target:{value:'A'}});
 f.publish({incidentKey:'group',key:'connection:2',title:'Second fact',target:{value:'B'}});
 f.publish({incidentKey:'group',revision:2,title:'First fact updated',target:{value:'A'}});
 let item=f.renderer.notificationSnapshot().items[0];assert.equal(item.title,'First fact updated');assert.equal(item.target.value,'A');
 f.publish({incidentKey:'group',key:'connection:2',revision:2,title:'Second fact updated'});
 item=f.renderer.notificationSnapshot().items[0];assert.equal(item.title,'First fact updated');assert.equal(item.target.value,'A');
 f.publish({incidentKey:'group',revision:3,phase:'resolved',title:'First ended'});
 item=f.renderer.notificationSnapshot().items[0];assert.equal(item.title,'Second fact updated');assert.equal(item.target.value,'B');
 f.publish({incidentKey:'group',key:'connection:2',revision:3,phase:'resolved',title:'Second ended'});
 item=f.renderer.notificationSnapshot().items[0];assert.equal(item.title,'First ended');assert.equal(item.pending,false);
});

test('visible notification migration into an existing incident retains its banner and action owner',()=>{
 for(const resolved of [true,false]){
  const f=notificationFixture();f.publish({incidentKey:'existing',title:'Existing source',target:{value:'A'}});
  if(resolved)f.publish({incidentKey:'existing',revision:2,phase:'resolved'});
  const first=f.publish({key:'connection:2',incidentKey:'old',title:'Moving source',target:{value:'B'},locate:()=>f.located.push('moving')});
  const oldAction=first.node.payload.action;const next=f.publish({key:'connection:2',incidentKey:'existing',revision:2,title:'Moving source updated',locate:()=>f.located.push('moving')});
  assert.equal(first.node,next.node);assert(!next.node.removed);
  assert.equal(next.node.payload.text,'Moving source updated');
  oldAction();assert.deepEqual(f.located,[]);next.node.payload.action();assert.deepEqual(f.located,['moving']);
  const state=f.renderer.notificationSnapshot();assert.equal(state.items.length,1);assert.equal(state.pending,1);
  assert.equal(state.items[0].target.value,resolved?'B':'A');
 }
});

test('a dismissed notification does not revive when merged into an existing incident',()=>{
 const f=notificationFixture();f.publish({incidentKey:'existing'});f.publish({incidentKey:'existing',revision:2,phase:'resolved'});
 const first=f.publish({key:'connection:2',incidentKey:'old'});first.node.payload.action();const count=f.nodes.length;
 const next=f.publish({key:'connection:2',incidentKey:'existing',revision:2});assert.equal(next.node,null);assert.equal(f.nodes.length,count);
});

function componentFocusFixture(){
 const f=retainedFocusFixture('ai'),ctx=f.context,replaceAi=ctx.renderAssistant,baseData=ctx.aiData;
 const data={draft:f.old.value,messages:[],attachments:[],model:'sonnet',permission:'确认后执行'};
 ctx.aiData=()=>({...data,...baseData()});
 const panel={hidden:false};Object.defineProperty(panel,'innerHTML',{set(markup){this.markup=markup;replaceAi();}});
 const nodes=new Map([['#assistant',panel],['#ai-edge',{dataset:{},classList:{toggle(){}}}],['#popover',{hidden:true}],['#ai-messages',{scrollTop:0,scrollHeight:100}]]);
 ctx.$=selector=>nodes.get(selector)||ctx.document.querySelector(selector)||{};
 Object.assign(ctx,{V3:{aiHeader:()=>''},V3AI:{welcome:()=>'',composer:()=>'',model:()=>({vision:true})},groupMode:false,aiSessionListOpen:false,aiMaximized:false,current:()=>({name:'Terminal'})});
 for(const name of ['renderAiDraftAttachments','renderAiSessionList','renderAiResizeTargets','positionAssistant','compressionDisabled'])ctx[name]=()=>'';
 ctx.aiPrimaryState=()=> 'send';ctx.aiUsage=()=>0;ctx.aiHasImageAttachments=()=>false;ctx.allAiConversations=()=>[];
 const start=workspace.indexOf('function renderAssistant(){'),end=workspace.indexOf('\nfunction ',start+1);
 vm.runInContext(workspace.slice(start,end),ctx);return {...f,data};
}

test('direct assistant refresh preserves the editor without relying on outer render',()=>{
 const f=componentFocusFixture();f.context.renderAssistant();const input=f.current();
 assert.notEqual(input,f.old);assert.equal(f.document.activeElement,input);
 assert.equal(input.selectionStart,2);assert.equal(input.selectionEnd,8);assert.equal(input.selectionDirection,'backward');assert.equal(input.scrollTop,24);
});

test('direct assistant refresh does not restore input focus into another conversation',()=>{
 const f=componentFocusFixture();const oldData=f.context.aiData;f.context.aiData=()=>({...oldData(),id:8});f.context.renderAssistant();
 assert.equal(f.document.activeElement,f.body);assert.equal(f.current().selectionStart,0);
});

function aiRequestFixture(){
 const state={s1:{id:1,messages:[],attachments:[],draft:'',running:false,permission:'确认后执行'}},timers=[],rendered=[],input={value:'first question'};let owner='s1';
 const context={refreshAiSessionRows(){},aiConversationViews:new Map(),closeModal(){},aiPendingDelete:null,aiConversations:{s1:[]},structuredClone,aiConversationTitle:d=>'Conversation '+d.id,aiOwnerInfo:()=>({available:true,session:{id:1}}),switchSession(){},aiState:state,aiData:()=>state[owner],assistantOwner:()=>owner,$:()=>input,esc:String,renderAssistant(){rendered.push({owner,id:state[owner]?.id});},now:()=>'',current:()=>({id:1,type:'local',name:'Terminal',cwd:'/tmp'}),directory:{remote:'/'},files:{remote:[]},setTimeout(fn){timers.push(fn);},icon:()=>'',Date};
 const start=workspace.indexOf("case 'ai-send':"),end=workspace.indexOf("case 'ai-stop':",start);assert(start>=0&&end>start);
 vm.createContext(context);
 context.allAiConversations=()=>[{id:state[owner].id,key:owner+'|'+state[owner].id,owner,state:state[owner]},...(context.aiConversations[owner]||[]).map(entry=>({...entry,key:owner+'|'+entry.id,owner}))];
 for(const name of ['findAiConversation','archiveAiConversation','allAiConversations','jumpAiConversation','deleteAiConversation']){const a=workspace.indexOf('function '+name+'('),b=workspace.indexOf('\nfunction ',a+1);if(a>=0)vm.runInContext(workspace.slice(a,b),context);}
 vm.runInContext('function send(){switch("ai-send"){'+workspace.slice(start,end)+'}}',context);
 return {context,state,timers,rendered,input,send:()=>context.send(),select(value){owner=value;},jump(id){context.jumpAiConversation(owner+'|'+id);}};
}

test('cancelled conversation reply cannot write or finish a new conversation on the same host',()=>{
 const f=aiRequestFixture(),old=f.state.s1;f.send();old.running=false;
 const next={id:2,messages:[],running:true,permission:'确认后执行'};f.state.s1=next;f.timers[0]();
 assert.equal(next.messages.length,0);assert.equal(next.running,true);assert.equal(old.messages.length,1);assert.equal(f.rendered.length,1);
});

test('a stopped request cannot finish a subsequent request in the same conversation',()=>{
 const f=aiRequestFixture();f.send();f.state.s1.running=false;f.input.value='second question';f.send();const before=f.state.s1.messages.length;
 f.timers[0]();assert.equal(f.state.s1.running,true);assert.equal(f.state.s1.messages.length,before);
 f.timers[1]();assert.equal(f.state.s1.running,false);assert.equal(f.state.s1.messages.length,before+1);
});

test('a valid background reply updates its original owner without refreshing the current editor',()=>{
 const f=aiRequestFixture(),original=f.state.s1;f.send();f.state.s2={id:2,messages:[],running:false};f.select('s2');f.timers[0]();
 assert.equal(original.messages.length,2);assert.equal(original.running,false);assert.equal(f.state.s2.messages.length,0);assert.equal(f.rendered.length,1);
});


test('same-host conversation switch retains a valid background reply without repainting the selected conversation',()=>{
 const f=aiRequestFixture(),original=f.state.s1;
 f.context.aiConversations.s1.push({id:2,state:{id:2,messages:[],attachments:[],draft:'second draft',running:false}});
 f.send();f.jump(2);assert.equal(f.context.allAiConversations().find(c=>c.id===1).status,'running');f.timers[0]();
 const archived=f.context.aiConversations.s1.find(c=>c.id===1).state;
 assert.equal(archived.messages.length,2);assert.equal(archived.running,false);
 assert.equal(f.state.s1.id,2);assert.equal(f.state.s1.draft,'second draft');assert.equal(f.state.s1.messages.length,0);assert.equal(f.rendered.length,1);
 f.jump(1);assert.equal(f.state.s1,original);assert.equal(f.state.s1.messages.length,2);
});

test('same-host switch away and back before completion retains the original request identity',()=>{
 const f=aiRequestFixture(),original=f.state.s1;
 f.context.aiConversations.s1.push({id:2,state:{id:2,messages:[],attachments:[],running:false}});
 f.send();f.jump(2);f.jump(1);f.timers[0]();
 assert.equal(f.state.s1,original);assert.equal(original.messages.length,2);assert.equal(original.running,false);assert.equal(f.rendered.length,2);
});

test('expired notification updates and migrations do not revive banners or execute expired actions',()=>{
 for(const destination of ['old','existing','new']){
  const f=notificationFixture();f.publish({incidentKey:'existing'});
  const first=f.publish({key:'connection:2',incidentKey:'old'});first.node.remove();
  first.node.payload.action();assert.deepEqual(f.located,[]);
  const next=f.publish({key:'connection:2',revision:2,incidentKey:destination});
  assert.equal(next.node,null);assert.equal(f.nodes.length,2);assert.equal(f.renderer.notificationSnapshot().pending,destination==='existing'?1:2);
 }
});

test('moving an undisplayed member refreshes only the original banner source summary',()=>{
 for(const context of [{},{sourceVisible:true},{focused:false},{quietHours:true}]){
  const f=notificationFixture();f.publish({incidentKey:'old',source:'A'});
  const shown=f.publish({key:'connection:2',incidentKey:'old',source:'B'});assert.equal(shown.node.payload.source,'A 等 2 个来源');const count=f.nodes.length;
  f.publish({key:'connection:2',revision:2,incidentKey:'new',source:'B'},context);
  assert.equal(shown.node.payload.source,'A');assert(!shown.node.removed);assert.equal(f.nodes.length,count);
  shown.node.payload.action();assert.deepEqual(f.located,['first']);
 }
});

function attachmentSceneFixture(){
 const timers=[],models={vision:false},states={s1:{id:1,draft:'original draft',messages:[],uiTurnGeneration:0},s2:{id:2,draft:'second draft',messages:[],uiTurnGeneration:0}},painted=[],sideEffects=[];
 let owner='s1',loadResolve=null;
 const document={addEventListener(type,fn){if(type==='click')context.click=fn;},querySelector(){return {src:'http://localhost/ai-prototype.js'};}};
 const data=JSON.parse(source('shared/ai-prototype-data.json'));
 const context={URL,structuredClone,document,aiState:states,aiConversations:{},assistantOwner:()=>owner,aiData:()=>states[owner],V3AI:{escape:String,icon:()=>'',model:()=>models},icon:()=>'',fetch:async()=>({ok:true,json:async()=>data}),aiDockSources:[],hidePopover(){sideEffects.push('popover');},closeModal(){sideEffects.push('modal');},renderAssistant(){painted.push(owner);},setTimeout(fn){timers.push(fn);}};context.window=context;
 vm.createContext(context);vm.runInContext(source('shared/ai-prototype.js'),context);
 for(const name of ['findAiConversation','aiConversationTicket','aiConversationForTicket','aiConversationDisplayed','retryAiPrototypeAttachment','updateAiPrototypeAttachment']){let a=workspace.indexOf('function '+name+'(');if(workspace.slice(a-6,a)==='async ')a-=6;const b=workspace.indexOf('\nfunction ',a+1);if(a>=0)vm.runInContext(workspace.slice(a,b),context);}
 const a=workspace.indexOf('async function showAssistantPrototypeScene('),b=workspace.indexOf('\nasync function loadAssistantPrototype',a);vm.runInContext(workspace.slice(a,b),context);
 return{context,states,timers,painted,sideEffects,models,async load(){await context.V3AIPrototype.load();},select(value){owner=value;},deferLoad(){context.V3AIPrototype.load=()=>new Promise(resolve=>{loadResolve=resolve;});},resolveLoad(){loadResolve(data);}};
}

test('attachment scene loading applies only to its original live conversation and never repaints another owner',async()=>{
 const f=attachmentSceneFixture();f.deferLoad();const pending=f.context.showAssistantPrototypeScene('352:1288339');f.select('s2');f.resolveLoad();await pending;
 assert.equal(f.states.s2.draft,'second draft');assert.equal(f.states.s2.model,undefined);assert.equal(f.models.vision,false);assert.equal(f.states.s1.draft,'检查截图里的报错，并对照 app.log。');assert.equal(f.painted.length,0);assert.equal(f.sideEffects.length,0);
});

test('attachment scene loading ignores stopped or deleted conversations',async()=>{
 for(const deleted of [false,true]){
  const f=attachmentSceneFixture(),original=f.states.s1;f.deferLoad();const pending=f.context.showAssistantPrototypeScene('352:1288339');
  if(deleted)f.states.s1={id:3,draft:'new draft'};else original.uiTurnGeneration++;
  f.resolveLoad();await pending;assert.equal(original.draft,'original draft');assert.equal(f.painted.length,0);assert.equal(f.sideEffects.length,0);
 }
});

test('production attachment retry updates only the original attachment while a same-host sibling is selected',async()=>{
 const f=attachmentSceneFixture();await f.load();await f.context.showAssistantPrototypeScene('358:1494663');
 const original=f.states.s1;original.draft='keep original draft';original.model='custom-model';original.effort='low';
 f.context.retryAiPrototypeAttachment();await Promise.resolve();assert.equal(original.prototypeAttachmentPending,true);
 f.context.aiConversations.s1=[{id:1,state:original}];f.states.s1={id:3,draft:'same-host draft',messages:[]};const painted=f.painted.length;
 await f.timers[0]();
 assert.equal(f.states.s1.draft,'same-host draft');assert.equal(f.painted.length,painted);assert.equal(original.draft,'keep original draft');assert.equal(original.model,'custom-model');assert.equal(original.effort,'low');assert.equal(original.prototypeAttachmentPending,false);assert.equal(original.prototypeAttachmentError,false);assert.equal(original.prototypeAttachmentItems.length,1);
});


function feedbackPolicyFixture(){
 const timers=[];let clock=0;
 class Node{
  constructor(){this.children=[];this.dataset={};this.listeners={};this.hidden=false;this.connected=false;this.className='';this.classList={contains:name=>this.className.split(' ').includes(name)};this.attrs={};}
  get isConnected(){return this.parent?this.parent.isConnected:this.connected;}
  append(node){node.parent=this;this.children.push(node);}
  insertBefore(node,before){node.parent=this;this.children.splice(this.children.indexOf(before),0,node);}
  remove(){if(this.parent){this.parent.children=this.parent.children.filter(n=>n!==this);this.parent=null;}this.connected=false;}
  getBoundingClientRect(){return {left:0,right:400,top:0,bottom:100};}
  querySelector(selector){return selector==='.zw-feedback-stack'?this.children.find(n=>n.className==='zw-feedback-stack'):this.parts?.get(selector)||null;}
  querySelectorAll(){return [];}
  setAttribute(key,value){this.attrs[key]=value;}
  getAttribute(key){return this.attrs[key];}
  addEventListener(type,fn){(this.listeners[type]||=[]).push(fn);}
  dispatchEvent(event){for(const fn of this.listeners[event.type]||[])fn(event);}
  set innerHTML(markup){this.markup=markup;this.parts=new Map();for(const [selector,token]of [['[data-feedback-close]','data-feedback-close'],['[data-feedback-action]','data-feedback-action'],['[data-feedback-expand]','data-feedback-expand'],['.zw-feedback-detail','zw-feedback-detail'],['.zw-feedback-summary','zw-feedback-summary']])if(markup.includes(token)){const part=new Node();part.parent=this;this.parts.set(selector,part);}const label=this.parts.get('.zw-feedback-summary');if(label){const m=markup.match(/class="zw-feedback-summary" title="([^"]*)">([^<]*)/);label.title=m[1];label.textContent=m[2];}const detail=this.parts.get('.zw-feedback-detail');if(detail)detail.hidden=true;}
 }
 const host=new Node();host.connected=true;
 const document={addEventListener(){},querySelector:()=>host,createElement:()=>new Node(),head:{append(){}},currentScript:{src:'http://localhost/notification-policy.js'}};
 const context={document,URL,URLSearchParams,Event,location:{search:'',origin:'http://localhost'},MutationObserver:class{observe(){}},setTimeout(fn,ms){const id=timers.length;timers.push({fn,ms,due:clock+ms,cancelled:false,done:false});return id;},clearTimeout(id){if(timers[id])timers[id].cancelled=true;}};context.window=context;context.parent=context;
 vm.createContext(context);vm.runInContext(source('shared/feedback.js'),context);vm.runInContext(source('shared/notification-policy.js'),context);
 const publish=(key,incidentKey,revision=1)=>context.V3Feedback.publish({key,incidentKey,revision,kind:'connection_failed',title:'Title '+key,detail:'Detail '+key,source:key,requiresAction:true,timeSensitive:true,locate(){}},{focused:true,sourceVisible:false});
 return{context,host,timers,publish,advance(ms){const end=clock+ms;for(;;){const next=timers.filter(t=>!t.cancelled&&!t.done&&t.due<=end).sort((a,b)=>a.due-b.due)[0];if(!next)break;clock=next.due;next.done=true;next.fn();}clock=end;}};
}

test('production feedback timeout followed by an incident migration never creates another banner',()=>{
 const f=feedbackPolicyFixture();f.publish('A','existing');const first=f.publish('B','old'),timer=f.timers.at(-1);assert.equal(timer.ms,8000);
 timer.fn();assert.equal(first.node.isConnected,false);const count=f.timers.length;
 const next=f.publish('B','existing',2);assert.equal(next.node,null);assert.equal(f.timers.length,count);assert.equal(f.host.querySelector('.zw-feedback-stack').children.length,0);
});

test('production feedback member migration updates summary in place and retains disclosure and timer state',()=>{
 const f=feedbackPolicyFixture();f.publish('A','old');const shown=f.publish('B','old'),node=shown.node;
 const label=node.querySelector('.zw-feedback-summary'),expand=node.querySelector('[data-feedback-expand]'),detail=node.querySelector('.zw-feedback-detail');assert.equal(label.textContent,'A 等 2 个来源 · Detail A');expand.onclick();assert.equal(detail.hidden,false);const count=f.timers.length;
 f.publish('B','new',2);assert.equal(node.isConnected,true);assert.equal(label.textContent,'A · Detail A');assert.equal(label.title,'A · Detail A');assert.equal(detail.hidden,false);assert.equal(f.timers.length,count);assert.equal(f.host.querySelector('.zw-feedback-stack').children[0],node);
});


test('deleting the selected sibling restores a pending same-host conversation without cloning its request',()=>{
 const f=aiRequestFixture(),original=f.state.s1;
 f.context.aiConversations.s1.push({id:2,state:{id:2,messages:[],attachments:[],draft:'sibling',running:false}});
 f.send();f.jump(2);f.context.aiPendingDelete='s1|2';f.context.deleteAiConversation();f.timers[0]();
 assert.equal(f.state.s1,original);assert.equal(original.messages.length,2);assert.equal(original.running,false);assert(!f.context.allAiConversations().some(c=>c.id===2));
});


test('actual workspace renderer includes the attachment retry action in the failed composer',async()=>{
 const attachment=attachmentSceneFixture();await attachment.load();await attachment.context.showAssistantPrototypeScene('358:1494663');
 const f=componentFocusFixture(),ctx=f.context;Object.assign(f.data,attachment.states.s1);
 ctx.window=ctx;ctx.document.addEventListener=()=>{};ctx.addEventListener=()=>{};
 vm.runInContext(source('shared/ai-assistant.js'),ctx);ctx.renderAssistant();
 const markup=ctx.$('#assistant').markup;
 assert.match(markup,/data-act="ai-prototype-attachment-retry"/);assert.match(markup,/>重试附件<\/button>/);assert.match(markup,/图片读取失败，请重试或移除/);
 const a=workspace.indexOf("case 'ai-prototype-attachment-retry':"),b=workspace.indexOf("case '",a+6);assert(a>=0&&b>a);
 let clicks=0;ctx.retryAiPrototypeAttachment=()=>clicks++;vm.runInContext('switch("ai-prototype-attachment-retry"){'+workspace.slice(a,b)+'}',ctx);assert.equal(clicks,1);
});

test('attachment retry completion preserves edits and other attachments in the original composer',async()=>{
 const f=attachmentSceneFixture();await f.load();await f.context.showAssistantPrototypeScene('358:1494663');
 const d=f.states.s1;d.prototypeAttachmentItems.push({key:'other.log',html:'<span>other.log</span>',pending:false,error:false,hasImages:false});
 f.context.retryAiPrototypeAttachment();await Promise.resolve();d.draft='edited while retry was processing';d.model='chosen-next-model';d.effort='low';
 await f.timers[0]();assert.equal(d.draft,'edited while retry was processing');assert.equal(d.model,'chosen-next-model');assert.equal(d.effort,'low');assert.equal(d.prototypeAttachmentItems.length,2);assert.match(d.prototypeAttachmentsHTML,/other.log/);assert.equal(d.prototypeAttachmentError,false);assert.equal(d.prototypeAttachmentPending,false);
});

test('attachment retry completion cannot revive a removed attachment or a stopped conversation',async()=>{
 for(const remove of [true,false]){const f=attachmentSceneFixture();await f.load();await f.context.showAssistantPrototypeScene('358:1494663');f.context.retryAiPrototypeAttachment();await Promise.resolve();const d=f.states.s1;if(remove)d.prototypeAttachmentItems=[];else d.uiTurnGeneration++;const before=d.prototypeAttachmentsHTML,painted=f.painted.length;await f.timers[0]();assert.equal(d.prototypeAttachmentsHTML,before);assert.equal(f.painted.length,painted);}
});

test('visible notification migration keeps the original expiry deadline',()=>{
 for(const destination of ['new','existing']){const f=feedbackPolicyFixture();f.publish('B','existing');const first=f.publish('A','old'),timers=f.timers.length;f.advance(7000);const next=f.publish('A',destination,2);assert.equal(next.node,first.node);assert.equal(f.timers.length,timers);f.advance(999);assert.equal(next.node.isConnected,true);f.advance(1);assert.equal(next.node.isConnected,false);}
});

test('visible notification migration retains expanded and paused state with the latest action',()=>{
 const f=feedbackPolicyFixture();const first=f.publish('A','old'),node=first.node;node.querySelector('[data-feedback-expand]').onclick();const count=f.timers.length;
 const next=f.publish('A','new',2);assert.equal(next.node,node);assert.equal(node.querySelector('.zw-feedback-detail').hidden,false);assert.equal(node.querySelector('[data-feedback-expand]').getAttribute('aria-expanded'),'true');assert.equal(f.timers.length,count);f.advance(16000);assert.equal(node.isConnected,true);node.querySelector('[data-feedback-expand]').onclick();assert.equal(f.timers.at(-1).ms,8000);f.advance(8000);assert.equal(node.isConnected,false);
});

test('background completion refreshes visible session status without replacing rows or the current editor',()=>{
 const f=aiRequestFixture(),ctx=f.context;ctx.assistantOpen=true;ctx.aiSessionListOpen=true;ctx.window=ctx;ctx.addEventListener=()=>{};
 const input={value:'B draft',selectionStart:2,selectionEnd:4};let markup='';
 ctx.document={activeElement:input,addEventListener(){},createElement(){return{set innerHTML(value){markup=value;},querySelector(selector){const id=selector.match(/data-ai-session-row="([^"]+)"/)[1],section=markup.split('data-ai-session-row="'+id+'"')[1],m=section?.match(/<span class="([^"]+)" title="([^"]*)">([\s\S]*?)<\/span>/);return m?{className:m[1],title:m[2],innerHTML:m[3]}:null;}};}};
 vm.runInContext(source('shared/ai-assistant.js'),ctx);for(const name of ['renderAiSessionList','refreshAiSessionRows']){const a=workspace.indexOf('function '+name+'('),b=workspace.indexOf('\nfunction ',a+1);vm.runInContext(workspace.slice(a,b),ctx);}
 const status={className:'v3-ai-session-status running',title:'运行中',innerHTML:'old'},row={dataset:{aiSessionRow:'1'},querySelector:()=>status};ctx.all=()=>[row];
 ctx.aiConversations.s1.push({id:2,state:{id:2,messages:[],attachments:[],draft:'B draft',running:false}});f.send();f.jump(2);f.timers[0]();
 assert.equal(status.title,'等待确认');assert.match(status.className,/approval/);assert.equal(ctx.document.activeElement,input);assert.equal(input.value,'B draft');assert.equal(input.selectionStart,2);assert.equal(input.selectionEnd,4);assert.equal(f.rendered.length,1);
});


test('retained notification migration rejects controls captured before the action revision changed',()=>{
 const f=feedbackPolicyFixture(),first=f.publish('A','old'),node=first.node;
 const staleAction=node.querySelector('[data-feedback-action]').onclick,staleClose=node.querySelector('[data-feedback-close]').onclick,staleExpand=node.querySelector('[data-feedback-expand]').onclick;
 const next=f.publish('A','new',2);assert.equal(next.node,node);staleAction();staleClose();staleExpand();assert.equal(node.isConnected,true);assert.equal(node.querySelector('.zw-feedback-detail').hidden,true);
 node.querySelector('[data-feedback-action]').onclick();assert.equal(node.isConnected,false);
});
