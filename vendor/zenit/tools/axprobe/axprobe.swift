// axprobe: read what a zenit app exposes to assistive tech from **outside the process**
// via AXUIElement.
//
// Why: zenit a11y unit tests live at the Zig layer (AccessibilityTree / bridge export) and never
// stand where VoiceOver sits. This tool uses the same cross-process AX channel as VoiceOver /
// Voice Control / Accessibility Inspector, so its output is the source of truth; Zig-layer
// assertions can't prove ObjC mapping, coordinate flip, notification, or main-thread latency.
//
// Needs a terminal process holding Accessibility permission.
//
// Usage:
//   axprobe tree    <pid> [--json] [--depth N] [--all]   print AX tree (default content only, --all
//   with menu/window buttons)
//   axprobe snapshot <pid>                               semantic snapshot (no coords), golden
//   compare
//   axprobe latency <pid> [--n N] [--attr A] [--query Q]  AX round-trip latency distribution
//   (p50/p95/max)
//   axprobe find    <pid> <query>                         find element, print all attributes; query
//   below
//   axprobe text    <pid> <query>                         text protocol probe (parameterized attr
//   per call)
//   axprobe do      <pid> <query> <AXAction|focus|value=STR>  execute action/set focus/set value on
//   element
//   axprobe watch   <pid> <seconds> [query=action ...]    listen to AX notifications; execute
//   actions after start
//   axprobe scrollstep <pid> [query]                      on table viewport bottom row cell, set
//   AXScrollToVisible (what VoiceOver
//                                                         does per step), immediately read back
//                                                         visible row range: should be exactly one
//                                                         row down
//
// query syntax: `Role`, `Role[name]`, `[name]`, name matches AXTitle / AXDescription /
//   AXValue / AXIdentifier (exact); `#identifier` AXIdentifier only. Role can drop AX prefix.

import ApplicationServices
import Foundation

// MARK: - AX helpers

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}

func attrNames(_ e: AXUIElement) -> [String] {
    var n: CFArray?
    AXUIElementCopyAttributeNames(e, &n)
    return (n as? [String]) ?? []
}

func paramAttrNames(_ e: AXUIElement) -> [String] {
    var n: CFArray?
    AXUIElementCopyParameterizedAttributeNames(e, &n)
    return (n as? [String]) ?? []
}

func actionNames(_ e: AXUIElement) -> [String] {
    var n: CFArray?
    AXUIElementCopyActionNames(e, &n)
    return (n as? [String]) ?? []
}

/// Children for traversal. Tables / outlines expand visible rows only: their AXChildren
/// is all data rows (NSTableView and zenit semantic set both do this; 100k rows full traverse
/// takes tens of seconds), total separate via AXRowCount. Matches Accessibility Inspector approach.
func children(_ e: AXUIElement) -> [AXUIElement] {
    if let role = attr(e, "AXRole") as? String, role == "AXTable" || role == "AXOutline",
       let visible = attr(e, "AXVisibleRows") as? [AXUIElement] {
        return visible
    }
    return (attr(e, "AXChildren") as? [AXUIElement]) ?? []
}

func str(_ e: AXUIElement, _ a: String) -> String? {
    guard let v = attr(e, a) else { return nil }
    if let s = v as? String { return s }
    return nil
}

func render(_ o: AnyObject?) -> Any? {
    guard let o = o else { return nil }
    if CFGetTypeID(o) == AXValueGetTypeID() {
        let v = o as! AXValue
        switch AXValueGetType(v) {
        case .cgPoint:
            var p = CGPoint.zero; AXValueGetValue(v, .cgPoint, &p)
            return ["x": Double(p.x), "y": Double(p.y)]
        case .cgSize:
            var s = CGSize.zero; AXValueGetValue(v, .cgSize, &s)
            return ["w": Double(s.width), "h": Double(s.height)]
        case .cgRect:
            var r = CGRect.zero; AXValueGetValue(v, .cgRect, &r)
            return ["x": Double(r.origin.x), "y": Double(r.origin.y), "w": Double(r.width), "h": Double(r.height)]
        case .cfRange:
            var r = CFRange(); AXValueGetValue(v, .cfRange, &r)
            return ["loc": r.location, "len": r.length]
        default:
            return "<axvalue>"
        }
    }
    if CFGetTypeID(o) == AXUIElementGetTypeID() {
        let e = o as! AXUIElement
        return "<\(str(e, "AXRole") ?? "?") \(label(e))>"
    }
    if let a = o as? [AnyObject] { return a.map { render($0) ?? NSNull() } }
    if let n = o as? NSNumber { return n }
    if let s = o as? String { return s }
    if let s = o as? NSAttributedString { return "attr:" + s.string }
    return "\(o)"
}

