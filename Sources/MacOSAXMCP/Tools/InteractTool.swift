import AppKit
import ApplicationServices

enum InteractTool {
    /// Browsers whose AXPress on web content is unreliable.
    static let pressBlocklist: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac",
    ]

    static let definition = ToolDefinition(
        name: "os_ax_interact",
        description: "Act on an element id from the latest os_ax_snapshot: press, set_value, focus or click_center. "
            + "Uses a 3-tier fallback (AXPress -> AXClick -> CGEvent click; AXValue -> clipboard paste).",
        inputSchema: Schema.object([
            "element_id": Schema.string("Element id (el_N) from the latest os_ax_snapshot."),
            "action": Schema.string("Action to perform.", enumValues: ["press", "set_value", "focus", "click_center"]),
            "value": Schema.string("Text for action=set_value."),
            "restore_focus": Schema.bool("Re-activate the previously frontmost app afterwards.", defaultValue: false),
        ], required: ["element_id", "action"]),
        handler: run
    )

    static func run(_ args: Args) throws -> JSONValue {
        let start = Date()
        let elementID = try args.requiredString("element_id")
        let action = try args.requiredString("action")
        guard ["press", "set_value", "focus", "click_center"].contains(action) else {
            throw ToolError.invalid("'action' must be one of press, set_value, focus, click_center, got '\(action)'")
        }
        let value = try args.string("value")
        let restoreFocus = try args.bool("restore_focus", default: false)
        if action == "set_value" && value == nil { throw ToolError.invalid("'value' is required when action == 'set_value'") }

        guard AX.isTrusted() else { throw Remediation.untrustedError() }
        guard let entry = ElementRegistry.shared.get(elementID) else {
            throw ToolError(code: ErrorCode.elementNotFound, detail: "Unknown element_id '\(elementID)'. Take a fresh os_ax_snapshot first.")
        }
        guard AX.isAlive(entry.element) else {
            throw ToolError(code: ErrorCode.elementStale, detail: "Element '\(elementID)' no longer exists. Take a fresh os_ax_snapshot.")
        }

        let pid = AX.pid(entry.element) ?? entry.pid
        let app = NSRunningApplication(processIdentifier: pid)
        let isBlocklisted = app?.bundleIdentifier.map { pressBlocklist.contains($0) } ?? false

        let focus = restoreFocus ? FocusGuard.capture() : nil
        defer { focus?.restore() }

        let strategy: String
        switch action {
        case "press":
            if isBlocklisted && entry.inWebContent && !entry.inDialog {
                strategy = try clickCenter(entry.element, app: app, label: "cgevent_click(browser_web_content)")
            } else {
                strategy = try press(entry.element, app: app)
            }
        case "set_value":
            strategy = try setValue(entry.element, value ?? "", app: app)
        case "focus":
            if AX.setAttribute(entry.element, "AXFocused", kCFBooleanTrue) == .success, AX.bool(entry.element, "AXFocused") != false {
                strategy = "ax_focused"
            } else {
                strategy = try clickCenter(entry.element, app: app, label: "cgevent_click")
            }
        default: // click_center
            strategy = try clickCenter(entry.element, app: app, label: "cgevent_click")
        }

        return [
            "ok": true,
            "element_id": .string(elementID),
            "action": .string(action),
            "strategy_used": .string(strategy),
            "elapsed_ms": .int(Int(Date().timeIntervalSince(start) * 1000)),
        ]
    }

    private static func press(_ el: AXUIElement, app: NSRunningApplication?) throws -> String {
        let actions = AX.actions(el)
        if actions.contains("AXPress"), AX.perform(el, "AXPress") == .success { return "ax_press" }
        if AX.perform(el, "AXClick") == .success { return "ax_click" }
        return try clickCenter(el, app: app, label: "cgevent_click")
    }

    private static func center(_ el: AXUIElement) throws -> CGPoint {
        guard let f = AX.frame(el), f.width > 0, f.height > 0 else {
            throw ToolError(code: ErrorCode.actionFailed, detail: "Element has no on-screen frame (AXPosition/AXSize)")
        }
        // Visually-hidden elements (e.g. an off-screen <input type=file> behind a styled <label>) get clipped
        // to a 1px frame; clicking there hits whatever is underneath.
        guard f.width >= 4, f.height >= 4 else {
            throw ToolError(code: ErrorCode.elementNotVisible,
                            detail: "Element frame \(Int(f.width))x\(Int(f.height)) is too small to click safely; it is probably visually hidden. Click its visible label instead, or use browser_upload_file for file inputs.")
        }
        return CGPoint(x: f.origin.x + f.width / 2, y: f.origin.y + f.height / 2)
    }

    private static func activate(_ app: NSRunningApplication?) throws {
        guard let app else { return }
        guard AppActivator.activate(app, timeoutMs: 800) else {
            throw ToolError(code: ErrorCode.activationFailed, detail: "\(app.localizedName ?? "app") did not become frontmost")
        }
    }

    private static func clickCenter(_ el: AXUIElement, app: NSRunningApplication?, label: String) throws -> String {
        let p = try center(el)
        try activate(app)
        guard InputHelper.click(at: p, restoreCursor: true) else {
            throw ToolError(code: ErrorCode.eventPostFailed, detail: "Could not post mouse events")
        }
        return label
    }

    private static func setValue(_ el: AXUIElement, _ value: String, app: NSRunningApplication?) throws -> String {
        if AX.setAttribute(el, "AXValue", value as CFString) == .success {
            Poll.sleep(ms: 50)
            if AX.string(el, "AXValue") == value { return "ax_set_value" }
        }
        // Fallback: focus + clipboard paste (IME-safe), clipboard restored afterwards.
        try activate(app)
        if AX.setAttribute(el, "AXFocused", kCFBooleanTrue) != .success {
            let p = try center(el)
            InputHelper.click(at: p, restoreCursor: true)
        }
        Poll.sleep(ms: 80)
        if let pid = app?.processIdentifier, FocusGuard.currentFrontmostPid() != pid {
            throw ToolError(code: ErrorCode.focusLost, detail: "Target app lost focus; refusing to paste into another app")
        }
        let clip = ClipboardGuard.capture()
        defer { clip.restore() }
        ClipboardGuard.writeTransientString(value)
        InputHelper.cmdA()
        Poll.sleep(ms: 30)
        InputHelper.cmdV()
        Poll.sleep(ms: 250) // let the target app read the pasteboard before restore
        let readBack = AX.string(el, "AXValue")
        return readBack == value ? "clipboard_paste" : "clipboard_paste(unverified)"
    }
}
