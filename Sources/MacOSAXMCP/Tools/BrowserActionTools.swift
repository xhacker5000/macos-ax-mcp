import Foundation

/// Page-mutating browser tools over CDP: tabs, navigation, trusted input, screenshots, network.
///
/// Safety: actions that change a page only run without confirmation on tabs this server opened
/// (browser_open_tab). Acting on a tab the user opened requires confirm_user_tab=true, which the agent
/// may only pass after the user explicitly agreed.
enum BrowserActions {
    static var definitions: [ToolDefinition] { [openTab, closeTab, navigate, click, type, key, screenshot, network] + BrowserExplore.definitions }

    static let confirmParam = Schema.bool("Required to act on a tab the USER opened (not one from browser_open_tab). "
        + "Only pass true after the user explicitly agreed to changes in that tab.", defaultValue: false)

    static func guardOwned(_ tab: BrowserTools.Tab, _ args: Args) throws {
        if CDPClient.shared.isOwned(tab.id) { return }
        if try args.bool("confirm_user_tab", default: false) { return }
        throw ToolError(code: ErrorCode.userTabProtected,
                        detail: "'\(tab.title)' is a tab the user opened. Use browser_open_tab for your own tab, or get the user's consent and pass confirm_user_tab=true.",
                        extra: ["tab": BrowserTools.tabJSON(tab)])
    }

    static func waitForLoad(_ sid: String, timeoutMs: Int) -> String {
        let state = Poll.until(timeoutMs: timeoutMs, intervalMs: 100) { () -> String? in
            let v = try? CDPClient.shared.evaluate(session: sid, expression: "document.readyState", timeout: 2)
            return v?.stringValue == "complete" ? "complete" : nil
        }
        return state ?? ((try? CDPClient.shared.evaluate(session: sid, expression: "document.readyState", timeout: 2))?.stringValue ?? "unknown")
    }

    static func pageInfo(_ sid: String) -> JSONValue {
        (try? CDPClient.shared.evaluate(session: sid, expression: "({title: document.title, url: location.href})", timeout: 3)) ?? .null
    }

    /// Chrome queues (and effectively drops) input for hidden tabs; fail fast instead of a multi-second silent no-op.
    static func requireVisible(_ sid: String, _ tab: BrowserTools.Tab) throws {
        let v = try CDPClient.shared.evaluate(session: sid, expression: "document.visibilityState", timeout: 3)
        if v.stringValue == "hidden" {
            throw ToolError(code: ErrorCode.tabHidden,
                            detail: "'\(tab.title)' is a hidden background tab (or its window is minimized/fully covered); Chrome ignores mouse/key input there. "
                                + "Open your own tab with browser_open_tab (new window), or use browser_eval / browser_type without press_enter.")
        }
    }

    // MARK: open / close

    static let openTab = ToolDefinition(
        name: "browser_open_tab",
        description: "Open a NEW tab (never touches the user's tabs). Defaults to its own window without stealing keyboard focus: "
            + "Chrome ignores mouse/key input in hidden background tabs. Tabs opened here can be navigated/clicked/closed freely.",
        inputSchema: Schema.object([
            "url": Schema.string("URL to open.", defaultValue: "about:blank"),
            "new_window": Schema.bool("Own window (needed for click/key). false = hidden background tab: read/screenshot/network only.", defaultValue: true),
            "timeout_ms": Schema.int("Wait for load.", defaultValue: 15000, min: 0, max: 120000),
        ]),
        handler: { args in
            let url = try args.string("url") ?? "about:blank"
            let newWindow = try args.bool("new_window", default: true)
            let timeout = try args.int("timeout_ms", default: 15000, range: 0...120000)
            let r = try CDPClient.shared.send("Target.createTarget", ["url": .string(url), "newWindow": .bool(newWindow), "background": .bool(!newWindow)])
            guard let id = r["targetId"]?.stringValue else {
                throw ToolError(code: ErrorCode.cdpCommandFailed, detail: "createTarget returned no targetId")
            }
            CDPClient.shared.markOwned(id)
            let sid = try CDPClient.shared.session(for: id)
            let state = timeout > 0 ? waitForLoad(sid, timeoutMs: timeout) : "not_waited"
            let info = pageInfo(sid)
            return ["ok": true, "tab_id": .string(id), "ready_state": .string(state),
                    "title": info["title"] ?? .null, "url": info["url"] ?? .string(url)]
        }
    )