func label(_ e: AXUIElement) -> String {
    for a in ["AXTitle", "AXDescription", "AXValue", "AXIdentifier"] {
        if let s = str(e, a), !s.isEmpty { return s }
    }
    return ""
}

func isChrome(_ e: AXUIElement) -> Bool {
    let role = str(e, "AXRole") ?? ""
    if role == "AXMenuBar" { return true }
    let sub = str(e, "AXSubrole") ?? ""
    return ["AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton"].contains(sub)
}

/// Content root: window-descended host group labeled 'Zenit content'; fallback window itself if not
/// found.
func contentRoots(_ app: AXUIElement) -> [AXUIElement] {
    var roots: [AXUIElement] = []
    for w in (attr(app, "AXWindows") as? [AXUIElement]) ?? [] {
        var found = false
        for k in children(w) where !isChrome(k) {
            roots.append(k); found = true
        }
        if !found { roots.append(w) }
    }
    return roots
}

// MARK: - query

struct Query {
    var role: String?
    var name: String?
    var identifierOnly = false

    init(_ raw: String) {
        if raw.hasPrefix("#") { name = String(raw.dropFirst()); identifierOnly = true; return }
        if let open = raw.firstIndex(of: "["), raw.hasSuffix("]") {
            let r = String(raw[..<open])
            role = r.isEmpty ? nil : r
            name = String(raw[raw.index(after: open)..<raw.index(before: raw.endIndex)])
        } else {
            role = raw
        }
        if let r = role, !r.hasPrefix("AX") { role = "AX" + r }
    }

    func matches(_ e: AXUIElement) -> Bool {
        if let r = role, str(e, "AXRole") != r { return false }
        if let n = name {
            let keys = identifierOnly ? ["AXIdentifier"] : ["AXTitle", "AXDescription", "AXValue", "AXIdentifier"]
            return keys.contains { str(e, $0) == n }
        }
        return true
    }
}

func findAll(_ roots: [AXUIElement], _ q: Query, limit: Int = Int.max) -> [AXUIElement] {
    var out: [AXUIElement] = []
    var stack = roots.reversed() as [AXUIElement]
    while let e = stack.popLast(), out.count < limit {
        if q.matches(e) { out.append(e) }
        for k in children(e).reversed() where !isChrome(k) { stack.append(k) }
    }
    return out
}

// MARK: - tree

let treeAttrs = ["AXRole", "AXSubrole", "AXRoleDescription", "AXTitle", "AXDescription", "AXValue",
                 "AXHelp", "AXPlaceholderValue", "AXIdentifier", "AXEnabled", "AXFocused", "AXSelected",
                 "AXExpanded", "AXRequired", "AXDisclosureLevel", "AXRowCount", "AXIndex", "AXPosition", "AXSize"]

func node(_ e: AXUIElement, depth: Int, maxDepth: Int) -> [String: Any] {
    var d: [String: Any] = [:]
    let names = Set(attrNames(e))
    for a in treeAttrs where names.contains(a) || a == "AXRole" {
        if let v = render(attr(e, a)) { d[a] = v }
    }
    if depth < maxDepth {
        let kids = children(e).filter { !isChrome($0) }
        if !kids.isEmpty { d["children"] = kids.map { node($0, depth: depth + 1, maxDepth: maxDepth) } }
    }
    return d
}

func printTree(_ e: AXUIElement, depth: Int, maxDepth: Int, all: Bool, count: inout Int) {
    count += 1
    let role = str(e, "AXRole") ?? "?"
    var line = String(repeating: "  ", count: depth) + role
    if let s = str(e, "AXSubrole") { line += "/" + s }
    for (key, a) in [("title", "AXTitle"), ("desc", "AXDescription"), ("help", "AXHelp"), ("ph", "AXPlaceholderValue"), ("id", "AXIdentifier")] {
        if let s = str(e, a), !s.isEmpty { line += " \(key)=\"\(s.prefix(60))\"" }
    }
    if let v = attr(e, "AXValue") {
        if let r = render(v) { line += " val=\(r is String ? "\"\(String(describing: r).prefix(60))\"" : "\(r)")" }
    }
    if let p = render(attr(e, "AXPosition")) as? [String: Double], let s = render(attr(e, "AXSize")) as? [String: Double] {
        line += " @\(Int(p["x"]!)),\(Int(p["y"]!)) \(Int(s["w"]!))x\(Int(s["h"]!))"
    }
    print(line)
    if depth >= maxDepth { return }
    for k in children(e) where all || !isChrome(k) {
        printTree(k, depth: depth + 1, maxDepth: maxDepth, all: all, count: &count)
    }
}

