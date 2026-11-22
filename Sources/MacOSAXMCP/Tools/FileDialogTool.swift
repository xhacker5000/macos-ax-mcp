import AppKit
import ApplicationServices

// MARK: - Dialog discovery helpers (shared with WindowsTool / SnapshotTool)

enum DialogFinder {
    enum Kind: String { case sheet, dialogWindow = "dialog_window" }

    struct Found {
        let element: AXUIElement
        let window: AXUIElement?
        let kind: Kind
    }

    static let confirmTitles: Set<String> = ["open", "打开", "upload", "上传", "choose", "选择"]
    static let fileListRoles: Set<String> = ["AXOutline", "AXBrowser", "AXSplitGroup"]
    static let textInputRoles: Set<String> = ["AXTextField", "AXComboBox", "AXTextArea"]
    /// Never descend here while hunting for the Go-to-Folder field (file rows contain text fields).
    static let listRoles: Set<String> = ["AXWebArea", "AXOutline", "AXBrowser", "AXTable", "AXList", "AXRow", "AXCell", "AXColumn"]

    static func matchesConfirmTitle(_ title: String?) -> Bool {
        guard var t = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !t.isEmpty else { return false }
        for suffix in ["…", "..."] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces) }
        return confirmTitles.contains(t)
    }

    /// Priority A: AXSheet attached to a window. Priority B: dialog-like top-level window.
    static func findFileDialog(in app: AXUIElement) -> Found? {
        let windows = AX.elements(app, "AXWindows")
        for w in windows {
            for c in AX.children(w, limit: 64) where AX.role(c) == "AXSheet" {
                return Found(element: c, window: w, kind: .sheet)
            }
        }
        for w in windows where isFileDialogWindow(w) {
            return Found(element: w, window: w, kind: .dialogWindow)
        }
        return nil
    }

    static func isFileDialogWindow(_ w: AXUIElement) -> Bool {
        let ident = (AX.string(w, "AXIdentifier") ?? "").lowercased()
        if ["open-panel", "nsopenpanel", "save-panel", "nssavepanel"].contains(where: { ident.contains($0) }) { return true }
        let sub = AX.subrole(w) ?? ""
        let hasDefault = AX.element(w, "AXDefaultButton") != nil
        let isDialogSubrole = sub == "AXDialog" || sub == "AXSystemDialog"
        // Cheap reject: ordinary document/browser windows without a default button are never scanned.
        if !isDialogSubrole && !hasDefault { return false }
        let hasFileList = AXTree.first(w, maxDepth: 6, budget: 250) { _, r in fileListRoles.contains(r) } != nil
        return hasFileList && (isDialogSubrole || hasDefault)
    }

    /// Any sheet or dialog window (for os_ax_snapshot scope=dialog).
    static func findAnyDialog(in app: AXUIElement) -> AXUIElement? {
        if let f = findFileDialog(in: app) { return f.element }
        return AX.elements(app, "AXWindows").first {
            let s = AX.subrole($0) ?? ""
            return s == "AXDialog" || s == "AXSystemDialog" || s == "AXFloatingWindow"
        }
    }

    static func isPresent(_ dialog: AXUIElement, in app: AXUIElement) -> Bool {
        guard AX.isAlive(dialog) else { return false }
        guard let current = findFileDialog(in: app) else { return false }
        return AX.same(current.element, dialog)
    }

    static func confirmButton(in dialog: AXUIElement) -> (AXUIElement, String)? {
        let cancel = AX.element(dialog, "AXCancelButton")
        if let b = AX.element(dialog, "AXDefaultButton"), cancel.map({ !AX.same($0, b) }) ?? true {
            return (b, "AXDefaultButton")
        }
        if let b = AXTree.first(dialog, maxDepth: 10, budget: 600, skipRoles: listRoles, where: { el, r in
            r == "AXButton" && matchesConfirmTitle(AX.title(el)) && !(cancel.map { AX.same($0, el) } ?? false)
        }) {
            return (b, "title_match")
        }
        return nil
    }

    static func isGoToCandidate(_ el: AXUIElement) -> Bool {
        guard let r = AX.role(el), textInputRoles.contains(r) else { return false }
        return AX.subrole(el) != "AXSearchField"
    }

    static func textInputs(in root: AXUIElement) -> [AXUIElement] {
        AXTree.all(root, maxDepth: 10, budget: 500, skipRoles: listRoles) { el, _ in isGoToCandidate(el) }
    }

    /// Locates the "Go to Folder" text field that appeared after Cmd+Shift+G.
    static func findGoToField(app: AXUIElement, dialog: AXUIElement,
                              baselineFields: [AXUIElement], baselineWindows: [AXUIElement],
                              preFocus: AXUIElement?) -> AXUIElement? {
        func isNew(_ el: AXUIElement) -> Bool { !AX.contains(baselineFields, el) }

        if let f = AX.element(app, "AXFocusedUIElement"), isGoToCandidate(f), isNew(f),
           !(preFocus.map { AX.same($0, f) } ?? false) {
            if AX.isWithin(f, dialog) { return f }
            if let top = AX.topWindow(of: f), !AX.contains(baselineWindows, top) { return f }
        }
        if let t = textInputs(in: dialog).first(where: isNew) { return t }
        for w in AX.elements(app, "AXWindows") where !AX.contains(baselineWindows, w) {
            if let t = textInputs(in: w).first(where: isNew) { return t }
        }
        return nil
    }
}