    static let closeTab = ToolDefinition(
        name: "browser_close_tab",
        description: "Close a tab. Tabs from browser_open_tab close freely; user tabs need confirm_user_tab=true.",
        inputSchema: Schema.object(["tab": BrowserTools.tabParam, "confirm_user_tab": confirmParam], required: ["tab"]),
        handler: { args in
            let tab = try BrowserTools.resolve(try args.requiredString("tab"))
            try guardOwned(tab, args)
            _ = try CDPClient.shared.send("Target.closeTarget", ["targetId": .string(tab.id)])
            CDPClient.shared.forget(tab.id)
            return ["ok": true, "closed": BrowserTools.tabJSON(tab)]
        }
    )

    // MARK: navigate

    static let navigate = ToolDefinition(
        name: "browser_navigate",
        description: "Navigate a tab to a URL, or go back/forward/reload, and wait for the page to load.",
        inputSchema: Schema.object([
            "tab": BrowserTools.tabParam,
            "url": Schema.string("URL, or 'back' / 'forward' / 'reload'."),
            "timeout_ms": Schema.int("Wait for load.", defaultValue: 20000, min: 0, max: 120000),
            "confirm_user_tab": confirmParam,
        ], required: ["tab", "url"]),
        handler: { args in
            let tab = try BrowserTools.resolve(try args.requiredString("tab"))
            try guardOwned(tab, args)
            let url = try args.requiredString("url")
            let timeout = try args.int("timeout_ms", default: 20000, range: 0...120000)
            let sid = try CDPClient.shared.session(for: tab.id)
            switch url.lowercased() {
            case "reload":
                _ = try CDPClient.shared.send("Page.reload", [:], session: sid)
            case "back", "forward":
                let h = try CDPClient.shared.send("Page.getNavigationHistory", [:], session: sid)
                let idx = h["currentIndex"]?.intValue ?? 0
                let entries = h["entries"]?.arrayValue ?? []
                let target = idx + (url.lowercased() == "back" ? -1 : 1)
                guard target >= 0, target < entries.count, let eid = entries[target]["id"]?.intValue else {
                    throw ToolError(code: ErrorCode.navigationFailed, detail: "No history entry to go \(url)")
                }
                _ = try CDPClient.shared.send("Page.navigateToHistoryEntry", ["entryId": .int(eid)], session: sid)
            default:
                let r = try CDPClient.shared.send("Page.navigate", ["url": .string(url)], session: sid)
                if let err = r["errorText"]?.stringValue, !err.isEmpty {
                    throw ToolError(code: ErrorCode.navigationFailed, detail: err)
                }
            }
            Poll.sleep(ms: 150) // let the old document start unloading
            let state = timeout > 0 ? waitForLoad(sid, timeoutMs: timeout) : "not_waited"
            let info = pageInfo(sid)
            return ["ok": true, "tab_id": .string(tab.id), "ready_state": .string(state),
                    "title": info["title"] ?? .null, "url": info["url"] ?? .null]
        }
    )

    // MARK: click

