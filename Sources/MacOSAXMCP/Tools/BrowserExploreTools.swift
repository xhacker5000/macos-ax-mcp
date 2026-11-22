import Foundation

// MARK: - iframe support

/// Where to run JS and how to map frame coordinates to page coordinates.
struct FrameContext {
    let pageSession: String     // top-level page session: input events, visibility
    let session: String         // session that owns the frame's document
    let contextId: Int?         // isolated world for same-process child frames
    let offset: CGPoint?        // frame viewport origin in page viewport coordinates (nil = unknown)
    let frameId: String?
    let url: String?

    func eval(_ expression: String, timeout: TimeInterval = 20) throws -> JSONValue {
        try CDPClient.shared.evaluate(session: session, expression: expression, timeout: timeout, contextId: contextId)
    }

    func toPage(_ p: CGPoint) throws -> CGPoint {
        guard let offset else {
            throw ToolError(code: ErrorCode.frameNotFound,
                            detail: "Cannot map coordinates for this nested frame; act on its parent frame or use browser_eval.")
        }
        return CGPoint(x: p.x + offset.x, y: p.y + offset.y)
    }

    var json: JSONValue {
        guard let frameId else { return "main" }
        return ["frame_id": .string(frameId), "url": .string(url ?? "")]
    }
}

enum Frames {
    struct Info { let id: String; let parentId: String?; let url: String; let name: String }

    static let frameParam = Schema.string("Optional iframe: frame_id, or a substring of the iframe URL or its name "
        + "(see browser_read_page mode=frames). Cross-origin iframes supported.")

    static func list(pageSession: String) throws -> [Info] {
        let r = try CDPClient.shared.send("Page.getFrameTree", [:], session: pageSession)
        var out: [Info] = []
        func walk(_ node: JSONValue) {
            let f = node["frame"] ?? .null
            if let id = f["id"]?.stringValue {
                out.append(Info(id: id, parentId: f["parentId"]?.stringValue, url: f["url"]?.stringValue ?? "", name: f["name"]?.stringValue ?? ""))
            }
            for c in node["childFrames"]?.arrayValue ?? [] { walk(c) }
        }
        walk(r["frameTree"] ?? .null)
        // Out-of-process iframes may be missing from the tree; add them from the target list.
        let known = Set(out.map(\.id))
        let targets = try CDPClient.shared.send("Target.getTargets")
        for t in targets["targetInfos"]?.arrayValue ?? [] where t["type"]?.stringValue == "iframe" {
            guard let id = t["targetId"]?.stringValue, !known.contains(id) else { continue }
            if let parent = t["parentFrameId"]?.stringValue, !known.contains(parent) { continue }
            out.append(Info(id: id, parentId: t["parentFrameId"]?.stringValue ?? out.first?.id, url: t["url"]?.stringValue ?? "", name: ""))
        }
        return out
    }

    static func json(_ frames: [Info]) -> JSONValue {
        .array(frames.map { f in
            var o: [String: JSONValue] = ["frame_id": .string(f.id), "url": .string(String(f.url.prefix(300)))]
            if !f.name.isEmpty { o["name"] = .string(f.name) }
            o["is_main"] = .bool(f.parentId == nil)
            return .object(o)
        })
    }

