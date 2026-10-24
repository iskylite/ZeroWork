import { clickTestId, query, request, resizeWindow, screenshot, waitForServerReady } from "./client";
import { assert, getSessionDir, run, test } from "./runner";
test("Windows background RPC preserves foreground and denies native desktop input", async()=> {
  await waitForServerReady(15000);
  const before=await request("POST","/windows/native-input",{action:"status"});
  assert(before.foreground_before_launch===before.foreground_after_launch,
    `background launch changed foreground: ${before.foreground_before_launch}->${before.foreground_after_launch}`);
  assert(!before.foreground,"background test window stole foreground");
  for(const [width,height] of [[900,650],[1000,730]]) {
    assert((await resizeWindow(width,height)).ok,"background resize failed");
    const resized=await request("POST","/windows/native-input",{action:"status"});
    assert(!resized.foreground_owned && resized.foreground_hwnd===before.foreground_hwnd,"background resize stole foreground");
  }
  assert((await clickTestId("gallery.drops")).ok,"render-gallery drops fixture required");
  assert((await clickTestId("drop.source")).ok,"drag source fixture required");
  assert(JSON.parse((await query("drop.source-status"))[0].text!).phase==="refused","background SDK source was allowed to start native OLE");
  for(const [path,body] of [
    ["/windows/native-input",{action:"activate"}],
    ["/windows/native-input",{action:"close"}],
    ["/windows/native-input",{action:"key",vk:0x41,edge:"press"}],
    ["/windows/native-input",{action:"text",text:"forbidden"}],
    ["/windows/native-input",{action:"drag-start",kind:"text",text:"forbidden",x:20,y:20,operations:1}],
    ["/windows/native-input",{action:"pointer-down",x:20,y:20}],
    ["/windows/native-input",{action:"drag-move",x:20,y:20}],
    ["/windows/native-input",{action:"drag-release"}],
    ["/windows/native-input",{action:"drag-cancel"}],
    ["/windows/native-input",{action:"receiver-start",operations:7}],
    ["/windows/native-input",{action:"receiver-status"}],
    ["/windows/native-input",{action:"receiver-move"}],
    ["/windows/native-input",{action:"receiver-activate"}],
    ["/windows/native-input",{action:"receiver-stop"}],
    ["/windows/native-desktop",{path:`${getSessionDir()}/forbidden-desktop.png`}]
  ] as const) {
    let rejected=false;
    try { await request("POST",path,body); }
    catch(error) { rejected=String(error).includes("requires --allow-foreground"); }
    assert(rejected,`foreground operation was not explicitly refused: ${path}`);
  }
  assert((await screenshot(`${getSessionDir()}/windows-background.png`)).ok,"background target capture failed");
  const after=await request("POST","/windows/native-input",{action:"status"});
  assert(!after.foreground && after.foreground_hwnd===before.foreground_hwnd,"ordinary RPC altered system foreground");
  console.log(`  preserved foreground=${after.foreground_hwnd}, owned=${after.hwnd}`);
});
run();
