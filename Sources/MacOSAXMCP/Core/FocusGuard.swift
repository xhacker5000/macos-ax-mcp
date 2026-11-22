import AppKit

/// Records the frontmost app + cursor position and restores them.
final class FocusGuard {
    let app: NSRunningApplication?
    let cursor: CGPoint?
    private(set) var restored = false

    private init(app: NSRunningApplication?, cursor: CGPoint?) {
        self.app = app
        self.cursor = cursor
    }

    static func capture() -> FocusGuard {
        FocusGuard(app: currentFrontmostApp(), cursor: InputHelper.cursorLocation())
    }

    /// AX focused application is live; NSWorkspace can be stale in a CLI process without a running run loop.
    static func currentFrontmostPid() -> pid_t? {
        if AX.isTrusted(), let pid = AX.focusedApplicationPid() { return pid }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    static func currentFrontmostApp() -> NSRunningApplication? {
        if let pid = currentFrontmostPid(), let app = NSRunningApplication(processIdentifier: pid) { return app }
        return NSWorkspace.shared.frontmostApplication
    }

    /// Returns a short description of what happened, for traces.
    @discardableResult
    func restore() -> String {
        guard !restored else { return "already restored" }
        restored = true
        var notes: [String] = []
        if let cursor, let now = InputHelper.cursorLocation(), hypot(now.x - cursor.x, now.y - cursor.y) > 1 {
            InputHelper.warpCursor(to: cursor)
            notes.append("cursor restored")
        }
        guard let app, !app.isTerminated else {
            notes.append("no previous app to restore")
            return notes.joined(separator: ", ")
        }
        if FocusGuard.currentFrontmostPid() == app.processIdentifier {
            notes.append("focus already on \(app.localizedName ?? "?")")
        } else {
            let ok = AppActivator.activate(app, timeoutMs: 800)
            notes.append("focus \(ok ? "restored" : "restore attempted") to \(app.localizedName ?? "?")")
        }
        return notes.joined(separator: ", ")
    }
}

enum AppActivator {
    /// Brings an app to the front via AXFrontmost (reliable for background processes) plus NSRunningApplication.activate.
    static func activate(_ app: NSRunningApplication, timeoutMs: Int = 800) -> Bool {
        let pid = app.processIdentifier
        if FocusGuard.currentFrontmostPid() == pid { return true }
        let el = AX.application(pid: pid)
        AX.setAttribute(el, "AXFrontmost", kCFBooleanTrue)
        _ = app.activate()
        return Poll.untilTrue(timeoutMs: timeoutMs, intervalMs: 50) { FocusGuard.currentFrontmostPid() == pid }
    }
}
