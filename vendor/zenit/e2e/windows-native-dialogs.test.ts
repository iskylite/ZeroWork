import { decodePng } from "./png";
import { clickTestId, query, request, resizeWindow, sleep, waitFor, waitForServerReady } from "./client";
import { assert, getSessionDir, run, test } from "./runner";

const native = (body: object) => request("POST", "/windows/native-input", body);
const press = (vk: number) => native({action:"key",vk,edge:"press"});
const chord = (...keys: number[]) => native({action:"chord",keys});

test("Windows native dialogs return Unicode open/save/folder paths, cancellation and buffer errors", async () => {
  await waitForServerReady(15000);
  await resizeWindow(1200,850);
  assert((await native({action:"activate"})).foreground,"owned app did not activate");
  assert((await clickTestId("gallery.dialogs")).ok,"dialog gallery activation failed");
  const directory=(await query("dialog.directory"))[0]?.text;
  assert(directory?.includes("dialog-fixtures"),"missing isolated dialog directory");
  const open=async(id:string,stage:string) => {
    assert((await clickTestId(id)).ok,`${stage}: trigger failed`);
    const status=await waitFor(async()=>{
      const s=await native({action:"status"});
      return s.foreground_owned && s.foreground_class==="#32770" && s.foreground_owner===s.hwnd ? s : null;
    },10000,100);
    const path=`${getSessionDir()}/windows-native-dialog-${stage}.png`;
    // Foreground ownership precedes Shell's first paint, particularly under
    // x86 emulation. Wait for the same strict pixel criterion, rather than
    // assuming a fixed delay is enough for an independently painted window.
    const started=Date.now();
    const fraction=await waitFor(async()=>{
      const owned=await native({action:"status"});
      assert(owned.foreground_owned && owned.foreground_hwnd===status.foreground_hwnd &&
        owned.foreground_class==="#32770" && owned.foreground_owner===owned.hwnd,
        `${stage}: native dialog lost foreground ownership before painting`);
      assert((await request("POST","/windows/native-desktop",{path})).ok,`${stage}: desktop capture failed`);
      const png=decodePng(path);
      let neutral=0;
      for(let i=0;i<png.pixels.length;i+=png.channels) {
        const rgb=[png.pixels[i],png.pixels[i+1],png.pixels[i+2]];
        if(Math.max(...rgb)-Math.min(...rgb)<12 && Math.max(...rgb)>10)neutral++;
      }
      const value=neutral/(png.width*png.height);
      console.log(`  ${stage}: native paint after ${Date.now()-started}ms, neutral coverage=${value}`);
      return value>.4 ? value : null;
    },10000,100);
    assert(fraction>.4,`${stage}: native dialog pixels absent; neutral coverage=${fraction}`);
    console.log(`  ${stage}: ${status.foreground_title}, native neutral coverage=${fraction}, ${path}`);
  };
  const result=async(expected:string) => {
    await waitFor(async()=>{
      const s=await native({action:"status"});return s.foreground ? s : null;
    },10000,100);
    const node=await waitFor(async()=>{
      const node=(await query("dialog.status"))[0];return node?.text===expected ? node : null;
    },10000,100);
    assert(node.text===expected,`dialog result ${node.text}, expected ${expected}`);
    console.log(`  result: ${node.text}`);
  };
  const selectFile=async() => {
    await chord(0x12,0x4e); // Alt+N: native File name edit
    await chord(0x11,0x41);
    assert((await native({action:"text",text:`${directory}\\输入-🧪.txt`})).ok,"Unicode filename typing failed");
    await sleep(100);
    await press(0x0d);
  };
  try {
    await open("dialog.open","cancel");
    await press(0x1b);
    await result("cancelled");
    await open("dialog.open","open");
    await selectFile();
    await result(`${directory}\\输入-🧪.txt`);
    await open("dialog.save","save");
    await press(0x0d); // Accept the real, prefilled Unicode suggestion.
    await result(`${directory}\\保存-🧪.txt`);
    await open("dialog.folder","folder");
    await press(0x0d);
    await result(`${directory}\\文件夹`);
    await open("dialog.short","short-buffer");
    await selectFile();
    await result("BufferTooSmall");
    await open("dialog.open","reopen-cancel");
    await press(0x1b);
    await result("cancelled");
  } finally {
    const s=await native({action:"status"}).catch(()=>null);
    if(s?.foreground_owned && s.foreground_class==="#32770") await press(0x1b).catch(()=>{});
  }
});
run();