// MARK: - main

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, let pidValue = Int32(args[1]) else {
    die("usage: axprobe <tree|snapshot|latency|find|text|do|watch> <pid> ... (see header)")
}
guard AXIsProcessTrusted() else { die("axprobe: this process lacks Accessibility permission") }
let cmd = args[0]
let pid = pid_t(pidValue)
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 5.0)

let watchStart = Date()

func flag(_ name: String) -> Bool { args.contains(name) }
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func requireOne(_ raw: String) -> AXUIElement {
    let hits = findAll(contentRoots(app), Query(raw), limit: 2)
    if hits.isEmpty { die("no element matches \(raw)") }
    return hits[0]
}

switch cmd {
case "tree":
    let maxDepth = Int(option("--depth") ?? "64") ?? 64
    let all = flag("--all")
    let t0 = Date()
    if flag("--json") {
        let roots = all ? [app] : contentRoots(app)
        let obj = roots.map { node($0, depth: 0, maxDepth: maxDepth) }
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    } else {
        var count = 0
        for r in (all ? [app] : contentRoots(app)) { printTree(r, depth: 0, maxDepth: maxDepth, all: all, count: &count) }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("# elements=\(count) walk_ms=\(ms)")
    }

case "snapshot":
    // Semantic snapshot: role / subrole / name / value / key states only, no coords, golden
    // compare.
    func line(_ e: AXUIElement, _ depth: Int) {
        var out = String(repeating: "  ", count: depth) + (str(e, "AXRole") ?? "?")
        if let sub = str(e, "AXSubrole") { out += "/" + sub }
        let name = [str(e, "AXTitle"), str(e, "AXDescription")].compactMap { $0 }.first { !$0.isEmpty }
        if let n = name { out += " \"\(n)\"" }
        if let v = attr(e, "AXValue") {
            if let s = v as? String { if !s.isEmpty { out += " = \"\(s)\"" } } else if let n = v as? NSNumber { out += " = \(n)" }
        }
        if let enabled = attr(e, "AXEnabled") as? Bool, !enabled { out += " [disabled]" }
        if let focused = attr(e, "AXFocused") as? Bool, focused { out += " [focused]" }
        print(out)
        for k in children(e) where !isChrome(k) { line(k, depth + 1) }
    }
    for r in contentRoots(app) { line(r, 0) }

case "latency":
    // --attr specifies probed attribute (default AXChildren), --query specifies element (default
    // content root).
    let n = Int(option("--n") ?? "40") ?? 40
    let probeAttr = option("--attr") ?? "AXChildren"
    let probe = option("--query").map { requireOne($0) } ?? (contentRoots(app).first ?? app)
    var samples: [Double] = []
    var v: AnyObject?
    for _ in 0..<n {
        let s = DispatchTime.now().uptimeNanoseconds
        // AXChildren must come from zenit accessibilityChildren live answer (AXRole etc
        // constant attributes cached by AX client, can't measure real process latency).
        _ = AXUIElementCopyAttributeValue(probe, probeAttr as CFString, &v)
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - s) / 1e6)
    }
    samples.sort()
    func pct(_ p: Double) -> Double { samples[min(samples.count - 1, Int(Double(samples.count) * p))] }
    print(String(format: "\(probeAttr) n=%d p50=%.2fms p95=%.2fms max=%.2fms", n, pct(0.5), pct(0.95), samples.last!))

case "find":
    guard args.count >= 3 else { die("find <pid> <query>") }
    let e = requireOne(args[2])
    for a in attrNames(e).sorted() {
        let v = render(attr(e, a))
        print("\(a) = \(v.map { "\($0)" } ?? "nil")")
    }
    print("parameterized: \(paramAttrNames(e).sorted().joined(separator: ","))")
    print("actions: \(actionNames(e).joined(separator: ","))")

case "text":
    guard args.count >= 3 else { die("text <pid> <query>") }
    let e = requireOne(args[2])
    for a in ["AXValue", "AXNumberOfCharacters", "AXSelectedTextRange", "AXSelectedText", "AXVisibleCharacterRange", "AXInsertionPointLineNumber"] {
        print("\(a) = \(render(attr(e, a)).map { "\($0)" } ?? "nil")")
    }
    let total = (attr(e, "AXNumberOfCharacters") as? Int) ?? 0
    var whole = CFRange(location: 0, length: total)
    let wholeValue = AXValueCreate(.cfRange, &whole)!
    for pa in ["AXStringForRange", "AXBoundsForRange", "AXAttributedStringForRange", "AXRTFForRange"] {
        var out: AnyObject?
        let err = AXUIElementCopyParameterizedAttributeValue(e, pa as CFString, wholeValue, &out)
        print("\(pa)(0,\(total)) -> \(err == .success ? "\(render(out) ?? "nil")" : "error \(err.rawValue)")")
    }
    var line = 0
    while line < 64 {
        var out: AnyObject?
        let err = AXUIElementCopyParameterizedAttributeValue(e, "AXRangeForLine" as CFString, line as CFNumber, &out)
        if err != .success { break }
        print("AXRangeForLine(\(line)) -> \(render(out) ?? "nil")")
        line += 1
    }

