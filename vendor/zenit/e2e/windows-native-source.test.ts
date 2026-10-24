import {createHash} from "node:crypto";
import {clickTestId,query,request,resizeWindow,screenshot,sleep,tree,waitFor,waitForServerReady} from "./client";
import {decodePng} from "./png";
import {assert,getSessionDir,run,test} from "./runner";
const native=(body:object)=>request("POST","/windows/native-input",body);
const source=async()=>{const text=(await query("drop.source-status"))[0]?.text;return text&&text!=="ready"?JSON.parse(text):null;};
test("Windows SDK source remains responsive and delivers owned payload plus completion",async()=>{
 await waitForServerReady(15000);await resizeWindow(1400,1100);
 assert((await native({action:"activate"})).foreground,"app not foreground");
 await clickTestId("gallery.drops");
 const s=(await query("drop.source"))[0].rect,t=(await query("drop.target"))[0].rect;
 const sx=s.x+s.w/2,sy=s.y+s.h/2,tx=t.x+t.w*.6,ty=t.y+t.h*.6;
 for(const preview of [false,true]){
   if(preview)await clickTestId("drop.source-preview");
   const old=await source();
   try{
     assert((await native({action:"pointer-down",x:sx,y:sy})).ok,"native pointer down failed");
     const active=await waitFor(async()=>{const r=await source();assert(r?.phase!=="refused","SDK refused real source gesture");return r?.phase==="active"&&r.token!==old?.token?r:null;},5000,50).catch(async e=>{console.log(`  start failed: old=${JSON.stringify(old)}, current=${JSON.stringify(await source())}, rect=${JSON.stringify((await query("drop.source"))[0].rect)}`);throw e;});
     assert(active.token>0&&active.preview===preview,"source token/preview invalid");
     // RPC queries and frame rendering must run while OLE is waiting for up.
     for(let i=0;i<4;i++){await sleep(50);assert((await source())?.phase==="active","drag completed before release");}
     await native({action:"drag-move",x:tx,y:ty});await sleep(200);
     assert((await source())?.phase==="active","drag ended during motion");
     if(preview){
       const targetPath=`${getSessionDir()}/windows-source-target.png`,desktopPath=`${getSessionDir()}/windows-source-preview.png`;
       assert((await screenshot(targetPath)).ok,"source target capture failed");
       const desktop=await request("POST","/windows/native-desktop",{path:desktopPath});assert(desktop.ok,"source desktop capture failed");
       const a=decodePng(targetPath),b=decodePng(desktopPath),scale=a.width/(await tree()).rect.w;
       const x0=Math.ceil((tx-4)*scale),y0=Math.ceil((ty-4)*scale),x1=Math.floor((tx+76)*scale),y1=Math.floor((ty+36)*scale);
       assert(x0>=0&&y0>=0&&x1<a.width&&y1<a.height,"preview outside client");
       let changed=0;
       for(let y=y0;y<y1;y++)for(let x=x0;x<x1;x++){
         const i=(y*a.width+x)*4,j=((y+desktop.client_y)*b.width+x+desktop.client_x)*4;
         if([0,1,2].some(c=>Math.abs(a.pixels[i+c]-b.pixels[j+c])>8))changed++;
       }
       assert(changed>(x1-x0)*(y1-y0)*.2,`native source preview invisible: ${changed} changed pixels`);
       console.log(`  real desktop preview: ${changed} changed pixels in ${x1-x0}x${y1-y0} physical bounds`);
     }
     await native({action:"drag-release"});
     const done=await waitFor(async()=>{const r=await source();return r?.phase==="complete"&&r.token===active.token?r:null;},7000,50);
     assert(done.operation===1&&!done.untrusted,`source completion invalid: ${JSON.stringify(done)}`);
     const received=JSON.parse((await query("drop.status"))[0].text!);
     assert(received.phase==="drop"&&received.kind===2&&received.untrusted,"native self receiver missing");
     assert((await query("drop.hash"))[0].text===createHash("sha256").update("source 中文 🧪").digest("hex"),"borrowed source payload changed");
     console.log(`  native SDK source: token=${done.token}, preview=${preview}, effect=${done.operation}; RPC responsive`);
   }finally{await native({action:"drag-cancel"}).catch(()=>{});}
 }
 const beforeCancel=JSON.parse((await query("drop.status"))[0].text!);
 try{
   await native({action:"pointer-down",x:sx,y:sy});
   const active=await waitFor(async()=>{const r=await source();return r?.phase==="active"?r:null;},5000,50);
   await native({action:"drag-move",x:tx,y:ty});await sleep(100);
   await native({action:"chord",keys:[0x1b]});
   const done=await waitFor(async()=>{const r=await source();return r?.phase==="complete"&&r.token===active.token?r:null;},7000,50);
   assert(done.operation===0&&!done.untrusted,"Escape did not emit cancellation");
   const received=JSON.parse((await query("drop.status"))[0].text!);
   assert(received.drops===beforeCancel.drops,"cancel delivered payload");
   assert(received.leaves>beforeCancel.leaves,"cancel left stale target hover");
   console.log(`  native SDK source cancellation: token=${done.token}, no drop, target cleared`);
 }finally{await native({action:"drag-cancel"}).catch(()=>{});}
 try{
   await native({action:"pointer-down",x:sx,y:sy});
   const active=await waitFor(async()=>{const r=await source();return r?.phase==="active"?r:null;},5000,50);
   await clickTestId("drop.source-cancel");
   const done=await waitFor(async()=>{const r=await source();return r?.phase==="complete"&&r.token===active.token?r:null;},7000,50);
   assert(done.operation===0,"programmatic cancellation did not finish while button held");
   console.log(`  native SDK source explicit cancellation before button release: token=${done.token}`);
 }finally{await native({action:"drag-cancel"}).catch(()=>{});}
});
run();