// MARK: - Path validation

struct ValidatedFile: Equatable {
    let path: String
    let sizeBytes: Int
    let isDirectory: Bool
}

enum FileValidation {
    static func validate(_ raw: String) throws -> ValidatedFile {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw ToolError(code: ErrorCode.invalidPath, detail: "file_path must be absolute (or start with ~): '\(raw)'")
        }
        guard !expanded.contains("\n"), !expanded.contains("\r") else {
            throw ToolError(code: ErrorCode.invalidPath, detail: "file_path must not contain newline characters")
        }
        let resolved = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else {
            throw ToolError(code: ErrorCode.fileNotFound, detail: "No such file: \(resolved)",
                            extra: ["resolved_path": .string(resolved)])
        }
        guard FileManager.default.isReadableFile(atPath: resolved) else {
            throw ToolError(code: ErrorCode.fileNotReadable, detail: "File is not readable by this process: \(resolved)",
                            extra: ["resolved_path": .string(resolved)])
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: resolved)[.size] as? NSNumber)?.intValue ?? 0
        return ValidatedFile(path: resolved, sizeBytes: isDir.boolValue ? 0 : size, isDirectory: isDir.boolValue)
    }
}

// MARK: - Trace

final class StepTrace {
    private let start = Date()
    private(set) var steps: [String] = []

    var elapsedMs: Int { Int(Date().timeIntervalSince(start) * 1000) }

    func add(_ s: String) {
        steps.append("[\(elapsedMs)ms] \(s)")
        Log.debug("trace: \(s)")
    }

    var json: JSONValue { .array(steps.map { .string($0) }) }
}

// MARK: - Tool

enum FileDialogTool {
    static let definition = ToolDefinition(
        name: "os_handle_file_dialog",
        description: "Complete an ALREADY OPEN native macOS file chooser (NSOpenPanel sheet/dialog, e.g. after clicking an "
            + "<input type=file> in Chrome) by navigating to an absolute file path via Go-to-Folder and pressing Open. "
            + "IME-safe (clipboard paste, never typed), works for multi-GB files, restores clipboard and focus.",
        inputSchema: Schema.object([
            "file_path": Schema.string("Absolute POSIX path of the file to select; '~' is expanded."),
            "app_name": Schema.string("App that owns the dialog (name or bundle ID).", defaultValue: "Google Chrome"),
            "timeout_ms": Schema.int("How long to wait for the dialog to appear.", defaultValue: 5000, min: 1000, max: 30000),
            "restore_focus": Schema.bool("Re-activate the previously frontmost app when done.", defaultValue: true),
        ], required: ["file_path"]),
        handler: { try run($0) }
    )

    struct Options {
        let rawPath: String
        let appName: String
        let timeoutMs: Int
        let restoreFocus: Bool
    }

    static func parse(_ args: Args) throws -> Options {
        Options(
            rawPath: try args.requiredString("file_path"),
            appName: try args.string("app_name") ?? "Google Chrome",
            timeoutMs: try args.int("timeout_ms", default: 5000, range: 1000...30000),
            restoreFocus: try args.bool("restore_focus", default: true)
        )
    }

