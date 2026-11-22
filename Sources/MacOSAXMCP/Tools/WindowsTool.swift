import AppKit
import ApplicationServices

enum WindowsTool {
    static let definition = ToolDefinition(
        name: "os_list_windows",
        description: "List running regular apps (optionally filtered) with their AX windows, and whether a sheet or "
            + "native file dialog (NSOpenPanel/NSSavePanel) is currently open.",
        inputSchema: Schema.object([
            "app_name": Schema.string("Case-insensitive app name substring or bundle ID (e.g. 'Chrome', 'com.google.Chrome')."),
        ]),
        handler: run
    )

    static func run(_ args: Args) throws -> JSONValue {
        let filter = try args.string("app_name")
        guard AX.isTrusted() else { throw Remediation.untrustedError() }

        let apps = filter.map { AppLocator.matching($0) } ?? AppLocator.regularApps()
        let frontPid = FocusGuard.currentFrontmostPid()

        let items: [JSONValue] = apps.map { app in
            let pid = app.processIdentifier
            let appEl = AX.application(pid: pid)
            let windows = AX.elements(appEl, "AXWindows")
            let dialog = DialogFinder.findFileDialog(in: appEl)
            let windowItems: [JSONValue] = windows.map { w in
                let hasSheet = AX.children(w, limit: 64).contains { AX.role($0) == "AXSheet" }
                var o: [String: JSONValue] = [
                    "title": .string(AX.title(w) ?? ""),
                    "role": .string(AX.role(w) ?? ""),
                    "subrole": .string(AX.subrole(w) ?? ""),
                    "has_active_sheet": .bool(hasSheet),
                ]
                if let dialog, dialog.kind == .dialogWindow, AX.same(dialog.element, w) { o["is_file_dialog"] = true }
                return .object(o)
            }
            var o: [String: JSONValue] = [
                "name": .string(app.localizedName ?? ""),
                "bundle_id": .string(app.bundleIdentifier ?? ""),
                "pid": .int(Int(pid)),
                "is_frontmost": .bool(pid == frontPid),
                "windows": .array(windowItems),
            ]
            if let dialog { o["file_dialog"] = ["kind": .string(dialog.kind.rawValue)] }
            return .object(o)
        }
        return ["ok": true, "apps": .array(items)]
    }
}
