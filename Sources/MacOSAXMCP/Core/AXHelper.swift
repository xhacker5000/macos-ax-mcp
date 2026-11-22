import AppKit
import ApplicationServices
import Foundation

/// Safe, timeout-guarded wrappers around the AXUIElement C API.
enum AX {
    static let messagingTimeout: Float = 2.0

    /// Attributes this tool must never write. AXEnhancedUserInterface on Chromium browsers causes
    /// severe renderer/window performance degradation, so it is banned for every app.
    static let forbiddenWriteAttributes: Set<String> = ["AXEnhancedUserInterface"]

    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta", "com.google.Chrome.dev",
        "org.chromium.Chromium", "com.apple.Safari", "company.thebrowser.Browser", "com.brave.Browser",
        "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    static let systemWide: AXUIElement = {
        let el = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(el, messagingTimeout)
        return el
    }()

    static func application(pid: pid_t) -> AXUIElement {
        _ = systemWide
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, messagingTimeout)
        return el
    }

    static func isTrusted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    // MARK: Reads

    static func raw(_ el: AXUIElement, _ attr: String) -> (AXError, CFTypeRef?) {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, attr as CFString, &v)
        return (err, v)
    }

    static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        let (err, v) = raw(el, attr)
        return err == .success ? v : nil
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        value(el, attr) as? String
    }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        (value(el, attr) as? NSNumber)?.boolValue
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(v, to: AXUIElement.self)
    }

    static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        guard let v = value(el, attr), CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        let array = unsafeBitCast(v, to: CFArray.self)
        var out: [AXUIElement] = []
        for i in 0..<CFArrayGetCount(array) {
            guard let ptr = CFArrayGetValueAtIndex(array, i) else { continue }
            let obj = Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
            if CFGetTypeID(obj) == AXUIElementGetTypeID() { out.append(unsafeBitCast(obj, to: AXUIElement.self)) }
        }
        return out
    }

    /// Fetches at most `limit` children (avoids materialising huge lists).
    static func children(_ el: AXUIElement, limit: Int) -> [AXUIElement] {
        var arr: CFArray?
        let err = AXUIElementCopyAttributeValues(el, "AXChildren" as CFString, 0, max(limit, 0), &arr)
        if err == .success, let arr {
            var out: [AXUIElement] = []
            for i in 0..<CFArrayGetCount(arr) {
                guard let ptr = CFArrayGetValueAtIndex(arr, i) else { continue }
                let obj = Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
                if CFGetTypeID(obj) == AXUIElementGetTypeID() { out.append(unsafeBitCast(obj, to: AXUIElement.self)) }
            }
            return out
        }
        return Array(elements(el, "AXChildren").prefix(limit))
    }

    static func count(_ el: AXUIElement, _ attr: String) -> Int {
        var c: CFIndex = 0
        return AXUIElementGetAttributeValueCount(el, attr as CFString, &c) == .success ? c : 0
    }

    static func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(unsafeBitCast(v, to: AXValue.self), .cgPoint, &p) ? p : nil
    }

    static func size(_ el: AXUIElement, _ attr: String) -> CGSize? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(unsafeBitCast(v, to: AXValue.self), .cgSize, &s) ? s : nil
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = point(el, "AXPosition"), let s = size(el, "AXSize") else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func role(_ el: AXUIElement) -> String? { string(el, "AXRole") }
    static func subrole(_ el: AXUIElement) -> String? { string(el, "AXSubrole") }
    static func title(_ el: AXUIElement) -> String? { string(el, "AXTitle") }

    /// Human-readable value for snapshots: strings, numbers and URLs only.
    static func displayValue(_ el: AXUIElement) -> String? {
        guard let v = value(el, "AXValue") else { return nil }
        if let s = v as? String { return s }
        if CFGetTypeID(v) == CFBooleanGetTypeID() { return (v as? NSNumber)?.boolValue == true ? "true" : "false" }
        if let n = v as? NSNumber { return n.stringValue }
        if let u = v as? URL { return u.absoluteString }
        return nil
    }

    static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let names else { return [] }
        return (names as? [String]) ?? []
    }

    static func pid(_ el: AXUIElement) -> pid_t? {
        var p: pid_t = 0
        return AXUIElementGetPid(el, &p) == .success ? p : nil
    }

    static func isAlive(_ el: AXUIElement) -> Bool {
        raw(el, "AXRole").0 == .success
    }

    static func focusedApplicationPid() -> pid_t? {
        guard let app = element(systemWide, "AXFocusedApplication") else { return nil }
        return pid(app)
    }

    static func same(_ a: AXUIElement, _ b: AXUIElement) -> Bool { CFEqual(a, b) }

    static func contains(_ list: [AXUIElement], _ el: AXUIElement) -> Bool {
        list.contains { CFEqual($0, el) }
    }

    /// True when `el` is `root` or one of its descendants (walks AXParent, bounded).
    static func isWithin(_ el: AXUIElement, _ root: AXUIElement, maxHops: Int = 40) -> Bool {
        var cur: AXUIElement? = el
        var hops = 0
        while let c = cur, hops < maxHops {
            if CFEqual(c, root) { return true }
            cur = element(c, "AXParent")
            hops += 1
        }
        return false
    }

    /// Topmost AXWindow/AXSheet ancestor (or nil).
    static func topWindow(of el: AXUIElement, maxHops: Int = 40) -> AXUIElement? {
        var cur: AXUIElement? = el
        var lastWindow: AXUIElement?
        var hops = 0
        while let c = cur, hops < maxHops {
            if role(c) == "AXWindow" { lastWindow = c }
            if role(c) == "AXApplication" { break }
            cur = element(c, "AXParent")
            hops += 1
        }
        return lastWindow
    }

    static func describe(_ el: AXUIElement) -> String {
        let r = role(el) ?? "?"
        let label = title(el) ?? string(el, "AXDescription") ?? ""
        return label.isEmpty ? r : "\(r) '\(label)'"
    }

    // MARK: Writes

    @discardableResult
    static func setAttribute(_ el: AXUIElement, _ attr: String, _ value: CFTypeRef) -> AXError {
        if forbiddenWriteAttributes.contains(attr) {
            Log.error("refused to write forbidden attribute \(attr)")
            return .attributeUnsupported
        }
        return AXUIElementSetAttributeValue(el, attr as CFString, value)
    }

    @discardableResult
    static func perform(_ el: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(el, action as CFString)
    }
}