    static func run(_ args: Args, trustCheck: () -> Bool = { AX.isTrusted() }) throws -> JSONValue {
        let opts = try parse(args)
        let trace = StepTrace()
        do {
            let result = try execute(opts, trace: trace, trustCheck: trustCheck)
            var o = result
            o["ok"] = true
            o["elapsed_ms"] = .int(trace.elapsedMs)
            o["steps_trace"] = trace.json
            return .object(o)
        } catch var e as ToolError {
            trace.add("FAILED \(e.code): \(e.detail)")
            e.extra["elapsed_ms"] = .int(trace.elapsedMs)
            e.extra["steps_trace"] = trace.json
            throw e
        }
    }

    private static func execute(_ opts: Options, trace: StepTrace, trustCheck: () -> Bool) throws -> [String: JSONValue] {
        // 1. Pre-flight (no UI / focus / clipboard side effects).
        guard trustCheck() else { throw Remediation.untrustedError() }
        trace.add("preflight: accessibility trusted")
        let file = try FileValidation.validate(opts.rawPath)
        trace.add("preflight: file ok \(file.path) (\(file.sizeBytes) bytes\(file.isDirectory ? ", directory" : ""))")

        // 2. State snapshot, restored unconditionally.
        let focus = FocusGuard.capture()
        let clipboard = ClipboardGuard.capture()
        trace.add("snapshot: frontmost=\(focus.app?.localizedName ?? "nil"), clipboard items=\(clipboard.items.count)")
        defer {
            let restoredClip = clipboard.restore()
            trace.add("restore: clipboard \(restoredClip ? "restored" : "restore failed")")
            if opts.restoreFocus { trace.add("restore: \(focus.restore())") }
        }

        // 3. Locate + activate target app.
        guard let app = AppLocator.find(opts.appName) else {
            throw ToolError(code: ErrorCode.appNotRunning, detail: "No running app matches '\(opts.appName)'")
        }
        let pid = app.processIdentifier
        let appEl = AX.application(pid: pid)
        trace.add("app: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"), pid \(pid))")
        guard AppActivator.activate(app, timeoutMs: 800) else {
            throw ToolError(code: ErrorCode.activationFailed, detail: "\(app.localizedName ?? "app") did not become frontmost within 800ms")
        }
        trace.add("app: frontmost")

        // 4. Poll for the native Open panel.
        guard let found = Poll.until(timeoutMs: opts.timeoutMs, intervalMs: 50, { DialogFinder.findFileDialog(in: appEl) }) else {
            throw ToolError(code: ErrorCode.dialogNotFound,
                            detail: "No open file dialog in \(app.localizedName ?? "app") within \(opts.timeoutMs)ms. "
                                + "Open it first (e.g. click the page's upload button), then call this tool.")
        }
        let dialog = found.element
        trace.add("dialog: found \(found.kind.rawValue) \(AX.describe(dialog))")
        if let w = found.window {
            AX.perform(w, "AXRaise")
            AX.setAttribute(w, "AXMain", kCFBooleanTrue)
        }

        // 5. Go to Folder.
        let baselineFields = DialogFinder.textInputs(in: dialog)
        let baselineWindows = AX.elements(appEl, "AXWindows")
        let preFocus = AX.element(appEl, "AXFocusedUIElement")
        try ensureFrontmost(pid, trace: trace)
        guard InputHelper.cmdShiftG() else { throw postFailed() }
        trace.add("goto: sent Cmd+Shift+G")
        guard let field = Poll.until(timeoutMs: 1500, intervalMs: 50, {
            DialogFinder.findGoToField(app: appEl, dialog: dialog, baselineFields: baselineFields,
                                       baselineWindows: baselineWindows, preFocus: preFocus)
        }) else {
            throw ToolError(code: ErrorCode.gotoSheetNotFound, detail: "Go-to-Folder field did not appear within 1500ms after Cmd+Shift+G")
        }
        trace.add("goto: field found \(AX.describe(field))")

        // 6. IME-safe injection via pasteboard + hardware keycodes.
        ClipboardGuard.writeTransientString(file.path)
        try ensureFrontmost(pid, trace: trace)
        guard InputHelper.cmdA() else { throw postFailed() }
        Poll.sleep(ms: 30)
        guard InputHelper.cmdV() else { throw postFailed() }
        trace.add("inject: Cmd+A, Cmd+V")
        Poll.sleep(ms: 200)
        let fileName = (file.path as NSString).lastPathComponent
        let current = AX.string(field, "AXValue")
        if let current, current.contains(fileName) || current.contains(file.path) {
            trace.add("inject: verified field value")
        } else {
            trace.add("inject: field value \(current.map { "'\($0)'" } ?? "unreadable"), setting AXValue directly")
            let err = AX.setAttribute(field, "AXValue", file.path as CFString)
            trace.add("inject: AXValue set -> \(err.rawValue)")
            Poll.sleep(ms: 150)
        }

