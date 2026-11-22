import AppKit
import ApplicationServices
import Darwin

enum HealthTool {
    static let definition = ToolDefinition(
        name: "os_check_health",
        description: "Check macOS Accessibility (TCC) trust, macOS version, host process chain and the frontmost app. "
            + "Run this first when other tools return ERR_TCC_UNTRUSTED.",
        inputSchema: Schema.object([
            "prompt_permission": Schema.bool("Show the system Accessibility permission prompt if not yet trusted.", defaultValue: false),
        ]),
        handler: run
    )

    static func run(_ args: Args) throws -> JSONValue {
        let prompt = try args.bool("prompt_permission", default: false)
        let trusted = AX.isTrusted(prompt: prompt)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let chain = HostProcess.chain()
        let host = HostProcess.responsibleAppHint()

        var out: [String: JSONValue] = [
            "ok": true,
            "accessibility_trusted": .bool(trusted),
            "post_event_access": .bool(CGPreflightPostEventAccess()),
            "macos_version": .string("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
            "macos_version_string": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            "server_version": .string(ServerInfo.version),
            "executable_path": .string(HostProcess.executablePath()),
            "pid": .int(Int(getpid())),
            "host_process_chain": .array(chain.map {
                ["pid": .int(Int($0.pid)), "name": .string($0.name),
                 "bundle_id": $0.bundleID.map { .string($0) } ?? .null, "path": $0.path.map { .string($0) } ?? .null]
            }),
            "host_app_hint": host.map {
                ["name": .string($0.name), "bundle_id": .string($0.bundleID), "pid": .int(Int($0.pid)),
                 "path": $0.path.map { .string($0) } ?? .null]
            } ?? .null,
            "frontmost_app": AppLocator.appInfo(FocusGuard.currentFrontmostApp()),
        ]
        if !trusted { out["remediation"] = .string(Remediation.accessibility()) }
        return .object(out)
    }
}

/// Process ancestry, used to tell the user which host app needs the Accessibility grant.
enum HostProcess {
    struct Entry { let pid: pid_t; let name: String; let bundleID: String?; let path: String? }

    static func executablePath() -> String {
        let p = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
        return URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    }

    static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    static func path(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    static func chain(maxDepth: Int = 16) -> [Entry] {
        var out: [Entry] = []
        var pid: pid_t? = getpid()
        while let p = pid, p > 1, out.count < maxDepth {
            let app = NSRunningApplication(processIdentifier: p)
            let exe = path(of: p)
            let name = app?.localizedName ?? exe.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "pid \(p)"
            out.append(Entry(pid: p, name: name, bundleID: app?.bundleIdentifier, path: exe))
            pid = parentPid(of: p)
        }
        return out
    }

    /// The outermost bundled-app ancestor (what TCC usually attributes the request to). Falls back to the
    /// outermost ancestor process (e.g. a terminal multiplexer daemon re-parented to launchd).
    static func responsibleAppHint() -> (name: String, bundleID: String, pid: pid_t, path: String?)? {
        let ancestors = Array(chain().dropFirst())
        if let top = ancestors.last(where: { $0.bundleID != nil }), let id = top.bundleID {
            return (top.name, id, top.pid, top.path)
        }
        guard let top = ancestors.last else { return nil }
        return (top.name, "", top.pid, top.path)
    }
}
