import { decodePng } from "./png";
import { clickTestId, screenPos, tree, inputState, request, screenshot, sleep, waitFor, waitForServerReady } from "./client";
import { assert, getSessionDir, run, test } from "./runner";

const native = (body: object) => request("POST", "/windows/native-input", body);
const press = (vk: number) => native({ action: "key", vk, edge: "press" });
// Modifier chords hold the modifier for a human-like interval: a TSF IME
// re-posts the intercepted key asynchronously, and a chord released right
// after the key-down reaches the app after the modifier is already up
// (real Win10 + Microsoft Pinyin: Shift+Right moved the caret without
// selecting; the worker's atomic chord passed only on the VM).
async function chord(...keys: number[]) {
  for (const vk of keys) await native({ action: "key", vk, edge: "down" });
  await sleep(60);
  for (const vk of [...keys].reverse()) await native({ action: "key", vk, edge: "up" });
}
// What a keystroke does under the active OS input profile. The layout handle
// cannot tell: a third-party Chinese IME reports the same HKL (…0804) as
// Microsoft Pinyin but composes in its own window and sends the app nothing
// until commit (real Win10 machine: native letters and Unicode text vanished).
type Profile="ime"|"latin"|"swallowed";
async function probeProfile(): Promise<Profile> {
  await chord(0x11,0x41); await press(0x08); await sleep(80);
  await press(0x4e); await sleep(250);
  const s=await inputState("input.name");
  const kind: Profile=s.ime_preedit_len>0 ? "ime" : s.buffer.length>0 ? "latin" : "swallowed";
  await press(0x1b); await sleep(80);
  await chord(0x11,0x41); await press(0x08); await sleep(80);
  return kind;
}
// Cycle the installed OS profiles (real Win+Space) until a keystroke behaves
// as wanted; inside a Pinyin profile Shift toggles its Latin mode.
async function selectProfile(want: Profile, switches: { count: number; shifted: boolean }) {
  for(let attempt=0;attempt<6;attempt++) {
    let kind=await probeProfile();
    if(kind===want) return;
    if((want==="latin" && kind==="ime") || (want==="ime" && kind==="latin")) {
      await press(0x10); await sleep(150);
      kind=await probeProfile();
      if(kind===want) { switches.shifted=!switches.shifted; return; }
      await press(0x10); await sleep(150);
    }
    await chord(0x5b,0x20); await sleep(500); switches.count++;
  }
  assert(false,`no OS input profile gives ${want} keystrokes`);
}
// inputState polling whose timeout reports the last state, not just "timeout".
async function untilState(id: string, label: string, pred: (s: any) => boolean, timeoutMs=5000) {
  const start=Date.now(); let last: any=null;
  while(Date.now()-start<timeoutMs) { last=await inputState(id); if(pred(last)) return last; await sleep(30); }
  assert(false,`${label}: timeout, last state ${JSON.stringify(last)}`);
}
async function letters(value: string) {
  for (const char of value) {
    await press(char.toUpperCase().charCodeAt(0));
    await sleep(35);
  }
}
async function capture(stage: string) {
  const path=`${getSessionDir()}/windows-native-${stage}.png`;
  assert((await screenshot(`${getSessionDir()}/windows-target-${stage}.png`)).ok,"target capture failed");
  const desktop=await request("POST", "/windows/native-desktop", {path});
  assert(desktop.ok,"native desktop capture failed");
  if(stage==="pinyin-preedit" || stage==="pinyin-committed") {
    const a=decodePng(path), b=decodePng(`${getSessionDir()}/windows-target-${stage}.png`);
    const scale=b.width/(await tree()).rect.w;
    const field=await screenPos("input.name");
    const x0=Math.floor(field.x*scale), x1=Math.min(b.width,Math.floor((field.x+field.w+120)*scale));
    const y0=Math.ceil((field.y+field.h+3)*scale), y1=Math.min(b.height,Math.floor((field.y+field.h+65)*scale));
    assert(desktop.client_x+b.width<=a.width && desktop.client_y+b.height<=a.height,"desktop capture truncated the physical client");
    let changed=0;
    for(let y=y0;y<y1;y++)for(let x=x0;x<x1;x++) {
      const i=((y+desktop.client_y)*a.width+x+desktop.client_x)*a.channels,j=(y*b.width+x)*b.channels;
      if([0,1,2].some(c=>Math.abs(a.pixels[i+c]-b.pixels[j+c])>3))changed++;
    }
    console.log(`  system candidate pixels=${changed}, physical client origin=${desktop.client_x},${desktop.client_y}`);
    if(stage==="pinyin-preedit")assert(changed>=1000,"native OS candidate panel is absent below the caret");
    else assert(changed<=200,`native candidate panel remained after commit (${changed} pixels)`);
  }
  console.log(`  ${stage}: ${path}`);
}

