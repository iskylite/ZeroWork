import { decodePng } from "./png";
import { request, resizeWindow, screenshot, sleep, tree, waitFor, waitForServerReady } from "./client";
import { assert, getSessionDir, run, test } from "./runner";

const native=(body:object)=>request("POST","/windows/native-input",body);

// Attended native window acceptance: one owned App, close remains last.
async function verifyDesktop(stage:string,initial=false){
  // Tree geometry can settle before the DWM maximize/restore animation.
  await sleep(600);
  const target=`${getSessionDir()}/windows-custom-caption-${stage}-target.png`;
  const desktop=`${getSessionDir()}/windows-custom-caption-${stage}-desktop.png`;
  assert((await screenshot(target)).ok,"caption target capture failed");
  const capture=await request("POST","/windows/native-desktop",{path:desktop});
  assert(capture.ok,"caption desktop capture failed");
  if(initial) assert(capture.client_y===0,`system caption was not removed: client_y=${capture.client_y}`);
  const a=decodePng(desktop),b=decodePng(target),width=(await tree()).rect.w,scale=b.width/width;
  assert(capture.client_x+b.width<=a.width && capture.client_y+b.height<=a.height,"desktop truncated the custom client");
  let bodyMatches=0;
  for(const y of [150,220,300,400,500]) for(const x of [20,100,200,350,500,650,750]){
    const px=Math.floor(x*scale),py=Math.floor(y*scale);
    const p=((py+capture.client_y)*a.width+px+capture.client_x)*a.channels,q=(py*b.width+px)*b.channels;
    if([0,1,2].every(c=>Math.abs(a.pixels[p+c]-b.pixels[q+c])<=5))bodyMatches++;
  }
  assert(bodyMatches>=30,`desktop did not show the actual App body: ${bodyMatches}/35 samples`);
  const counts:number[]=[];
  for(const [lo,hi] of [[width-140,width-96],[width-94,width-50],[width-48,width-4]]){
    let changed=0,ink=0;
    for(let y=Math.ceil(8*scale);y<Math.floor(30*scale);y++)
      for(let x=Math.ceil(lo*scale);x<Math.floor(hi*scale);x++){
        const p=((y+capture.client_y)*a.width+x+capture.client_x)*a.channels,q=(y*b.width+x)*b.channels;
        if([0,1,2].some(c=>Math.abs(a.pixels[p+c]-b.pixels[q+c])>5))changed++;
        if([0,1,2].every(c=>a.pixels[p+c]<110))ink++;
      }
    counts.push(changed);
    assert(ink>=6 && ink<=200*scale*scale,`${stage}: missing native caption glyph or solid black region: ${ink}`);
  }
  console.log(`  ${stage} native caption overlay pixels=${counts.join(",")}, client offset=${capture.client_x},${capture.client_y}`);
  assert(counts.every(n=>n>=6),"native caption controls were not painted over the App surface");
}

test("Windows custom titlebar preserves visible native controls and maximize/restore",async()=>{
  await waitForServerReady(15000);
  assert((await resizeWindow(800,550)).ok,"caption fixture resize failed");
  assert((await native({action:"activate"})).foreground,"caption App did not activate");
  await verifyDesktop("initial",true);
  assert((await native({action:"caption-toggle"})).ok,"native maximize caption click failed");
  await waitFor(async()=>{const r=(await tree()).rect;return r.w>800 || r.h>550 ? r:null;},5000,100);
  await verifyDesktop("maximized");
  assert((await native({action:"caption-toggle"})).ok,"native restore caption click failed");
  await waitFor(async()=>{const r=(await tree()).rect;return r.w===800 && r.h===550 ? r:null;},5000,100);
  await verifyDesktop("restored");
  const closed=await native({action:"close"});
  assert(closed.ok && closed.exited && closed.exit_code===0 && !closed.hwnd_alive,"owned custom window did not close cleanly");
});
run();
