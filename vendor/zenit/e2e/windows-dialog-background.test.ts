import { clickTestId, query, request, resizeWindow, waitFor, waitForServerReady } from "./client";
import { assert, run, test } from "./runner";
test("Windows background SDK rejects native dialogs without changing foreground",async()=>{
  await waitForServerReady(15000);
  const before=await request("POST","/windows/native-input",{action:"status"});
  assert(before.foreground_before_launch===before.foreground_after_launch,"background startup changed foreground");
  await resizeWindow(1200,850);
  const resized=await request("POST","/windows/native-input",{action:"status"});
  assert(!resized.foreground_owned && resized.foreground_hwnd===before.foreground_hwnd,"background resize changed foreground");
  assert((await clickTestId("gallery.dialogs")).ok,"dialog fixture unavailable");
  for(const id of ["dialog.open","dialog.save","dialog.folder"]) {
    assert((await clickTestId(id)).ok,`trigger ${id} failed`);
    await waitFor(async()=>(await query("dialog.status"))[0]?.text==="InvalidState" ? true : null,3000,50);
    const after=await request("POST","/windows/native-input",{action:"status"});
    assert(!after.foreground_owned && after.foreground_hwnd===before.foreground_hwnd,`${id} changed native foreground`);
  }
  console.log(`  all dialog kinds refused, foreground=${before.foreground_hwnd}`);
});
run();