test("Windows native attended input session: Microsoft Pinyin composition, commit and cancellation", async () => {
  await waitForServerReady(15000);
  const initial=await native({action:"activate"});
  assert(initial.foreground && initial.session > 0,"native worker is not in an interactive foreground session");
  const originalLayout=initial.layout;
  console.log(`  original layout=${originalLayout}, session=${initial.session}`);
  let originalKind: Profile="latin";
  const switches={count:0,shifted:false};
  try {
    await clickTestId("input.name");
    originalKind=await probeProfile();
    console.log(`  original profile keystrokes: ${originalKind}`);
    await selectProfile("ime",switches);
    const chinese=await native({action:"status"});
    console.log(`  IME profile layout=${chinese.layout}, open=${chinese.ime_open}, conversion=${chinese.conversion}, switches=${switches.count}`);
    await letters("nihao");
    let composing=await inputState("input.name");
    console.log(`  after typing nihao: ${JSON.stringify(composing)}; status=${JSON.stringify(await native({action:"status"}))}`);
    if(composing.ime_preedit_len===0 && composing.buffer==="nihao") {
      await chord(0x11,0x41);
      await press(0x08);
      await press(0x10); // Pinyin's native Shift toggle leaves Latin mode.
      await letters("nihao");
    }
    composing=await waitFor(async()=> {
      const state=await inputState("input.name");
      return state.ime_preedit_len>0 ? state : null;
    },5000,30);
    console.log(`  composing state: ${JSON.stringify(composing)}`);
    console.log(`  composing=${JSON.stringify(composing)}`);
    assert(composing.buffer==="","native preedit leaked into the committed buffer");
    await capture("pinyin-preedit");
    await press(0x20);
    const committed=await waitFor(async()=> {
      const state=await inputState("input.name");
      return state.ime_preedit_len===0 && state.buffer.length>0 ? state : null;
    },5000,30);
    assert(committed.buffer==="你好",`native Pinyin commit wrong or duplicated: ${JSON.stringify(committed)}`);
    await sleep(150);
    await capture("pinyin-committed");
    await letters("zhongwen");
    await untilState("input.name","s.ime_preedit_len>0",s=>s.ime_preedit_len>0);
    await press(0x1b);
    const cancelled=await waitFor(async()=> {
      const state=await inputState("input.name");
      return state.ime_preedit_len===0 ? state:null;
    },5000,30);
    assert(cancelled.buffer==="你好","native Escape committed or retained cancelled preedit");
    await capture("pinyin-cancelled");
    await letters("nihao");
    await untilState("input.name","s.ime_preedit_len>0",s=>s.ime_preedit_len>0);
    await clickTestId("input.email");
    await untilState("input.name","s.ime_preedit_len===0",s=>s.ime_preedit_len===0);
    assert((await inputState("input.name")).buffer==="你好","focus change committed the active preedit");
    assert((await inputState("input.email")).ime_preedit_len===0 && (await inputState("input.email")).buffer==="",
      "cancelled native preedit was transferred to the new field");
    await clickTestId("input.notes");
    await letters("zhongwen");
    await untilState("input.notes","s.ime_preedit_len>0",s=>s.ime_preedit_len>0);
    await press(0x20);
    await untilState("input.notes","s.buffer==='中文'",s=>s.buffer==="中文");
    await press(0x0d);
    await letters("nihao");
    await untilState("input.notes","s.ime_preedit_len>0",s=>s.ime_preedit_len>0);
    await press(0x20);
    await untilState("input.notes","s.buffer==='中文\n你好'",s=>s.buffer==="中文\n你好");
    await capture("pinyin-multiline");
    await clickTestId("input.name");
    await chord(0x11,0x41);
    const selected=await waitFor(async()=> {
      const state=await inputState("input.name");
      return state.anchor===0 && state.cursor_pos===6 ? state:null;
    },3000,30);
    assert(selected.buffer==="你好","native Ctrl+A changed the buffer");
    console.log("  stage: native Unicode selection, collapse, Delete and undo/redo");
    await press(0x27);
    await untilState("input.name","s.cursor_pos===6 && s.anchor===-1",s=>s.cursor_pos===6 && s.anchor===-1);
    await press(0x24);
    await chord(0x10,0x27);
    await untilState("input.name","s.cursor_pos===3 && s.anchor===0",s=>s.cursor_pos===3 && s.anchor===0);
    await capture("native-unicode-selection");
    await chord(0x10,0x27);
    await untilState("input.name","s.cursor_pos===6 && s.anchor===0",s=>s.cursor_pos===6 && s.anchor===0);
    await press(0x25);
    await untilState("input.name","s.cursor_pos===0 && s.anchor===-1",s=>s.cursor_pos===0 && s.anchor===-1);
    await press(0x23);
    await chord(0x10,0x25);
    await untilState("input.name","s.cursor_pos===3 && s.anchor===6",s=>s.cursor_pos===3 && s.anchor===6);
    await press(0x2e);
    await untilState("input.name","s.buffer==='你'",s=>s.buffer==="你");
    await chord(0x11,0x5a);
    await untilState("input.name","s.buffer==='你好'",s=>s.buffer==="你好");
    await chord(0x11,0x59);
    await untilState("input.name","s.buffer==='你'",s=>s.buffer==="你");
    await chord(0x11,0x5a);
    await untilState("input.name","s.buffer==='你好'",s=>s.buffer==="你好");
    await chord(0x11,0x41);
    await press(0x08);
    await untilState("input.name","s.buffer===''",s=>s.buffer==="");
    await selectProfile("latin",switches);
    const longText="abcdefghijklmnopqrstuvwxyz".repeat(4);
    await letters(longText);
    await waitFor(async()=> {
      const state=await inputState("input.name");
      return state.buffer===longText && state.cursor_pos===104 && state.scroll_x>0 ? state:null;
    },3000,30);
    await capture("native-long-end");
    await press(0x24);
    await waitFor(async()=> {
      const state=await inputState("input.name");
      return state.cursor_pos===0 && state.scroll_x===0 ? state:null;
    },3000,30);
    await capture("native-long-home");
    console.log("  stage: native Shift+End/Home selection follows viewport and arrows collapse it");
    await chord(0x10,0x23);
    await untilState("input.name","s.buffer===longText && s.anchor===0 && s.cursor_pos===104 && s.scroll_x>0",s=>s.buffer===longText && s.anchor===0 && s.cursor_pos===104 && s.scroll_x>0);
    await capture("native-long-selected");
    await press(0x27);
    await untilState("input.name","s.cursor_pos===104 && s.anchor===-1",s=>s.cursor_pos===104 && s.anchor===-1);
    await chord(0x10,0x24);
    await untilState("input.name","s.anchor===104 && s.cursor_pos===0 && s.scroll_x===0",s=>s.anchor===104 && s.cursor_pos===0 && s.scroll_x===0);
    await press(0x25);
    await untilState("input.name","s.buffer===longText && s.cursor_pos===0 && s.anchor===-1 && s.scroll_x===0",s=>s.buffer===longText && s.cursor_pos===0 && s.anchor===-1 && s.scroll_x===0);
    console.log("  native IME, multiline commit, cancellation, Unicode selection/Delete/undo/redo and caret-following selection scroll verified");
  } finally {
    // A failed stage may have left focus elsewhere, and the IME state belongs
    // to the foreground thread: every key below (Esc, the Shift undo, the
    // probe's typing) goes to the app only after it owns the foreground and
    // input.name has focus again.
    const refocus=async()=>{ if(!(await native({action:"status"})).foreground_owned) await native({action:"activate"}); await clickTestId("input.name"); await sleep(100); };
    await refocus();
    await press(0x1b);
    // Undo the Pinyin Latin-mode toggle before leaving its profile.
    if(switches.shifted) { await press(0x10); await sleep(150); switches.shifted=false; }
    // Restore the user's profile: same layout handle and the same keystroke
    // behaviour (two Chinese profiles share the handle).
    let restored=false;
    for(let attempt=0;attempt<8 && !restored;attempt++) {
      await refocus();
      if((await native({action:"status"})).layout===originalLayout && (await probeProfile())===originalKind) { restored=true; break; }
      await chord(0x5b,0x20);
      await sleep(500);
    }
    // Reported after the stage failure, never in place of it.
    if(!restored) console.log("  WARNING: original OS input profile was not restored");
  }
});
run();