        try ensureFrontmost(pid, trace: trace)
        guard InputHelper.pressReturn() else { throw postFailed() }
        trace.add("goto: sent Return")
        func gotoClosed() -> Bool {
            !AX.isAlive(field) || DialogFinder.findGoToField(app: appEl, dialog: dialog, baselineFields: baselineFields,
                                                            baselineWindows: baselineWindows, preFocus: preFocus) == nil
        }
        var closed = Poll.untilTrue(timeoutMs: 500, intervalMs: 50, gotoClosed)
        if !closed {
            try ensureFrontmost(pid, trace: trace)
            InputHelper.pressReturn()
            trace.add("goto: still open after 500ms, sent Return again (autocomplete quirk)")
            closed = Poll.untilTrue(timeoutMs: 1000, intervalMs: 50, gotoClosed)
        }
        guard closed else {
            throw ToolError(code: ErrorCode.gotoSheetStuck, detail: "Go-to-Folder field still visible 1500ms after Return; path may be invalid for this panel")
        }
        trace.add("goto: closed, back in open panel")

        // 7. Confirm via AXPress.
        if !DialogFinder.isPresent(dialog, in: appEl) {
            trace.add("confirm: dialog already dismissed after Return")
        } else {
            guard DialogFinder.confirmButton(in: dialog) != nil else {
                throw ToolError(code: ErrorCode.confirmButtonNotFound, detail: "No default/Open button found in the dialog")
            }
            let enabled = Poll.until(timeoutMs: 1500, intervalMs: 50) { () -> (AXUIElement, String)? in
                guard let (b, how) = DialogFinder.confirmButton(in: dialog) else { return nil }
                return AX.bool(b, "AXEnabled") == true ? (b, how) : nil
            }
            guard let (button, how) = enabled else {
                throw ToolError(code: ErrorCode.confirmButtonDisabled,
                                detail: "Open button stayed disabled for 1500ms. The page's accept= filter may reject this file type, or the path did not resolve.")
            }
            let err = AX.perform(button, "AXPress")
            trace.add("confirm: AXPress on \(AX.describe(button)) via \(how) -> \(err.rawValue)")
        }

        // 8. Verify dismissal.
        var dismissed = Poll.untilTrue(timeoutMs: 2000, intervalMs: 50) { !DialogFinder.isPresent(dialog, in: appEl) }
        if !dismissed {
            trace.add("verify: dialog still open after 2000ms, sending Return")
            try ensureFrontmost(pid, trace: trace)
            InputHelper.pressReturn()
            dismissed = Poll.untilTrue(timeoutMs: 1000, intervalMs: 50) { !DialogFinder.isPresent(dialog, in: appEl) }
        }
        guard dismissed else {
            throw ToolError(code: ErrorCode.dialogStillOpen, detail: "File dialog refused to close after confirm + Return")
        }
        trace.add("verify: dialog dismissed")

        return [
            "selected_path": .string(file.path),
            "file_size_bytes": .int(file.sizeBytes),
            "is_directory": .bool(file.isDirectory),
            "app": AppLocator.appInfo(app),
            "dialog_kind": .string(found.kind.rawValue),
        ]
    }

    /// Never send keystrokes unless the target app is frontmost (prevents typing into the wrong app).
    private static func ensureFrontmost(_ pid: pid_t, trace: StepTrace) throws {
        if FocusGuard.currentFrontmostPid() == pid { return }
        if let app = NSRunningApplication(processIdentifier: pid), AppActivator.activate(app, timeoutMs: 500) {
            trace.add("focus: re-activated target app")
            return
        }
        throw ToolError(code: ErrorCode.focusLost, detail: "Target app lost focus; refusing to send keystrokes to another app")
    }

    private static func postFailed() -> ToolError {
        ToolError(code: ErrorCode.eventPostFailed, detail: "Could not create/post CGEvent (check Accessibility / Input Monitoring permission)")
    }
}
