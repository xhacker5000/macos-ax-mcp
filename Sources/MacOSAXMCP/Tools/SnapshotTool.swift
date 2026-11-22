import AppKit
import ApplicationServices

// MARK: - Element registry

struct RegisteredElement {
    let element: AXUIElement
    let pid: pid_t
    let role: String
    let inWebContent: Bool
    let inDialog: Bool
}

/// Ephemeral `el_N` -> AXUIElement map. Rebuilt on every snapshot so stale references never leak.
final class ElementRegistry {
    static let shared = ElementRegistry()
    private var map: [String: RegisteredElement] = [:]
    private var next = 1

    func reset() {
        map.removeAll(keepingCapacity: true)
        next = 1
    }

    func add(_ e: RegisteredElement) -> String {
        let id = "el_\(next)"
        next += 1
        map[id] = e
        return id
    }

    func get(_ id: String) -> RegisteredElement? { map[id] }
    var count: Int { map.count }
}

// MARK: - Source-agnostic pruning builder (unit-testable with mock trees)

struct NodeInfo {
    var role: String
    var subrole: String?
    var title: String?
    var description: String?
    var value: String?
    var enabled: Bool?
    var focused: Bool?
    var frame: CGRect?
    var actions: [String] = []
}

struct NodeContext {
    var inWebContent = false
    var inDialog = false

    func including(_ info: NodeInfo) -> NodeContext {
        var c = self
        if info.role == "AXWebArea" { c.inWebContent = true }
        if info.role == "AXSheet" || info.subrole == "AXDialog" || info.subrole == "AXSystemDialog" { c.inDialog = true }
        return c
    }
}

protocol SnapshotSource {
    associatedtype Node
    func info(_ node: Node) -> NodeInfo
    func children(_ node: Node, limit: Int) -> [Node]
    func childCount(_ node: Node) -> Int
}

struct SnapshotBuilder<Source: SnapshotSource> {
    static var wrapperRoles: Set<String> { ["AXGroup", "AXScrollArea", "AXSplitGroup"] }
    /// Actions that make a wrapper "interactive" (AXShowMenu/AXScrollToVisible are ubiquitous noise).
    static var interactiveActions: Set<String> { ["AXPress", "AXConfirm", "AXPick", "AXIncrement", "AXDecrement", "AXOpen"] }
    static var reportedActions: Set<String> { ["AXPress", "AXConfirm", "AXShowMenu", "AXPick", "AXIncrement", "AXDecrement", "AXCancel", "AXOpen", "AXRaise"] }
    static var valueLimit: Int { 120 }

    let source: Source
    let maxDepth: Int
    let maxNodes: Int
    var skipWebContent: Bool = false
    var register: (Source.Node, NodeInfo, NodeContext) -> String

    private(set) var nodeCount = 0
    private(set) var truncated = false
    private(set) var depthLimited = false

    init(source: Source, maxDepth: Int, maxNodes: Int, skipWebContent: Bool = false,
         register: @escaping (Source.Node, NodeInfo, NodeContext) -> String) {
        self.source = source
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.skipWebContent = skipWebContent
        self.register = register
    }

    static func isPrunableWrapper(_ i: NodeInfo) -> Bool {
        guard wrapperRoles.contains(i.role) else { return false }
        let empty: (String?) -> Bool = { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return empty(i.title) && empty(i.description) && empty(i.value)
            && !i.actions.contains(where: { interactiveActions.contains($0) })
    }

    mutating func build(roots: [Source.Node]) -> [JSONValue] {
        var out: [JSONValue] = []
        for r in roots {
            if nodeCount >= maxNodes { truncated = true; break }
            out += visit(r, depth: 0, context: NodeContext())
        }
        return out
    }

    private mutating func visit(_ node: Source.Node, depth: Int, context: NodeContext) -> [JSONValue] {
        if nodeCount >= maxNodes { truncated = true; return [] }
        let info = source.info(node)
        let ctx = context.including(info)
        let prunable = Self.isPrunableWrapper(info)

        var id: String?
        if !prunable {
            nodeCount += 1
            id = register(node, info, ctx)
        }

        let stopHere = skipWebContent && info.role == "AXWebArea"
        var kids: [JSONValue] = []
        if !stopHere {
            if depth < maxDepth {
                for c in source.children(node, limit: maxNodes) {
                    if nodeCount >= maxNodes { truncated = true; break }
                    kids += visit(c, depth: depth + 1, context: ctx)
                }
            } else if source.childCount(node) > 0 {
                depthLimited = true
            }
        }

        if prunable { return kids }

        var o: [String: JSONValue] = ["id": .string(id ?? ""), "role": .string(info.role)]
        func put(_ k: String, _ v: String?) {
            if let v, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { o[k] = .string(v) }
        }
        put("subrole", info.subrole)
        put("title", info.title)
        put("description", info.description)
        if let v = info.value, !v.isEmpty {
            o["value"] = .string(v.count > Self.valueLimit ? String(v.prefix(Self.valueLimit)) + "…" : v)
        }
        if info.enabled == false { o["enabled"] = false }
        if info.focused == true { o["focused"] = true }
        if let f = info.frame {
            o["frame"] = [.int(Int(f.origin.x.rounded())), .int(Int(f.origin.y.rounded())),
                          .int(Int(f.size.width.rounded())), .int(Int(f.size.height.rounded()))]
        }
        let acts = info.actions.filter { Self.reportedActions.contains($0) }
        if !acts.isEmpty { o["actions"] = .array(acts.map { .string($0) }) }
        if stopHere { o["web_content_skipped"] = true }
        if !kids.isEmpty { o["children"] = .array(kids) }
        return [.object(o)]
    }
}

struct AXSnapshotSource: SnapshotSource {
    func info(_ el: AXUIElement) -> NodeInfo {
        NodeInfo(
            role: AX.role(el) ?? "AXUnknown",
            subrole: AX.subrole(el),
            title: AX.title(el),
            description: AX.string(el, "AXDescription"),
            value: AX.displayValue(el),
            enabled: AX.bool(el, "AXEnabled"),
            focused: AX.bool(el, "AXFocused"),
            frame: AX.frame(el),
            actions: AX.actions(el)
        )
    }

