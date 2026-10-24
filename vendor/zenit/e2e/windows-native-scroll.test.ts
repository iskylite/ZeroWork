import { spawnSync } from "node:child_process";
import { clickTestId, query, request, screenPos, screenshot, waitFor, waitForServerReady } from "./client";
import { assert, getSessionDir, run, test } from "./runner";

// Post native wheel messages to this suite's HWND only. No desktop-wide input,
// and no Harness /scroll shortcut: this exercises the Win32 normalization path.
async function nativeWheel(part: string, horizontal: boolean, delta: number) {
  const owned = await request("POST", "/windows/native-input", { action: "status" });
  assert(owned.ok && owned.pid > 0 && owned.hwnd > 0, "missing owned native window");
  const r = await screenPos(`story.scrolling.${part}`);
  const script = `
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ScrollProbe {
 [StructLayout(LayoutKind.Sequential)] public struct Point { public int X,Y; }
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
 [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
 [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h,ref Point p);
 [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
 public static void Send(long handle,uint expected,double x,double y,bool horizontal,int delta) {
  IntPtr h=new IntPtr(handle);uint pid;GetWindowThreadProcessId(h,out pid);
  if(pid!=expected)throw new Exception("Window owner changed");
  IntPtr old=SetThreadDpiAwarenessContext(new IntPtr(-4));
  try {
   double scale=GetDpiForWindow(h)/96.0;
   Point p=new Point{X=(int)Math.Round(x*scale),Y=(int)Math.Round(y*scale)};
   if(!ClientToScreen(h,ref p))throw new Exception("ClientToScreen failed");
   int xy=(p.X&65535)|((p.Y&65535)<<16);
   if(!PostMessage(h,horizontal?0x20eu:0x20au,new IntPtr(delta<<16),new IntPtr(xy)))throw new Exception("PostMessage failed");
  } finally {SetThreadDpiAwarenessContext(old);}
 }
}
'@
[ScrollProbe]::Send(${owned.hwnd},${owned.pid},${r.x + 40},${r.y + 40},$${horizontal},${delta})
`;
  const result = spawnSync("powershell.exe", ["-NoProfile", "-EncodedCommand", Buffer.from(script, "utf16le").toString("base64")], { encoding: "utf8", timeout: 30000 });
  assert(result.status === 0, `native wheel sender failed: ${result.stderr}`);
}
async function offset(part: string, axis: "x" | "y") {
  const nodes = await query(`story.scrolling.${part}.status`);
  const match = new RegExp(`${axis}=(-?\\d+)`).exec(JSON.stringify(nodes));
  assert(match != null, "missing scrolling status");
  return Number(match![1]);
}
test("Windows native wheel: logical-point normalization and horizontal routing", async () => {
  await waitForServerReady(15000);
  assert((await clickTestId("nav.scrolling")).ok, "scrolling navigation failed");
  await nativeWheel("vertical", false, -120);
  await waitFor(async () => (await offset("vertical", "y")) === 40, 5000);
  await nativeWheel("vertical", false, -30);
  await waitFor(async () => (await offset("vertical", "y")) === 50, 5000);
  // Win32 WM_MOUSEHWHEEL uses positive delta for scroll-right.
  await nativeWheel("horizontal", true, 120);
  await waitFor(async () => (await offset("horizontal", "x")) === 40, 5000);
  await nativeWheel("horizontal", true, -30);
  await waitFor(async () => (await offset("horizontal", "x")) === 30, 5000);
  await nativeWheel("horizontal", true, -120);
  await waitFor(async () => (await offset("horizontal", "x")) === 0, 5000);
  await nativeWheel("vertical", false, 120);
  await waitFor(async () => (await offset("vertical", "y")) === 10, 5000);
  assert((await screenshot(`${getSessionDir()}/native-scroll.png`)).ok, "native scroll screenshot failed");
});
run();
