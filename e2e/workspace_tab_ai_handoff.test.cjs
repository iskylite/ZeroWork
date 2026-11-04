const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync('docs/UI_V3/workspace/app.js','utf8');
const names=['aiTicketOwner','findAiConversation','aiConversationForTicket','aiConversationDisplayed','archiveAiConversation','moveTabAssistant'];
const helpers=names.map(name=>source.slice(source.indexOf('function '+name+'('),source.indexOf('\nfunction ',source.indexOf('function '+name+'(')+1))).join('\n');
const context={assert,document:{createElement:()=>({innerHTML:'',querySelectorAll:()=>[]})}};
vm.createContext(context);
vm.runInContext(`let aiState={},aiConversations={},assistantOpen=false,aiConversationId=20,shownOwner='g9';const aiMovedOwners=new Map();function assistantOwner(){return shownOwner;}function now(){return '12:00';}function aiConversationTitle(d){return d.title||'history';}${helpers}
const a={id:1,title:'A',messages:['A history'],draft:'A draft',running:true,uiTurnGeneration:3,compression:{state:'running',generation:5}};
const b={id:2,title:'B',messages:['B history'],draft:'B draft',running:true,model:'modelB',effort:'high',attachments:['B.txt']};
aiState.s1=a;aiState.s2=b;
moveTabAssistant(1,{id:9,members:[2,1]},'s2');
assert.equal(aiState.g9,b);assert.equal(b.running,true);assert.equal(b.id,2);assert.equal(b.draft,'B draft');assert.equal(b.model,'modelB');assert.equal(b.attachments[0],'B.txt');assert.equal(b.messages[0],'B history');assert.equal(aiState.s2,undefined);
assert.equal(a.running,false);assert.equal(a.ended,true);assert.equal(a.draft,'A draft');assert.equal(aiState.s1,undefined);assert.equal(aiConversations.s1[0].state,a);assert.equal(a.compression.state,'cancelled');assert.equal(aiConversationForTicket({owner:'s1',id:1,generation:3}),null);
assert.equal(aiConversationForTicket({owner:'s2',id:2,generation:0}),b);assert.equal(aiConversationDisplayed({owner:'s2',id:2}),true);
const c={id:3,messages:['C history'],draft:'C draft',running:true};aiState.s3=c;moveTabAssistant(3,{id:9,members:[2,1,3]});assert.equal(aiState.g9,b);assert.equal(b.running,true);assert.equal(c.running,false);assert.equal(aiConversations.s3[0].state,c);assert.deepEqual(b.memberSessionIds,[2,1,3]);assert.equal(b.messages[0],'B history');
moveTabAssistant(4,{id:10,members:[5,4]},'s5');assert.equal(aiState.g10,undefined);
`,context);
console.log('PASS HTML handoff: target identity/history/draft/settings, source stop/archive, stale callbacks, membership, absent assistant');