    func children(_ el: AXUIElement, limit: Int) -> [AXUIElement] { AX.children(el, limit: limit) }
    func childCount(_ el: AXUIElement) -> Int { AX.count(el, "AXChildren") }
}

// MARK: - Tool

enum SnapshotTool {
    static let definition = ToolDefinition(
        name: "os_ax_snapshot",
        description: "Compact, pruned Accessibility tree of an app's dialog / front window / all windows. Returns ephemeral "
            + "element ids (el_N) for os_ax_interact; ids are invalidated by the next snapshot. Browser web content is "
            + "skipped by default (use the browser extension for DOM).",
        inputSchema: Schema.object([
            "app_name": Schema.string("App name or bundle ID."),
            "scope": Schema.string("Which part of the app to capture.", enumValues: ["dialog", "front_window", "all_windows"], defaultValue: "front_window"),
            "max_depth": Schema.int("Maximum AX traversal depth.", defaultValue: 6, min: 1, max: 12),
            "max_nodes": Schema.int("Maximum retained nodes.", defaultValue: 150, min: 1, max: 400),
            "include_web_content": Schema.bool("Descend into AXWebArea of browsers (expensive).", defaultValue: false),
        ], required: ["app_name"]),
        handler: run
    )

    static func run(_ args: Args) throws -> JSONValue {
        let appName = try args.requiredString("app_name")
        let scope = try args.enumeration("scope", allowed: ["dialog", "front_window", "all_windows"], default: "front_window")
        let maxDepth = try args.int("max_depth", default: 6, range: 1...12)
        let maxNodes = try args.int("max_nodes", default: 150, range: 1...400)
        let includeWeb = try args.bool("include_web_content", default: false)

        guard AX.isTrusted() else { throw Remediation.untrustedError() }
        guard let app = AppLocator.find(appName) else {
            throw ToolError(code: ErrorCode.appNotRunning, detail: "No running app matches '\(appName)'")
        }
        let pid = app.processIdentifier
        let appEl = AX.application(pid: pid)

        let roots: [AXUIElement]
        switch scope {
        case "dialog":
            guard let d = DialogFinder.findAnyDialog(in: appEl) else {
                throw ToolError(code: ErrorCode.dialogNotFound, detail: "\(app.localizedName ?? appName) has no open sheet or dialog")
            }
            roots = [d]
        case "all_windows":
            roots = AX.elements(appEl, "AXWindows")
        default:
            let w = AX.element(appEl, "AXFocusedWindow") ?? AX.element(appEl, "AXMainWindow") ?? AX.elements(appEl, "AXWindows").first
            roots = w.map { [$0] } ?? []
        }
        guard !roots.isEmpty else {
            throw ToolError(code: ErrorCode.noWindows, detail: "\(app.localizedName ?? appName) has no accessible windows")
        }

        let registry = ElementRegistry.shared
        registry.reset()
        var builder = SnapshotBuilder(source: AXSnapshotSource(), maxDepth: maxDepth, maxNodes: maxNodes,
                                      skipWebContent: !includeWeb) { el, info, ctx in
            registry.add(RegisteredElement(element: el, pid: pid, role: info.role,
                                           inWebContent: ctx.inWebContent, inDialog: ctx.inDialog))
        }
        let tree = builder.build(roots: roots)
        return [
            "ok": true,
            "app_name": .string(app.localizedName ?? appName),
            "bundle_id": .string(app.bundleIdentifier ?? ""),
            "scope": .string(scope),
            "node_count": .int(builder.nodeCount),
            "truncated": .bool(builder.truncated),
            "depth_limited": .bool(builder.depthLimited),
            "tree": .array(tree),
        ]
    }
}