// MARK: - Bounded tree search

enum AXTree {
    /// Breadth-first search. `visit` returns true to stop. Never descends into `skipRoles`.
    static func bfs(_ root: AXUIElement, maxDepth: Int, budget: Int,
                    skipRoles: Set<String> = ["AXWebArea"],
                    visit: (AXUIElement, String) -> Bool) {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var head = 0
        var seen = 0
        while head < queue.count, seen < budget {
            let (el, depth) = queue[head]
            head += 1
            seen += 1
            let r = AX.role(el) ?? ""
            if visit(el, r) { return }
            if depth >= maxDepth || skipRoles.contains(r) { continue }
            for c in AX.children(el, limit: 200) { queue.append((c, depth + 1)) }
        }
    }

    static func first(_ root: AXUIElement, maxDepth: Int = 8, budget: Int = 400,
                      skipRoles: Set<String> = ["AXWebArea"],
                      where predicate: (AXUIElement, String) -> Bool) -> AXUIElement? {
        var found: AXUIElement?
        bfs(root, maxDepth: maxDepth, budget: budget, skipRoles: skipRoles) { el, r in
            if predicate(el, r) { found = el; return true }
            return false
        }
        return found
    }

    static func all(_ root: AXUIElement, maxDepth: Int = 8, budget: Int = 400,
                    skipRoles: Set<String> = ["AXWebArea"],
                    where predicate: (AXUIElement, String) -> Bool) -> [AXUIElement] {
        var out: [AXUIElement] = []
        bfs(root, maxDepth: maxDepth, budget: budget, skipRoles: skipRoles) { el, r in
            if predicate(el, r) { out.append(el) }
            return false
        }
        return out
    }
}