    static let locateJS = #"""
    (() => {
      const sel = __SEL__, doScroll = __SCROLL__;
      const find = (root) => {
        const hit = root.querySelector(sel);
        if (hit) return hit;
        for (const h of root.querySelectorAll('*')) if (h.shadowRoot) { const x = find(h.shadowRoot); if (x) return x; }
        return null;
      };
      const el = find(document);
      if (!el) return { found: false };
      if (doScroll) el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      const r = el.getBoundingClientRect();
      const x = r.left + r.width / 2, y = r.top + r.height / 2;
      const inViewport = x >= 0 && y >= 0 && x <= innerWidth && y <= innerHeight;
      const top = inViewport ? document.elementFromPoint(x, y) : null;
      const covered = !!top && top !== el && !el.contains(top) && !(top.shadowRoot && top.shadowRoot.contains(el)) && !top.contains(el)
                      && !(el.tagName === 'INPUT' && el.labels && [...el.labels].some(l => l.contains(top)));
      const desc = (e) => e ? e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') + (e.className && typeof e.className === 'string' ? '.' + e.className.trim().split(/\s+/).slice(0, 2).join('.') : '') : null;
      return { found: true, x, y, w: r.width, h: r.height, in_viewport: inViewport, covered, covered_by: covered ? desc(top) : null,
               tag: desc(el), text: (el.innerText || el.value || '').trim().slice(0, 60) };
    })()
    """#

    static func mouse(_ sid: String, _ type: String, x: Double, y: Double, clickCount: Int = 1, buttons: Int? = nil) throws {
        var p: [String: JSONValue] = ["type": .string(type), "x": .double(x), "y": .double(y)]
        if type != "mouseMoved" {
            p["button"] = "left"
            p["clickCount"] = .int(clickCount)
            p["buttons"] = .int(type == "mousePressed" ? 1 : 0)
        } else if let buttons {
            p["buttons"] = .int(buttons)
            if buttons != 0 { p["button"] = "left" }
        }
        _ = try CDPClient.shared.send("Input.dispatchMouseEvent", .object(p), session: sid, timeout: 4)
    }

    /// Resolves a selector (in the given frame) or raw x/y to a point in PAGE viewport coordinates.
    static func point(_ ctx: FrameContext, _ args: Args, scroll: Bool, force: Bool = true,
                      selectorKey: String = "selector", xKey: String = "x", yKey: String = "y") throws -> (CGPoint, JSONValue?) {
        if let selector = try args.string(selectorKey) {
            let js = locateJS.replacingOccurrences(of: "__SEL__", with: JSONValue.string(selector).compactString())
                .replacingOccurrences(of: "__SCROLL__", with: scroll ? "true" : "false")
            let loc = try ctx.eval(js)
            guard loc["found"]?.boolValue == true, let lx = CDPClient.number(loc["x"]), let ly = CDPClient.number(loc["y"]) else {
                throw ToolError(code: ErrorCode.elementNotFound, detail: "No element matches '\(selector)'")
            }
            if (CDPClient.number(loc["w"]) ?? 0) < 1 || (CDPClient.number(loc["h"]) ?? 0) < 1 {
                throw ToolError(code: ErrorCode.elementNotVisible, detail: "'\(selector)' has no visible box (display:none / zero size). For file inputs use browser_upload_file.")
            }
            if loc["in_viewport"]?.boolValue == false {
                throw ToolError(code: ErrorCode.elementNotVisible, detail: "'\(selector)' is outside the viewport; scroll it into view first (browser_scroll direction=into_view).")
            }
            if loc["covered"]?.boolValue == true && !force {
                throw ToolError(code: ErrorCode.elementNotVisible, detail: "'\(selector)' is covered by \(loc["covered_by"]?.stringValue ?? "another element"); pass force=true to click anyway.")
            }
            return (try ctx.toPage(CGPoint(x: lx, y: ly)), loc)
        }
        guard args.raw[xKey] != nil, args.raw[yKey] != nil else {
            throw ToolError.invalid("Pass '\(selectorKey)' or both '\(xKey)' and '\(yKey)'")
        }
        let p = CGPoint(x: Double(try args.int(xKey, default: 0, range: 0...100_000)), y: Double(try args.int(yKey, default: 0, range: 0...100_000)))
        return (ctx.frameId == nil ? p : try ctx.toPage(p), nil)
    }

    static let click = ToolDefinition(
        name: "browser_click",
        description: "Click an element (CSS selector, shadow DOM searched, iframe via 'frame') or viewport coordinates with trusted "
            + "CDP mouse events (counts as a real user gesture, e.g. opens file choosers). Scrolls into view and reports if covered.",
        inputSchema: Schema.object([
            "tab": BrowserTools.tabParam,
            "selector": Schema.string("CSS selector of the element to click."),
            "x": Schema.int("Viewport X (CSS px) when no selector.", defaultValue: 0, min: 0, max: 100_000),
            "y": Schema.int("Viewport Y (CSS px) when no selector.", defaultValue: 0, min: 0, max: 100_000),
            "double": Schema.bool("Double-click.", defaultValue: false),
            "force": Schema.bool("Click even if another element covers the target.", defaultValue: false),
            "frame": Frames.frameParam,
            "confirm_user_tab": confirmParam,
        ], required: ["tab"]),
        handler: { args in
            let tab = try BrowserTools.resolve(try args.requiredString("tab"))
            try guardOwned(tab, args)
            let double = try args.bool("double", default: false)
            let force = try args.bool("force", default: false)
            let ctx = try Frames.context(tab: tab, frame: try args.string("frame"))
            let sid = ctx.pageSession
            try requireVisible(sid, tab)
            let (p, element) = try point(ctx, args, scroll: true, force: force)
            try mouse(sid, "mouseMoved", x: p.x, y: p.y)
            for n in 1...(double ? 2 : 1) {
                try mouse(sid, "mousePressed", x: p.x, y: p.y, clickCount: n)
                try mouse(sid, "mouseReleased", x: p.x, y: p.y, clickCount: n)
            }
            var out: [String: JSONValue] = ["ok": true, "tab_id": .string(tab.id), "x": .int(Int(p.x)), "y": .int(Int(p.y)), "frame": ctx.json]
            if let element { out["element"] = element }
            Poll.sleep(ms: 100)
            out["page"] = pageInfo(sid)
            return .object(out)
        }
    )

    // MARK: keyboard

    struct KeyDef { let key: String; let code: String; let vk: Int; let text: String? }

    static let namedKeys: [String: KeyDef] = [
        "enter": KeyDef(key: "Enter", code: "Enter", vk: 13, text: "\r"),
        "tab": KeyDef(key: "Tab", code: "Tab", vk: 9, text: nil),
        "escape": KeyDef(key: "Escape", code: "Escape", vk: 27, text: nil),
        "backspace": KeyDef(key: "Backspace", code: "Backspace", vk: 8, text: nil),
        "delete": KeyDef(key: "Delete", code: "Delete", vk: 46, text: nil),
        "space": KeyDef(key: " ", code: "Space", vk: 32, text: " "),
        "arrowup": KeyDef(key: "ArrowUp", code: "ArrowUp", vk: 38, text: nil),
        "arrowdown": KeyDef(key: "ArrowDown", code: "ArrowDown", vk: 40, text: nil),
        "arrowleft": KeyDef(key: "ArrowLeft", code: "ArrowLeft", vk: 37, text: nil),
        "arrowright": KeyDef(key: "ArrowRight", code: "ArrowRight", vk: 39, text: nil),
        "home": KeyDef(key: "Home", code: "Home", vk: 36, text: nil),
        "end": KeyDef(key: "End", code: "End", vk: 35, text: nil),
        "pageup": KeyDef(key: "PageUp", code: "PageUp", vk: 33, text: nil),
        "pagedown": KeyDef(key: "PageDown", code: "PageDown", vk: 34, text: nil),
    ]

    /// macOS editing shortcuts do not run from synthetic key events alone; CDP needs explicit editor commands.
    static let metaCommands: [String: String] = ["a": "selectAll", "c": "copy", "v": "paste", "x": "cut", "z": "undo"]

    static func pressKey(_ sid: String, _ spec: String) throws {
        let parts = spec.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else { throw ToolError.invalid("Empty key '\(spec)'") }
        var modifiers = 0
        for m in parts.dropLast() {
            switch m.lowercased() {
            case "alt", "option": modifiers |= 1
            case "ctrl", "control": modifiers |= 2
            case "cmd", "meta", "command": modifiers |= 4
            case "shift": modifiers |= 8
            default: throw ToolError.invalid("Unknown modifier '\(m)' in '\(spec)'")
            }
        }
        let def: KeyDef
        if let named = namedKeys[last.lowercased()] {
            def = named
        } else if last.count == 1, let ch = last.first {
            let upper = String(ch).uppercased()
            let isLetter = ch.isLetter && ch.isASCII
            let isDigit = ch.isNumber && ch.isASCII
            def = KeyDef(key: String(ch), code: isLetter ? "Key\(upper)" : (isDigit ? "Digit\(ch)" : ""),
                         vk: Int(upper.unicodeScalars.first?.value ?? 0), text: String(ch))
        } else {
            throw ToolError.invalid("Unknown key '\(last)'. Use a single character or one of: \(namedKeys.keys.sorted().joined(separator: ", "))")
        }
        var down: [String: JSONValue] = ["type": .string(def.text != nil && modifiers & 6 == 0 ? "keyDown" : "rawKeyDown"),
                                         "key": .string(def.key), "code": .string(def.code),
                                         "windowsVirtualKeyCode": .int(def.vk), "nativeVirtualKeyCode": .int(def.vk),
                                         "modifiers": .int(modifiers)]
        if let t = def.text, modifiers & 6 == 0 { down["text"] = .string(t); down["unmodifiedText"] = .string(t) }
        if modifiers & 4 != 0, let cmd = metaCommands[last.lowercased()] { down["commands"] = [.string(cmd)] }
        _ = try CDPClient.shared.send("Input.dispatchKeyEvent", .object(down), session: sid, timeout: 10)
        _ = try CDPClient.shared.send("Input.dispatchKeyEvent", ["type": "keyUp", "key": .string(def.key), "code": .string(def.code),
                                                                 "windowsVirtualKeyCode": .int(def.vk), "nativeVirtualKeyCode": .int(def.vk),
                                                                 "modifiers": .int(modifiers)], session: sid, timeout: 10)
    }

    static let focusJS = #"""
    (() => {
      const sel = __SEL__, clear = __CLEAR__;
      const find = (root) => { const h = root.querySelector(sel); if (h) return h;
        for (const x of root.querySelectorAll('*')) if (x.shadowRoot) { const y = find(x.shadowRoot); if (y) return y; } return null; };
      const el = sel ? find(document) : document.activeElement;
      if (!el) return { found: false };
      el.scrollIntoView({ block: 'center', behavior: 'instant' });
      el.focus();
      if (clear) {
        if ('value' in el && typeof el.select === 'function') { el.select(); }
        else if (el.isContentEditable) { const r = document.createRange(); r.selectNodeContents(el); const s = getSelection(); s.removeAllRanges(); s.addRange(r); }
      }
      return { found: true, focused: document.activeElement === el || el.contains(document.activeElement), tag: el.tagName.toLowerCase() };
    })()
    """#

    static let type = ToolDefinition(
        name: "browser_type",
        description: "Type text into an element (or the focused element) via Input.insertText: IME-safe, any language, "
            + "fires input events like real typing. Optionally clears first and presses Enter after.",
        inputSchema: Schema.object([
            "tab": BrowserTools.tabParam,
            "text": Schema.string("Text to insert."),
            "selector": Schema.string("CSS selector to focus first (default: currently focused element)."),
            "clear": Schema.bool("Replace existing content.", defaultValue: false),
            "press_enter": Schema.bool("Press Enter after typing.", defaultValue: false),
            "frame": Frames.frameParam,
            "confirm_user_tab": confirmParam,
        ], required: ["tab", "text"]),
        handler: { args in
            let tab = try BrowserTools.resolve(try args.requiredString("tab"))
            try guardOwned(tab, args)
            guard let text = try args.string("text") else { throw ToolError.invalid("'text' is required") }
            let selector = try args.string("selector")
            let clear = try args.bool("clear", default: false)
            let enter = try args.bool("press_enter", default: false)
            let ctx = try Frames.context(tab: tab, frame: try args.string("frame"))
            let sid = ctx.pageSession
            if enter || (clear && text.isEmpty) { try requireVisible(sid, tab) }
            let js = focusJS.replacingOccurrences(of: "__SEL__", with: selector.map { JSONValue.string($0).compactString() } ?? "null")
                .replacingOccurrences(of: "__CLEAR__", with: clear ? "true" : "false")
            let f = try ctx.eval(js)
            guard f["found"]?.boolValue == true else {
                throw ToolError(code: ErrorCode.elementNotFound, detail: selector.map { "No element matches '\($0)'" } ?? "No focused element")
            }
            if clear && text.isEmpty { try pressKey(sid, "Backspace") }
            if !text.isEmpty { _ = try CDPClient.shared.send("Input.insertText", ["text": .string(text)], session: sid) }
            if enter { try pressKey(sid, "Enter") }
            let value = try? ctx.eval("(() => { const e = document.activeElement; return e ? (e.isContentEditable ? e.innerText : (e.value ?? null)) : null })()")
            var out: [String: JSONValue] = ["ok": true, "tab_id": .string(tab.id), "element": f, "frame": ctx.json]
            if let v = value?.stringValue { out["value_after"] = .string(String(v.prefix(500))) }
            return .object(out)
        }
    )

    static let key = ToolDefinition(
        name: "browser_key",
        description: "Press keys in a tab, e.g. 'Enter', 'Tab', 'Escape', 'ArrowDown', 'cmd+a', 'shift+Tab'. "
            + "Space-separate several presses: 'ArrowDown ArrowDown Enter'.",
        inputSchema: Schema.object([
            "tab": BrowserTools.tabParam,
            "keys": Schema.string("Key presses, space separated."),
            "confirm_user_tab": confirmParam,
        ], required: ["tab", "keys"]),
        handler: { args in
            let tab = try BrowserTools.resolve(try args.requiredString("tab"))
            try guardOwned(tab, args)
            let keys = try args.requiredString("keys").split(separator: " ").map(String.init)
            let sid = try CDPClient.shared.session(for: tab.id)
            try requireVisible(sid, tab)
            for k in keys { try pressKey(sid, k); Poll.sleep(ms: 20) }
            return ["ok": true, "tab_id": .string(tab.id), "pressed": .array(keys.map { .string($0) })]
        }
    )

    // MARK: screenshot

    static let screenshot = ToolDefinition(
        name: "browser_screenshot",
        description: "Capture a tab as PNG/JPEG (viewport, full page, or one element) and save it to disk; returns the file path "
            + "so it can be viewed with the Read tool. Read-only.",
        inputSchema: Schema.object([
            "tab": BrowserTools.tabParam,
            "full_page": Schema.bool("Capture the whole scrollable page.", defaultValue: false),
            "selector": Schema.string("Capture only this element."),
            "format": Schema.string("Image format.", enumValues: ["png", "jpeg"], defaultValue: "png"),
            "path": Schema.string("Output path (default: /tmp/macos-ax-mcp/screenshots/<time>.<ext>)."),
        ], required: ["tab"]),
        handler: { args in
            let tab = try BrowserTools.resolve(try args.requiredString("tab"))
            let full = try args.bool("full_page", default: false)
            let selector = try args.string("selector")
            let format = try args.enumeration("format", allowed: ["png", "jpeg"], default: "png")
            let sid = try CDPClient.shared.session(for: tab.id)
            var params: [String: JSONValue] = ["format": .string(format), "captureBeyondViewport": .bool(full || selector != nil)]
            if format == "jpeg" { params["quality"] = 85 }
            if let selector {
                let r = try CDPClient.shared.evaluate(session: sid, expression: """
                    (() => { const e = document.querySelector(\(JSONValue.string(selector).compactString())); if (!e) return null;
                      const r = e.getBoundingClientRect(); return {x: r.left + scrollX, y: r.top + scrollY, w: r.width, h: r.height} })()
                    """)
                guard let x = CDPClient.number(r["x"]), let y = CDPClient.number(r["y"]),
                      let w = CDPClient.number(r["w"]), let h = CDPClient.number(r["h"]), w > 0, h > 0 else {
                    throw ToolError(code: ErrorCode.elementNotFound, detail: "No visible element matches '\(selector)'")
                }
                params["clip"] = ["x": .double(x), "y": .double(y), "width": .double(w), "height": .double(h), "scale": 1]
            } else if full {
                let m = try CDPClient.shared.send("Page.getLayoutMetrics", [:], session: sid)
                let size = m["cssContentSize"] ?? m["contentSize"] ?? .null
                if let w = CDPClient.number(size["width"]), let h = CDPClient.number(size["height"]) {
                    params["clip"] = ["x": 0, "y": 0, "width": .double(w), "height": .double(min(h, 16384)), "scale": 1]
                }
            }
            let r = try CDPClient.shared.send("Page.captureScreenshot", .object(params), session: sid, timeout: 30)
            guard let b64 = r["data"]?.stringValue, let data = Data(base64Encoded: b64) else {
                throw ToolError(code: ErrorCode.cdpCommandFailed, detail: "captureScreenshot returned no data (a hidden background tab may not render)")
            }
            let defaultDir = "/tmp/macos-ax-mcp/screenshots"
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let path = (try args.string("path")).map { ($0 as NSString).expandingTildeInPath } ?? "\(defaultDir)/\(stamp).\(format == "png" ? "png" : "jpg")"
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path))
            return ["ok": true, "tab_id": .string(tab.id), "path": .string(path), "bytes": .int(data.count)]
        }
    )

    // MARK: network

    static let network = ToolDefinition(
        name: "browser_network",
        description: "Network requests of a tab (URL, method, type, status, size, duration, failure). Recording starts on the "
            + "first call; pass reload=true to capture a full page load. Pass body_for_request_id to fetch one response body.",
        inputSchema: Schema.object([
            "tab": BrowserTools.tabParam,
            "after_seq": Schema.int("Only requests with seq greater than this.", defaultValue: 0, min: 0, max: Int(Int32.max)),
            "url_contains": Schema.string("Filter by URL substring."),
            "failed_only": Schema.bool("Only failed requests or HTTP status >= 400.", defaultValue: false),
            "reload": Schema.bool("Reload the tab after enabling recording (needs an owned tab or confirm_user_tab).", defaultValue: false),
            "body_for_request_id": Schema.string("Return the response body of this request id."),
            "max_entries": Schema.int("Return at most this many (newest).", defaultValue: 200, min: 1, max: 2000),
            "confirm_user_tab": confirmParam,
        ], required: ["tab"]),
        handler: { args in
            let tab = try BrowserTools.resolve(try args.requiredString("tab"))
            let sid = try CDPClient.shared.session(for: tab.id)
            if let rid = try args.string("body_for_request_id") {
                let b = try CDPClient.shared.send("Network.getResponseBody", ["requestId": .string(rid)], session: sid)
                let encoded = b["base64Encoded"]?.boolValue ?? false
                let body = b["body"]?.stringValue ?? ""
                let (t, cut) = BrowserTools.truncate(body, 200_000)
                return ["ok": true, "request_id": .string(rid), "base64_encoded": .bool(encoded), "body": .string(t),
                        "total_chars": .int(body.count), "truncated": .bool(cut)]
            }
            let started = try CDPClient.shared.enableNetwork(session: sid)
            if try args.bool("reload", default: false) {
                try guardOwned(tab, args)
                _ = try CDPClient.shared.send("Page.reload", [:], session: sid)
                Poll.sleep(ms: 150)
                _ = waitForLoad(sid, timeoutMs: 20000)
                Poll.sleep(ms: 300)
            }
            let after = try args.int("after_seq", default: 0, range: 0...Int(Int32.max))
            let maxEntries = try args.int("max_entries", default: 200, range: 1...2000)
            let filter = try args.string("url_contains")?.lowercased()
            let failedOnly = try args.bool("failed_only", default: false)
            var entries = CDPClient.shared.networkEntries(session: sid, afterSeq: after)
            if let filter { entries = entries.filter { $0.url.lowercased().contains(filter) } }
            if failedOnly { entries = entries.filter { $0.failure != nil || ($0.status ?? 0) >= 400 } }
            let total = entries.count
            if entries.count > maxEntries { entries = Array(entries.suffix(maxEntries)) }
            var out: [String: JSONValue] = ["ok": true, "tab": BrowserTools.tabJSON(tab), "count": .int(entries.count),
                                            "total_matching": .int(total), "last_seq": .int(entries.last?.seq ?? after),
                                            "entries": .array(entries.map(\.json))]
            if started { out["note"] = "Recording started now; earlier requests are not available. Use reload=true to capture a page load." }
            return .object(out)
        }
    )
}