    static func context(tab: BrowserTools.Tab, frame selector: String?) throws -> FrameContext {
        let pageSID = try CDPClient.shared.session(for: tab.id)
        guard let selector, !selector.isEmpty, selector.lowercased() != "main" else {
            return FrameContext(pageSession: pageSID, session: pageSID, contextId: nil, offset: .zero, frameId: nil, url: nil)
        }
        let frames = try list(pageSession: pageSID)
        let children = frames.filter { $0.parentId != nil }
        let q = selector.lowercased()
        var matches = children.filter { $0.id == selector }
        if matches.isEmpty { matches = children.filter { $0.name == selector } }
        if matches.isEmpty { matches = children.filter { $0.url.lowercased().contains(q) } }
        guard !matches.isEmpty else {
            throw ToolError(code: ErrorCode.frameNotFound, detail: "No iframe matches '\(selector)'", extra: ["frames": json(frames)])
        }
        guard matches.count == 1 else {
            throw ToolError(code: ErrorCode.frameNotFound, detail: "'\(selector)' matches \(matches.count) iframes; pass a frame_id",
                            extra: ["frames": json(matches)])
        }
        let f = matches[0]

        // Cross-origin (out-of-process) iframes are their own CDP targets; same-process ones get an isolated world.
        let targets = try CDPClient.shared.send("Target.getTargets")
        let isOOPIF = (targets["targetInfos"]?.arrayValue ?? []).contains { $0["type"]?.stringValue == "iframe" && $0["targetId"]?.stringValue == f.id }
        var session = pageSID
        var contextId: Int?
        if isOOPIF {
            session = try CDPClient.shared.session(for: f.id)
        } else {
            let w = try CDPClient.shared.send("Page.createIsolatedWorld", ["frameId": .string(f.id), "worldName": "macos_ax_mcp",
                                                                           "grantUniveralAccess": true], session: pageSID)
            contextId = w["executionContextId"]?.intValue
        }

        // Offset of the frame's viewport inside the page, via its <iframe> owner element (direct children of main only).
        var offset: CGPoint?
        if f.parentId == frames.first?.id,
           let owner = try? CDPClient.shared.send("DOM.getFrameOwner", ["frameId": .string(f.id)], session: pageSID),
           let backend = owner["backendNodeId"]?.intValue {
            _ = try? CDPClient.shared.send("DOM.scrollIntoViewIfNeeded", ["backendNodeId": .int(backend)], session: pageSID)
            if let box = try? CDPClient.shared.send("DOM.getBoxModel", ["backendNodeId": .int(backend)], session: pageSID),
               let quad = box["model"]?["content"]?.arrayValue, quad.count >= 2,
               let x = CDPClient.number(quad[0]), let y = CDPClient.number(quad[1]) {
                offset = CGPoint(x: x, y: y)
            }
        }
        return FrameContext(pageSession: pageSID, session: session, contextId: contextId, offset: offset, frameId: f.id, url: f.url)
    }
}

// MARK: - Scroll / wait / hover / drag

enum BrowserExplore {
    static var definitions: [ToolDefinition] { [scroll, waitFor, hover, drag] }

    // MARK: scroll

