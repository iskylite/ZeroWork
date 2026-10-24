// CGEvent synthetic input: drag / scroll / click.
//
// Main purpose: **real-hardware verification of drag-drop**, dragging real files from Finder into a
// zenit window. Synthetic CGEvent mousedown->dragged->mouseup drives a real macOS NSDragging
// session, so the target window's performDragOperation: fires with a real pasteboard (criterion:
// with ZENIT_DEBUG_DRAG=1 stderr has `[DRAG] kind=3 ... paths=/...`). System Events `click at` is
// atomic and cannot express hold-and-drag.
//
// Usage (coords global screen, top-left origin):
//   swift scripts/cgevent.swift drag   <sx> <sy> <ex> <ey>
//   swift scripts/cgevent.swift scroll <x> <y> <ticks>     # ticks<0 scroll down
//   swift scripts/cgevent.swift click  <x> <y>
//
// Calling process must hold Accessibility permission.

import CoreGraphics
import Foundation

let src = CGEventSource(stateID: .hidSystemState)

func post(_ type: CGEventType, _ p: CGPoint) {
    guard let e = CGEvent(mouseEventSource: src, mouseType: type,
                          mouseCursorPosition: p, mouseButton: .left) else { return }
    e.post(tap: .cghidEventTap)
}

func usage() -> Never {
    FileHandle.standardError.write("""
    usage:
      cgevent.swift drag      <sx> <sy> <ex> <ey>
      cgevent.swift dragmulti <x> <y1> <y2> <ex> <ey>
      cgevent.swift draghold  <sx> <sy> <ex> <ey> <holdSeconds>
      cgevent.swift scroll    <x> <y> <ticks>
      cgevent.swift click     <x> <y>

    """.data(using: .utf8)!)
    exit(2)
}

let a = CommandLine.arguments
guard a.count >= 2 else { usage() }

switch a[1] {
case "drag":
    guard a.count >= 6,
          let sx = Double(a[2]), let sy = Double(a[3]),
          let ex = Double(a[4]), let ey = Double(a[5]) else { usage() }

    // Move cursor to start and stabilize one frame first, else mousedown treated as click from
    // previous position.
    post(.mouseMoved, CGPoint(x: sx, y: sy))
    usleep(200_000)
    post(.leftMouseDown, CGPoint(x: sx, y: sy))
    // Start drag immediately after press: holding multiple-select in Finder too long collapses
    // selection into single file, multi-file drag becomes single (tested).
    usleep(30_000)

    // Step-wise dragging: jumping straight to end deemed 'non-drag' by system, must have continuous
    // intermediate events for system to start NSDragging session and attach pasteboard.
    let steps = 40
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        post(.leftMouseDragged, CGPoint(x: sx + (ex - sx) * t, y: sy + (ey - sy) * t))
        usleep(25_000)
    }
    // End point pause several frames, give draggingUpdated dispatch chance.
    for _ in 0..<10 {
        post(.leftMouseDragged, CGPoint(x: ex, y: ey))
        usleep(50_000)
    }
    post(.leftMouseUp, CGPoint(x: ex, y: ey))
    usleep(300_000)
    print("drag posted: (\(sx),\(sy)) -> (\(ex),\(ey))")

case "draghold":
    // Drag hover over target N seconds before release -- screenshot-verify on_drag_enter hover
    // highlight.
    guard a.count >= 7,
          let sx = Double(a[2]), let sy = Double(a[3]),
          let ex = Double(a[4]), let ey = Double(a[5]),
          let holdSec = Double(a[6]) else { usage() }
    post(.mouseMoved, CGPoint(x: sx, y: sy))
    usleep(200_000)
    post(.leftMouseDown, CGPoint(x: sx, y: sy))
    usleep(30_000)
    let hsteps = 40
    for i in 1...hsteps {
        let t = Double(i) / Double(hsteps)
        post(.leftMouseDragged, CGPoint(x: sx + (ex - sx) * t, y: sy + (ey - sy) * t))
        usleep(25_000)
    }
    // Keep feeding dragged events during hover or system thinks drag stalled.
    let ticks = Int(holdSec * 10)
    for _ in 0..<max(1, ticks) {
        post(.leftMouseDragged, CGPoint(x: ex, y: ey))
        usleep(100_000)
    }
    post(.leftMouseUp, CGPoint(x: ex, y: ey))
    usleep(300_000)
    print("draghold posted: (\(sx),\(sy)) -> (\(ex),\(ey)) hold=\(holdSec)s")

case "dragmulti":
    // Multi-select drag: first click(x,y1) then shift-click(x,y2) build continuous selection, then
    // immediately start drag from y2 -- no release, no pause in between or Finder collapses
    // selection to single.
    guard a.count >= 7,
          let x = Double(a[2]), let y1 = Double(a[3]), let y2 = Double(a[4]),
          let ex = Double(a[5]), let ey = Double(a[6]) else { usage() }

    func shiftClick(_ p: CGPoint) {
        for t in [CGEventType.leftMouseDown, .leftMouseUp] {
            if let e = CGEvent(mouseEventSource: src, mouseType: t,
                               mouseCursorPosition: p, mouseButton: .left) {
                e.flags = .maskShift
                e.post(tap: .cghidEventTap)
            }
            usleep(60_000)
        }
    }

    post(.mouseMoved, CGPoint(x: x, y: y1))
    usleep(150_000)
    post(.leftMouseDown, CGPoint(x: x, y: y1))
    usleep(60_000)
    post(.leftMouseUp, CGPoint(x: x, y: y1))
    usleep(250_000)
    shiftClick(CGPoint(x: x, y: y2))
    usleep(250_000)

    post(.leftMouseDown, CGPoint(x: x, y: y2))
    usleep(30_000)
    let msteps = 40
    for i in 1...msteps {
        let t = Double(i) / Double(msteps)
        post(.leftMouseDragged, CGPoint(x: x + (ex - x) * t, y: y2 + (ey - y2) * t))
        usleep(25_000)
    }
    for _ in 0..<10 {
        post(.leftMouseDragged, CGPoint(x: ex, y: ey))
        usleep(50_000)
    }
    post(.leftMouseUp, CGPoint(x: ex, y: ey))
    usleep(300_000)
    print("dragmulti posted: rows y=\(y1),\(y2) at x=\(x) -> (\(ex),\(ey))")

case "scroll":
    guard a.count >= 5,
          let x = Double(a[2]), let y = Double(a[3]), let ticks = Int32(a[4]) else { usage() }
    post(.mouseMoved, CGPoint(x: x, y: y))
    usleep(100_000)
    let step: Int32 = ticks < 0 ? -3 : 3
    for _ in 0..<abs(ticks) {
        if let e = CGEvent(scrollWheelEvent2Source: src, units: .line,
                           wheelCount: 1, wheel1: step, wheel2: 0, wheel3: 0) {
            e.location = CGPoint(x: x, y: y)
            e.post(tap: .cghidEventTap)
        }
        usleep(30_000)
    }
    print("scrolled \(ticks) at (\(x),\(y))")

case "click":
    guard a.count >= 4, let x = Double(a[2]), let y = Double(a[3]) else { usage() }
    let p = CGPoint(x: x, y: y)
    post(.mouseMoved, p)
    usleep(100_000)
    post(.leftMouseDown, p)
    usleep(80_000)
    post(.leftMouseUp, p)
    usleep(150_000)
    print("clicked (\(x),\(y))")

default:
    usage()
}
