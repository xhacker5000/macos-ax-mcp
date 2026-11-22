import CoreGraphics
import XCTest
@testable import MacOSAXMCP

final class MockNode {
    let info: NodeInfo
    var children: [MockNode]
    init(_ role: String, title: String? = nil, value: String? = nil, actions: [String] = [], subrole: String? = nil,
         enabled: Bool? = true, children: [MockNode] = []) {
        info = NodeInfo(role: role, subrole: subrole, title: title, description: nil, value: value, enabled: enabled,
                        focused: false, frame: CGRect(x: 1, y: 2, width: 30, height: 40), actions: actions)
        self.children = children
    }
}

struct MockSource: SnapshotSource {
    func info(_ n: MockNode) -> NodeInfo { n.info }
    func children(_ n: MockNode, limit: Int) -> [MockNode] { Array(n.children.prefix(limit)) }
    func childCount(_ n: MockNode) -> Int { n.children.count }
}

final class SnapshotPrunerTests: XCTestCase {
    private func build(_ roots: [MockNode], depth: Int = 6, nodes: Int = 150, skipWeb: Bool = false)
        -> (tree: [JSONValue], builder: SnapshotBuilder<MockSource>, registered: [String: (NodeInfo, NodeContext)]) {
        var registered: [String: (NodeInfo, NodeContext)] = [:]
        var n = 0
        var b = SnapshotBuilder(source: MockSource(), maxDepth: depth, maxNodes: nodes, skipWebContent: skipWeb) { _, info, ctx in
            n += 1
            registered["el_\(n)"] = (info, ctx)
            return "el_\(n)"
        }
        let tree = b.build(roots: roots)
        return (tree, b, registered)
    }

    func testStructuralWrappersAreHoisted() throws {
        let root = MockNode("AXWindow", title: "Main", children: [
            MockNode("AXGroup", children: [
                MockNode("AXScrollArea", children: [
                    MockNode("AXSplitGroup", children: [
                        MockNode("AXButton", title: "Open", actions: ["AXPress", "AXScrollToVisible"]),
                        MockNode("AXStaticText", value: "hello"),
                    ]),
                ]),
            ]),
            MockNode("AXGroup", title: "Named group", children: [MockNode("AXCheckBox", title: "x", actions: ["AXPress"])]),
            MockNode("AXGroup", actions: ["AXPress"]), // interactive wrapper is kept
            MockNode("AXGroup", actions: ["AXShowMenu"]), // ShowMenu alone is not "interactive": pruned (no kids -> gone)
        ])
        let (tree, b, _) = build([root])
        XCTAssertEqual(tree.count, 1)
        let kids = try XCTUnwrap(tree[0]["children"]?.arrayValue)
        XCTAssertEqual(kids.compactMap { $0["role"]?.stringValue }, ["AXButton", "AXStaticText", "AXGroup", "AXGroup"])
        XCTAssertEqual(kids[0]["title"]?.stringValue, "Open")
        XCTAssertEqual(kids[0]["actions"], .array(["AXPress"]), "noise actions filtered out")
        XCTAssertEqual(kids[2]["title"]?.stringValue, "Named group")
        XCTAssertEqual(b.nodeCount, 6) // window, button, text, named group, checkbox, interactive group
        XCTAssertFalse(b.truncated)
    }

    func testOnlyNonEmptyFieldsAndValueTruncation() throws {
        let long = String(repeating: "长", count: 300)
        let (tree, _, _) = build([MockNode("AXTextArea", value: long, enabled: false)])
        let node = tree[0]
        XCTAssertNil(node["title"])
        XCTAssertNil(node["description"])
        XCTAssertNil(node["focused"], "focused=false omitted")
        XCTAssertEqual(node["enabled"], .bool(false), "enabled only reported when false")
        XCTAssertEqual(node["frame"], .array([1, 2, 30, 40]))
        XCTAssertEqual(node["value"]?.stringValue?.count, 121) // 120 + ellipsis
        XCTAssertEqual(node["id"]?.stringValue, "el_1")
    }

    func testMaxNodesTruncation() {
        let root = MockNode("AXWindow", title: "W", children: (0..<50).map { MockNode("AXButton", title: "b\($0)", actions: ["AXPress"]) })
        let (_, b, registered) = build([root], nodes: 10)
        XCTAssertEqual(b.nodeCount, 10)
        XCTAssertEqual(registered.count, 10)
        XCTAssertTrue(b.truncated)
    }

    func testMaxDepthLimit() {
        var leaf = MockNode("AXButton", title: "deep", actions: ["AXPress"])
        for i in 0..<10 { leaf = MockNode("AXGroup", title: "g\(i)", children: [leaf]) }
        let (_, b, _) = build([leaf], depth: 3)
        XCTAssertEqual(b.nodeCount, 4) // depths 0...3
        XCTAssertTrue(b.depthLimited)
        XCTAssertFalse(b.truncated)
    }

    func testWebContentSkippedAndContextFlags() throws {
        let root = MockNode("AXWindow", title: "Chrome", children: [
            MockNode("AXWebArea", title: "page", children: [MockNode("AXButton", title: "web", actions: ["AXPress"])]),
            MockNode("AXSheet", children: [MockNode("AXButton", title: "Open", actions: ["AXPress"])]),
        ])
        let skipped = build([root], skipWeb: true)
        let web = try XCTUnwrap(skipped.tree[0]["children"]?.arrayValue?.first)
        XCTAssertEqual(web["web_content_skipped"], .bool(true))
        XCTAssertNil(web["children"])

        let full = build([root], skipWeb: false)
        let byTitle = Dictionary(full.registered.values.map { ($0.0.title ?? "", $0.1) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byTitle["web"]?.inWebContent, true)
        XCTAssertEqual(byTitle["web"]?.inDialog, false)
        XCTAssertEqual(byTitle["Open"]?.inDialog, true)
        XCTAssertEqual(byTitle["Open"]?.inWebContent, false)
    }

    func testRegistryResets() {
        let r = ElementRegistry()
        let el = AXUIElementCreateSystemWide()
        XCTAssertEqual(r.add(RegisteredElement(element: el, pid: 1, role: "x", inWebContent: false, inDialog: false)), "el_1")
        r.reset()
        XCTAssertNil(r.get("el_1"))
        XCTAssertEqual(r.add(RegisteredElement(element: el, pid: 1, role: "x", inWebContent: false, inDialog: false)), "el_1")
    }
}