// MARK: - Polling (run-loop friendly)

enum Poll {
    /// Spins the current run loop (so NSWorkspace/KVO updates arrive), falling back to sleep.
    static func pump(_ seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        _ = RunLoop.current.run(mode: .default, before: deadline)
        let remaining = deadline.timeIntervalSinceNow
        if remaining > 0 { usleep(useconds_t(remaining * 1_000_000)) }
    }

    static func sleep(ms: Int) { pump(Double(ms) / 1000) }

    /// Evaluates `body` immediately and then every `intervalMs` until non-nil or timeout.
    static func until<T>(timeoutMs: Int, intervalMs: Int = 50, _ body: () -> T?) -> T? {
        let deadline = Date(timeIntervalSinceNow: Double(timeoutMs) / 1000)
        while true {
            if let v = body() { return v }
            if Date() >= deadline { return nil }
            pump(Double(intervalMs) / 1000)
        }
    }

    static func untilTrue(timeoutMs: Int, intervalMs: Int = 50, _ body: () -> Bool) -> Bool {
        until(timeoutMs: timeoutMs, intervalMs: intervalMs) { body() ? true : nil } ?? false
    }
}

// MARK: - App lookup

enum AppLocator {
    static func regularApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
    }

    /// Case-insensitive exact name / bundle-ID match first, then substring.
    static func find(_ query: String) -> NSRunningApplication? {
        let matches = matching(query)
        return matches.first
    }

    static func matching(_ query: String) -> [NSRunningApplication] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let apps = regularApps()
        let exact = apps.filter {
            $0.bundleIdentifier?.lowercased() == q || $0.localizedName?.lowercased() == q
        }
        if !exact.isEmpty { return exact }
        return apps.filter {
            ($0.localizedName?.lowercased().contains(q) ?? false) || ($0.bundleIdentifier?.lowercased().contains(q) ?? false)
        }
    }

    static func appInfo(_ app: NSRunningApplication?) -> JSONValue {
        guard let app else { return .null }
        return [
            "name": .string(app.localizedName ?? ""),
            "bundle_id": .string(app.bundleIdentifier ?? ""),
            "pid": .int(Int(app.processIdentifier)),
        ]
    }

    static func isBrowser(pid: pid_t) -> Bool {
        guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return AX.browserBundleIDs.contains(id)
    }
}

enum Remediation {
    static func accessibility() -> String {
        let host = HostProcess.responsibleAppHint()
        let hostText: String
        if let host, !host.bundleID.isEmpty {
            hostText = "'\(host.name)' (\(host.bundleID))"
        } else if let host {
            hostText = "the host process '\(host.name)'\(host.path.map { " at \($0)" } ?? "") (use the '+' button and pick that executable, or the terminal app that started it)"
        } else {
            hostText = "the terminal / IDE / agent app that launches this server"
        }
        return "Grant Accessibility access: System Settings -> Privacy & Security -> Accessibility, then enable \(hostText). "
            + "macOS attributes the permission to the parent host process that spawns macos-ax-mcp (Terminal, iTerm2, "
            + "VS Code, Claude, Antigravity...), not to this binary itself. Fully quit and relaunch the host app after "
            + "granting. Run os_check_health with prompt_permission=true to trigger the system prompt."
    }

    static func untrustedError() -> ToolError {
        ToolError(code: ErrorCode.tccUntrusted, detail: "This process is not trusted for Accessibility (AXIsProcessTrusted == false).",
                  extra: ["remediation": .string(accessibility())])
    }
}