    static let scrollJS = #"""
    (() => {
      const sel = __SEL__, dir = __DIR__, amount = __AMOUNT__;
      const find = (root) => { const h = root.querySelector(sel); if (h) return h;
        for (const x of root.querySelectorAll('*')) if (x.shadowRoot) { const y = find(x.shadowRoot); if (y) return y; } return null; };
      let el = sel ? find(document) : null;
      if (sel && !el) return { found: false };
      if (dir === 'into_view') {
        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        const r = el.getBoundingClientRect();
        return { found: true, into_view: true, top: Math.round(r.top), left: Math.round(r.left) };
      }
      const box = el || document.scrollingElement || document.documentElement;
      const isDoc = !el;
      const vh = isDoc ? innerHeight : box.clientHeight, vw = isDoc ? innerWidth : box.clientWidth;
      const step = amount > 0 ? amount : Math.round((dir === 'left' || dir === 'right' ? vw : vh) * 0.85);
      const before = { top: box.scrollTop, left: box.scrollLeft, height: box.scrollHeight };
      const opts = { behavior: 'instant' };
      if (dir === 'down') box.scrollBy({ top: step, ...opts });
      else if (dir === 'up') box.scrollBy({ top: -step, ...opts });
      else if (dir === 'right') box.scrollBy({ left: step, ...opts });
      else if (dir === 'left') box.scrollBy({ left: -step, ...opts });
      else if (dir === 'bottom') box.scrollTo({ top: box.scrollHeight, ...opts });
      else if (dir === 'top') box.scrollTo({ top: 0, ...opts });
      if (isDoc) window.dispatchEvent(new Event('scroll'));
      return { found: true, before_top: before.top, top: Math.round(box.scrollTop), left: Math.round(box.scrollLeft),
               moved: Math.round(box.scrollTop - before.top), height_before: before.height, viewport: vh };
    })()
    """#

    static let metricsJS = #"""
    (() => { const sel = __SEL__; const el = sel ? document.querySelector(sel) : null;
      const box = el || document.scrollingElement || document.documentElement;
      const vh = el ? box.clientHeight : innerHeight;
      return { top: Math.round(box.scrollTop), height: box.scrollHeight, at_bottom: box.scrollTop + vh >= box.scrollHeight - 2 }; })()
    """#

    static let scroll = ToolDefinition(
        name: "browser_scroll",
        description: "Scroll a tab (or a scrollable element / iframe): up, down, left, right, top, bottom, or into_view for a selector. "
            + "For infinite scroll pass times>1: it scrolls, waits for new content, and stops early once the bottom is reached "
            + "and the page stops growing. Works on hidden tabs too. Reports scroll position and how much content was loaded.",
        inputSchema: Schema.object([
            "tab": BrowserTools.tabParam,
            "direction": Schema.string("Where to scroll.", enumValues: ["down", "up", "left", "right", "top", "bottom", "into_view"], defaultValue: "down"),
            "selector": Schema.string("Scrollable container to scroll, or the element to bring into view (direction=into_view)."),
            "amount": Schema.int("Pixels per step (0 = about one viewport).", defaultValue: 0, min: 0, max: 100_000),
            "times": Schema.int("Repeat count, for infinite scroll.", defaultValue: 1, min: 1, max: 100),
            "wait_ms": Schema.int("Wait after each step for lazy content.", defaultValue: 600, min: 0, max: 10_000),
            "frame": Frames.frameParam,
            "confirm_user_tab": BrowserActions.confirmParam,
        ], required: ["tab"]),
        handler: { args in
            let tab = try BrowserTools.resolve(try args.requiredString("tab"))
            try BrowserActions.guardOwned(tab, args)
            let direction = try args.enumeration("direction", allowed: ["down", "up", "left", "right", "top", "bottom", "into_view"], default: "down")
            let selector = try args.string("selector")
            if direction == "into_view" && selector == nil { throw ToolError.invalid("direction=into_view needs 'selector'") }
            let amount = try args.int("amount", default: 0, range: 0...100_000)
            let times = direction == "into_view" ? 1 : try args.int("times", default: 1, range: 1...100)
            let waitMs = try args.int("wait_ms", default: 600, range: 0...10_000)
            let ctx = try Frames.context(tab: tab, frame: try args.string("frame"))
            let selJS = selector.map { JSONValue.string($0).compactString() } ?? "null"
            let js = scrollJS.replacingOccurrences(of: "__SEL__", with: selJS)
                .replacingOccurrences(of: "__DIR__", with: JSONValue.string(direction).compactString())
                .replacingOccurrences(of: "__AMOUNT__", with: String(amount))
            let metrics = metricsJS.replacingOccurrences(of: "__SEL__", with: selJS)

            let startHeight = CDPClient.number(try ctx.eval(metrics)["height"]) ?? 0
            var steps = 0
            var stalls = 0
            var last: JSONValue = .null
            var lastHeight = startHeight
            while steps < times {
                let r = try ctx.eval(js)
                guard r["found"]?.boolValue == true else {
                    throw ToolError(code: ErrorCode.elementNotFound, detail: "No element matches '\(selector ?? "")'")
                }
                steps += 1
                if direction == "into_view" { last = r; break }
                if waitMs > 0 { Poll.sleep(ms: waitMs) }
                last = try ctx.eval(metrics)
                let h = CDPClient.number(last["height"]) ?? 0
                let grew = h > lastHeight + 1
                lastHeight = h
                // Infinite scroll: stop after two consecutive steps at the bottom with no new content.
                if times > 1 && direction != "up" && direction != "top" {
                    stalls = (last["at_bottom"]?.boolValue == true && !grew) ? stalls + 1 : 0
                    if stalls >= 2 { break }
                }
            }
            var out: [String: JSONValue] = ["ok": true, "tab_id": .string(tab.id), "direction": .string(direction),
                                            "steps": .int(steps), "frame": ctx.json]
            if direction == "into_view" {
                out["element_top"] = last["top"] ?? .null
            } else {
                out["scroll_top"] = last["top"] ?? .null
                out["at_bottom"] = last["at_bottom"] ?? .null
                out["page_height_before"] = .int(Int(startHeight))
                out["page_height_after"] = .int(Int(lastHeight))
                out["content_loaded_px"] = .int(Int(lastHeight - startHeight))
            }
            return .object(out)
        }
    )

    // MARK: wait_for

    static let waitFor = ToolDefinition(
        name: "browser_wait_for",
        description: "Wait until a condition holds in a tab: an element appears (visible) or disappears, text appears in the page, "
            + "the URL contains a string, or a JS expression is truthy. Use after clicks/navigation on dynamic pages. Read-only.",
        inputSchema: Schema.object([
            "tab": BrowserTools.tabParam,
            "selector": Schema.string("CSS selector to wait for."),
            "text": Schema.string("Text to wait for in the page (or inside selector)."),
            "url_contains": Schema.string("Wait until the tab URL contains this."),
            "expression": Schema.string("JS expression; waits until truthy."),
            "gone": Schema.bool("Wait for the selector/text to DISAPPEAR instead.", defaultValue: false),
            "visible": Schema.bool("For selector: require a visible box, not just presence in the DOM.", defaultValue: true),
            "timeout_ms": Schema.int("Give up after this long.", defaultValue: 10_000, min: 100, max: 120_000),
            "frame": Frames.frameParam,
        ], required: ["tab"]),
        handler: { args in
            let tab = try BrowserTools.resolve(try args.requiredString("tab"))
            let selector = try args.string("selector")
            let text = try args.string("text")
            let urlPart = try args.string("url_contains")
            let expression = try args.string("expression")
            let gone = try args.bool("gone", default: false)
            let visible = try args.bool("visible", default: true)
            let timeout = try args.int("timeout_ms", default: 10_000, range: 100...120_000)
            guard selector != nil || text != nil || urlPart != nil || expression != nil else {
                throw ToolError.invalid("Pass at least one of selector, text, url_contains, expression")
            }
            let ctx = try Frames.context(tab: tab, frame: try args.string("frame"))
            let enc: (String?) -> String = { $0.map { JSONValue.string($0).compactString() } ?? "null" }
            let js = """
            (() => {
              const sel = \(enc(selector)), text = \(enc(text)), urlPart = \(enc(urlPart)), wantVisible = \(visible), gone = \(gone);
              const checks = [];
              let el = null;
              if (sel) {
                el = document.querySelector(sel);
                let ok = !!el;
                if (ok && wantVisible) { const r = el.getBoundingClientRect(); const cs = getComputedStyle(el);
                  ok = r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none'; }
                checks.push(gone ? !ok : ok);
              }
              if (text) { const scope = (sel && el) ? el : document.body; const has = !!scope && (scope.innerText || '').includes(text);
                checks.push(gone ? !has : has); }
              if (urlPart) checks.push(location.href.includes(urlPart));
              return { ok: checks.every(Boolean), url: location.href,
                       element: el ? { tag: el.tagName.toLowerCase(), text: (el.innerText || '').trim().slice(0, 80) } : null };
            })()
            """
            let start = Date()
            var lastState: JSONValue = .null
            let met = Poll.until(timeoutMs: timeout, intervalMs: 100) { () -> Bool? in
                guard let r = try? ctx.eval(js, timeout: 5) else { return nil } // page mid-navigation
                lastState = r
                guard r["ok"]?.boolValue == true else { return nil }
                if let expression {
                    guard let v = try? ctx.eval("Boolean(\(expression))", timeout: 5), v.boolValue == true else { return nil }
                }
                return true
            } ?? false
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            guard met else {
                throw ToolError(code: ErrorCode.waitTimeout, detail: "Condition not met within \(timeout)ms",
                                extra: ["last_state": lastState, "elapsed_ms": .int(elapsed)])
            }
            var out: [String: JSONValue] = ["ok": true, "tab_id": .string(tab.id), "elapsed_ms": .int(elapsed), "url": lastState["url"] ?? .null]
            if let e = lastState["element"], e != .null { out["element"] = e }
            return .object(out)
        }
    )

    // MARK: hover

    static let hover = ToolDefinition(
        name: "browser_hover",
        description: "Move the mouse over an element (or coordinates) with a real CDP mouse event, e.g. to open hover menus or "
            + "tooltips. Then use browser_read_page / browser_wait_for to see what appeared.",
        inputSchema: Schema.object([
            "tab": BrowserTools.tabParam,
            "selector": Schema.string("CSS selector of the element to hover."),
            "x": Schema.int("Viewport X (CSS px) when no selector.", defaultValue: 0, min: 0, max: 100_000),
            "y": Schema.int("Viewport Y (CSS px) when no selector.", defaultValue: 0, min: 0, max: 100_000),
            "frame": Frames.frameParam,
            "confirm_user_tab": BrowserActions.confirmParam,
        ], required: ["tab"]),
        handler: { args in
            let tab = try BrowserTools.resolve(try args.requiredString("tab"))
            try BrowserActions.guardOwned(tab, args)
            let ctx = try Frames.context(tab: tab, frame: try args.string("frame"))
            try BrowserActions.requireVisible(ctx.pageSession, tab)
            let (p, element) = try BrowserActions.point(ctx, args, scroll: true)
            try BrowserActions.mouse(ctx.pageSession, "mouseMoved", x: p.x, y: p.y)
            Poll.sleep(ms: 150)
            var out: [String: JSONValue] = ["ok": true, "tab_id": .string(tab.id), "x": .int(Int(p.x)), "y": .int(Int(p.y)), "frame": ctx.json]
            if let element { out["element"] = element }
            return .object(out)
        }
    )

    // MARK: drag

    static let drag = ToolDefinition(
        name: "browser_drag",
        description: "Drag from one element/point to another with real CDP mouse events. Handles both HTML5 drag-and-drop "
            + "(draggable=true, kanban boards, file-drop zones) and pointer-based dragging (sliders, sortable lists, canvas).",
        inputSchema: Schema.object([
            "tab": BrowserTools.tabParam,
            "from_selector": Schema.string("Element to start dragging."),
            "from_x": Schema.int("Start viewport X when no from_selector.", defaultValue: 0, min: 0, max: 100_000),
            "from_y": Schema.int("Start viewport Y when no from_selector.", defaultValue: 0, min: 0, max: 100_000),
            "to_selector": Schema.string("Element to drop onto."),
            "to_x": Schema.int("End viewport X when no to_selector.", defaultValue: 0, min: 0, max: 100_000),
            "to_y": Schema.int("End viewport Y when no to_selector.", defaultValue: 0, min: 0, max: 100_000),
            "steps": Schema.int("Intermediate mouse moves.", defaultValue: 12, min: 1, max: 100),
            "frame": Frames.frameParam,
            "confirm_user_tab": BrowserActions.confirmParam,
        ], required: ["tab"]),
        handler: { args in
            let tab = try BrowserTools.resolve(try args.requiredString("tab"))
            try BrowserActions.guardOwned(tab, args)
            let steps = try args.int("steps", default: 12, range: 1...100)
            let ctx = try Frames.context(tab: tab, frame: try args.string("frame"))
            let sid = ctx.pageSession
            try BrowserActions.requireVisible(sid, tab)
            let (from, fromEl) = try BrowserActions.point(ctx, args, scroll: true, selectorKey: "from_selector", xKey: "from_x", yKey: "from_y")
            let (to, toEl) = try BrowserActions.point(ctx, args, scroll: false, selectorKey: "to_selector", xKey: "to_x", yKey: "to_y")

            _ = try CDPClient.shared.send("Input.setInterceptDrags", ["enabled": true], session: sid)
            defer { _ = try? CDPClient.shared.send("Input.setInterceptDrags", ["enabled": false], session: sid) }
            _ = CDPClient.shared.takeDragData(session: sid)

            try BrowserActions.mouse(sid, "mouseMoved", x: from.x, y: from.y)
            try BrowserActions.mouse(sid, "mousePressed", x: from.x, y: from.y)
            var dragData: JSONValue?
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let x = from.x + (to.x - from.x) * t, y = from.y + (to.y - from.y) * t
                try BrowserActions.mouse(sid, "mouseMoved", x: x, y: y, buttons: 1)
                Poll.sleep(ms: 16)
                if dragData == nil { dragData = CDPClient.shared.takeDragData(session: sid) }
                if dragData != nil { break }
            }
            let mode: String
            if let data = dragData {
                // HTML5 DnD: Chrome handed us the drag payload; deliver it to the drop target.
                for type in ["dragEnter", "dragOver", "drop"] {
                    _ = try CDPClient.shared.send("Input.dispatchDragEvent", ["type": .string(type), "x": .double(to.x), "y": .double(to.y),
                                                                              "data": data, "modifiers": 0], session: sid, timeout: 5)
                    Poll.sleep(ms: 30)
                }
                try BrowserActions.mouse(sid, "mouseReleased", x: to.x, y: to.y)
                mode = "html5_drag_and_drop"
            } else {
                try BrowserActions.mouse(sid, "mouseMoved", x: to.x, y: to.y, buttons: 1)
                try BrowserActions.mouse(sid, "mouseReleased", x: to.x, y: to.y)
                mode = "pointer_drag"
            }
            Poll.sleep(ms: 100)
            var out: [String: JSONValue] = ["ok": true, "tab_id": .string(tab.id), "mode": .string(mode),
                                            "from": [.int(Int(from.x)), .int(Int(from.y))], "to": [.int(Int(to.x)), .int(Int(to.y))],
                                            "frame": ctx.json]
            if let fromEl { out["from_element"] = fromEl }
            if let toEl { out["to_element"] = toEl }
            return .object(out)
        }
    )
}