case "scrollstep":
    // Native NSTableView behavior: VoiceOver reaches bottom-row cell, set writable attribute
    // AXScrollToVisible, list scrolls exactly one row, after set return read frame / visible rows
    // already new position.
    let table = requireOne(args.count >= 3 ? args[2] : "Table")
    func visibleIndices() -> [Int] {
        ((attr(table, "AXVisibleRows") as? [AXUIElement]) ?? []).compactMap { attr($0, "AXIndex") as? Int }
    }
    let before = visibleIndices()
    guard let last = before.last, let first = before.first else { die("表格没有可见行") }
    var segment: CFArray?
    guard AXUIElementCopyAttributeValues(table, "AXRows" as CFString, last + 1, 1, &segment) == .success,
          let next = (segment as? [AXUIElement])?.first,
          let cell = children(next).first else { die("取不到第 \(last + 1) 行的单元格") }
    var settable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(cell, "AXScrollToVisible" as CFString, &settable)
    let err = AXUIElementSetAttributeValue(cell, "AXScrollToVisible" as CFString, kCFBooleanTrue)
    let after = visibleIndices()
    print("settable=\(settable.boolValue) err=\(err.rawValue) before=\(first)...\(last) after=\((after.first ?? -1))...\((after.last ?? -1))")
    if settable.boolValue && err == .success && after.first == first + 1 && after.last == last + 1 {
        print("PASS: 恰好滚一行，读回立即一致")
    } else {
        print("FAIL: 期望 \(first + 1)...\(last + 1)")
        exit(1)
    }

case "do":
    guard args.count >= 4 else { die("do <pid> <query> <action>") }
    let e = requireOne(args[2])
    let action = args[3]
    let t0 = Date()
    let err: AXError
    if action == "focus" {
        err = AXUIElementSetAttributeValue(e, "AXFocused" as CFString, kCFBooleanTrue)
    } else if action.hasPrefix("value=") {
        err = AXUIElementSetAttributeValue(e, "AXValue" as CFString, String(action.dropFirst(6)) as CFString)
    } else {
        err = AXUIElementPerformAction(e, action as CFString)
    }
    print("\(action) -> \(err == .success ? "ok" : "error \(err.rawValue)") in \(Int(Date().timeIntervalSince(t0) * 1000))ms")

case "watch":
    guard args.count >= 3, let secs = Double(args[2]) else { die("watch <pid> <seconds> [query=action ...]") }
    var observer: AXObserver?
    AXObserverCreateWithInfoCallback(pid, { _, el, note, info, _ in
        let t = Int(Date().timeIntervalSince(watchStart) * 1000)
        let infoText = (info as NSDictionary?).map { d -> String in
            d.map { "\($0.key)=\(render($0.value as AnyObject) ?? "nil")" }.sorted().joined(separator: " ")
        } ?? ""
        print("[\(t)ms] \(note) <\(str(el, "AXRole") ?? "?") \(label(el))> \(infoText)")
        fflush(stdout)
    }, &observer)
    let notes = ["AXFocusedUIElementChanged", "AXValueChanged", "AXSelectedTextChanged", "AXLayoutChanged",
                 "AXUIElementDestroyed", "AXAnnouncementRequested", "AXCreated", "AXSelectedChildrenChanged",
                 "AXSelectedRowsChanged", "AXRowCountChanged", "AXTitleChanged", "AXElementBusyChanged",
                 "AXExpandedChanged", "AXRowExpanded", "AXRowCollapsed", "AXFocusedWindowChanged",
                 "AXMenuOpened", "AXMenuClosed", "AXLiveRegionChanged", "AXLiveRegionCreated", "AXMoved", "AXResized"]
    for n in notes { _ = AXObserverAddNotification(observer!, app, n as CFString, nil) }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer!), .defaultMode)
    let steps = Array(args.dropFirst(3))
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        for step in steps {
            guard let eq = step.lastIndex(of: "=") else { continue }
            let q = String(step[..<eq]); let action = String(step[step.index(after: eq)...])
            guard let e = findAll(contentRoots(app), Query(q), limit: 1).first else { print(">> \(q) not found"); continue }
            let err = action == "focus"
                ? AXUIElementSetAttributeValue(e, "AXFocused" as CFString, kCFBooleanTrue)
                : AXUIElementPerformAction(e, action as CFString)
            print(">> \(q) \(action) -> \(err == .success ? "ok" : "error \(err.rawValue)")")
            fflush(stdout)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(secs))

default:
    die("unknown command \(cmd)")
}
