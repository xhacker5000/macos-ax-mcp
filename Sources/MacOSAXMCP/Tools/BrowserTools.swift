import AppKit
import Foundation

/// Live-browser tools over CDP: tabs, DOM, console, JS, dialog-free file upload.
enum BrowserTools {
    static let tabParam = Schema.string("Tab selector: tab_id from browser_list_tabs, 'active' (tab shown in Chrome's front window), "
        + "or a case-insensitive substring of the tab title or URL.")

    static var definitions: [ToolDefinition] { [listTabs, readPage, console, eval, upload] }

    // MARK: Tab resolution

    struct Tab {
        let id: String
        let title: String
        let url: String
    }

    static func pageTabs(includeInternal: Bool = false) throws -> [Tab] {
        let r = try CDPClient.shared.send("Target.getTargets")
        return (r["targetInfos"]?.arrayValue ?? []).compactMap { t in
            guard t["type"]?.stringValue == "page", let id = t["targetId"]?.stringValue else { return nil }
            let url = t["url"]?.stringValue ?? ""
            if !includeInternal && (url.hasPrefix("chrome://") || url.hasPrefix("devtools://") || url.hasPrefix("chrome-extension://")
                                    || url.hasPrefix("chrome-untrusted://")) { return nil }
            return Tab(id: id, title: t["title"]?.stringValue ?? "", url: url)
        }
    }

    /// Front Chrome window as seen by Accessibility: its title ("<tab> - Google Chrome - <profile>") and frame.
    static func frontWindow() -> (title: String, frame: CGRect?)? {
        guard AX.isTrusted(), let chrome = AppLocator.find("com.google.Chrome") else { return nil }
        let app = AX.application(pid: chrome.processIdentifier)
        guard let w = AX.element(app, "AXFocusedWindow") ?? AX.element(app, "AXMainWindow"),
              let title = AX.title(w), !title.isEmpty else { return nil }
        let tabTitle = title.range(of: " - Google Chrome", options: .backwards).map { String(title[..<$0.lowerBound]) } ?? title
        return (tabTitle, AX.frame(w))
    }

    /// The tab shown in Chrome's front window. Title match first; when several tabs share the title, the CDP
    /// window bounds are compared with the AX window frame.
    static func activeTab(in tabs: [Tab]) -> Tab? {
        guard let front = frontWindow() else { return nil }
        let byTitle = tabs.filter { $0.title == front.title }
        if byTitle.count <= 1 { return byTitle.first }
        guard let frame = front.frame else { return nil }
        let hits = byTitle.filter { t in
            guard let w = try? CDPClient.shared.send("Browser.getWindowForTarget", ["targetId": .string(t.id)], timeout: 5),
                  let b = w["bounds"], let l = b["left"]?.intValue, let tp = b["top"]?.intValue,
                  let wd = b["width"]?.intValue, let h = b["height"]?.intValue else { return false }
            return abs(Double(l) - frame.minX) <= 2 && abs(Double(tp) - frame.minY) <= 2
                && abs(Double(wd) - frame.width) <= 2 && abs(Double(h) - frame.height) <= 2
        }
        return hits.count == 1 ? hits[0] : nil
    }

    static func resolve(_ selector: String) throws -> Tab {
        let tabs = try pageTabs(includeInternal: true)
        if let exact = tabs.first(where: { $0.id == selector }) { return exact }
        if selector.lowercased() == "active" {
            guard let t = activeTab(in: tabs) else {
                throw ToolError(code: ErrorCode.tabNotFound,
                                detail: "Cannot determine the active tab (needs Accessibility trust, a focused Chrome window, and a unique match)")
            }
            return t
        }
        let q = selector.lowercased()
        let matches = tabs.filter { $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }
        guard !matches.isEmpty else {
            throw ToolError(code: ErrorCode.tabNotFound, detail: "No tab matches '\(selector)'. Use browser_list_tabs.")
        }
        guard matches.count == 1 else {
            throw ToolError(code: ErrorCode.tabAmbiguous, detail: "'\(selector)' matches \(matches.count) tabs; pass a tab_id.",
                            extra: ["matches": .array(matches.prefix(20).map(tabJSON))])
        }
        return matches[0]
    }

    static func tabJSON(_ t: Tab) -> JSONValue {
        ["tab_id": .string(t.id), "title": .string(t.title), "url": .string(t.url)]
    }

    static func truncate(_ s: String, _ max: Int) -> (String, Bool) {
        s.count > max ? (String(s.prefix(max)), true) : (s, false)
    }

    // MARK: browser_list_tabs

    static let listTabs = ToolDefinition(
        name: "browser_list_tabs",
        description: "List the tabs open in the user's running Chrome (all windows and profiles) via the DevTools protocol. "
            + "Requires chrome://inspect/#remote-debugging to be enabled; Chrome asks the user to approve the first connection.",
        inputSchema: Schema.object([
            "include_internal": Schema.bool("Include chrome://, devtools:// and extension pages.", defaultValue: false),
        ]),
        handler: { args in
            let includeInternal = try args.bool("include_internal", default: false)
            let tabs = try pageTabs(includeInternal: includeInternal)
            let active = activeTab(in: tabs)?.id
            var items: [JSONValue] = []
            for t in tabs {
                var o: [String: JSONValue] = ["tab_id": .string(t.id), "title": .string(t.title), "url": .string(t.url)]
                if let w = try? CDPClient.shared.send("Browser.getWindowForTarget", ["targetId": .string(t.id)], timeout: 5),
                   let wid = w["windowId"]?.intValue {
                    o["window_id"] = .int(wid)
                }
                if t.id == active { o["is_active_in_front_window"] = true }
                items.append(.object(o))
            }
            return ["ok": true, "count": .int(items.count), "tabs": .array(items)]
        }
    )

    // MARK: browser_read_page

    static let elementsJS = #"""
    (() => {
      const MAX = __MAX__;
      const sel = (el) => {
        if (el.id && document.querySelectorAll('#' + CSS.escape(el.id)).length === 1) return '#' + CSS.escape(el.id);
        const parts = [];
        for (let e = el; e && e.nodeType === 1 && parts.length < 5; e = e.parentElement) {
          let p = e.tagName.toLowerCase();
          if (e.id && document.querySelectorAll('#' + CSS.escape(e.id)).length === 1) { parts.unshift('#' + CSS.escape(e.id)); break; }
          const sib = e.parentElement ? [...e.parentElement.children].filter(c => c.tagName === e.tagName) : [];
          if (sib.length > 1) p += ':nth-of-type(' + (sib.indexOf(e) + 1) + ')';
          parts.unshift(p);
        }
        return parts.join(' > ');
      };
      const out = [];
      const walk = (root) => {
        for (const el of root.querySelectorAll('a[href],button,input,select,textarea,label,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[contenteditable=""],[contenteditable=true],[onclick],[tabindex]')) {
          if (out.length >= MAX) return;
          const r = el.getBoundingClientRect();
          const cs = getComputedStyle(el);
          const visible = r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none';
          const inViewport = r.right > 0 && r.bottom > 0 && r.left < innerWidth && r.top < innerHeight;
          const o = { tag: el.tagName.toLowerCase(), selector: sel(el), visible: visible && inViewport };
          if (visible && !inViewport) o.offscreen = true;
          const text = (el.innerText || el.textContent || '').trim().replace(/\s+/g, ' ');
          if (text) o.text = text.slice(0, 80);
          for (const a of ['type', 'name', 'placeholder', 'aria-label', 'href', 'accept', 'for', 'role']) {
            const v = el.getAttribute(a); if (v) o[a] = v.slice(0, 120);
          }
          if ('value' in el && el.type !== 'password' && el.value) o.value = String(el.value).slice(0, 120);
          if (el.type === 'file') o.files = [...el.files].map(f => ({ name: f.name, size: f.size, type: f.type }));
          if (el.disabled) o.disabled = true;
          out.push(o);
        }
        for (const host of root.querySelectorAll('*')) if (host.shadowRoot && out.length < MAX) walk(host.shadowRoot);
      };
      walk(document);
      return out;
    })()
    """#

    static let readPage = ToolDefinition(
        name: "browser_read_page",
        description: "Read a tab's live DOM. mode=text: visible text; mode=html: full serialized HTML (document or a CSS selector); "
            + "mode=elements: interactive elements with CSS selectors, values and file-input state (shadow DOM included).",
        inputSchema: Schema.object([
            "tab": tabParam,
            "mode": Schema.string("What to return.", enumValues: ["text", "html", "elements"], defaultValue: "text"),
            "selector": Schema.string("Optional CSS selector to scope text/html to one element."),
            "max_chars": Schema.int("Truncate text/html output.", defaultValue: 30000, min: 1000, max: 1_000_000),
            "max_elements": Schema.int("Max elements for mode=elements.", defaultValue: 300, min: 10, max: 2000),
        ], required: ["tab"]),
        handler: { args in
            let tab = try resolve(try args.requiredString("tab"))
            let mode = try args.enumeration("mode", allowed: ["text", "html", "elements"], default: "text")
            let selector = try args.string("selector")
            let maxChars = try args.int("max_chars", default: 30000, range: 1000...1_000_000)
            let maxElements = try args.int("max_elements", default: 300, range: 10...2000)
            let sid = try CDPClient.shared.session(for: tab.id)

            var out: [String: JSONValue] = ["ok": true, "tab": tabJSON(tab), "mode": .string(mode)]
            let meta = try CDPClient.shared.evaluate(session: sid, expression: "({title: document.title, url: location.href, readyState: document.readyState})")
            out["title"] = meta["title"] ?? .null
            out["url"] = meta["url"] ?? .null
            out["ready_state"] = meta["readyState"] ?? .null

            switch mode {
            case "elements":
                let v = try CDPClient.shared.evaluate(session: sid, expression: elementsJS.replacingOccurrences(of: "__MAX__", with: String(maxElements)))
                out["elements"] = v
                out["element_count"] = .int(v.arrayValue?.count ?? 0)
            default:
                let target = selector.map { "document.querySelector(\(JSONValue.string($0).compactString()))" } ?? (mode == "html" ? "document.documentElement" : "document.body")
                let prop = mode == "html" ? "outerHTML" : "innerText"
                let v = try CDPClient.shared.evaluate(session: sid, expression: "(() => { const el = \(target); return el ? el.\(prop) : null })()")
                guard let s = v.stringValue else {
                    throw ToolError(code: ErrorCode.elementNotFound, detail: "Selector matched nothing: \(selector ?? "(document)")")
                }
                let (t, cut) = truncate(s, maxChars)
                out["content"] = .string(t)
                out["total_chars"] = .int(s.count)
                out["truncated"] = .bool(cut)
            }
            return .object(out)
        }
    )

    // MARK: browser_console

    static let console = ToolDefinition(
        name: "browser_console",
        description: "Console messages, uncaught exceptions and browser log entries (network errors, violations) for a tab. "
            + "The first call attaches and replays what Chrome still buffers; later calls also include everything logged since. "
            + "Pass after_seq (the last seq you saw) to get only new entries.",
        inputSchema: Schema.object([
            "tab": tabParam,
            "after_seq": Schema.int("Only entries with seq greater than this.", defaultValue: 0, min: 0, max: Int(Int32.max)),
            "levels": Schema.string("Comma-separated level filter, e.g. 'error,warning'. Empty = all."),
            "max_entries": Schema.int("Return at most this many (newest).", defaultValue: 200, min: 1, max: 1000),
            "include_extensions": Schema.bool("Include messages emitted by browser-extension content scripts.", defaultValue: false),
        ], required: ["tab"]),
        handler: { args in
            let tab = try resolve(try args.requiredString("tab"))
            let after = try args.int("after_seq", default: 0, range: 0...Int(Int32.max))
            let maxEntries = try args.int("max_entries", default: 200, range: 1...1000)
            let levels = Set((try args.string("levels") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
            let includeExtensions = try args.bool("include_extensions", default: false)
            let sid = try CDPClient.shared.session(for: tab.id)
            var entries = CDPClient.shared.consoleEntries(session: sid, afterSeq: after)
            let extensionCount = entries.filter { $0.url?.hasPrefix("chrome-extension://") == true }.count
            if !includeExtensions { entries = entries.filter { $0.url?.hasPrefix("chrome-extension://") != true } }
            if !levels.isEmpty { entries = entries.filter { levels.contains($0.level.lowercased()) } }
            let total = entries.count
            if entries.count > maxEntries { entries = Array(entries.suffix(maxEntries)) }
            return [
                "ok": true, "tab": tabJSON(tab), "count": .int(entries.count), "total_matching": .int(total),
                "extension_entries_hidden": .int(includeExtensions ? 0 : extensionCount),
                "last_seq": .int(entries.last?.seq ?? after), "entries": .array(entries.map(\.json)),
            ]
        }
    )

    // MARK: browser_eval

    static let eval = ToolDefinition(
        name: "browser_eval",
        description: "Evaluate a JavaScript expression in a tab (page context, promises awaited) and return its JSON value.",
        inputSchema: Schema.object([
            "tab": tabParam,
            "expression": Schema.string("JavaScript expression, e.g. 'document.title' or '[...document.links].length'."),
            "timeout_ms": Schema.int("Evaluation timeout.", defaultValue: 15000, min: 100, max: 120000),
        ], required: ["tab", "expression"]),
        handler: { args in
            let tab = try resolve(try args.requiredString("tab"))
            let expression = try args.requiredString("expression")
            let timeout = try args.int("timeout_ms", default: 15000, range: 100...120000)
            let sid = try CDPClient.shared.session(for: tab.id)
            let value = try CDPClient.shared.evaluate(session: sid, expression: expression, timeout: Double(timeout) / 1000)
            return ["ok": true, "tab": tabJSON(tab), "value": value]
        }
    )

    // MARK: browser_upload_file

    static let findInputJS = #"""
    (() => {
      const want = __SEL__;
      const hits = [];
      const walk = (root) => {
        for (const el of root.querySelectorAll(want || 'input[type=file]')) hits.push(el);
        for (const h of root.querySelectorAll('*')) if (h.shadowRoot) walk(h.shadowRoot);
      };
      walk(document);
      return hits.filter(e => e instanceof HTMLInputElement && e.type === 'file')[0] || null;
    })()
    """#

    static let upload = ToolDefinition(
        name: "browser_upload_file",
        description: "Attach a local file to an <input type=file> in a tab WITHOUT opening the native file dialog "
            + "(DOM.setFileInputFiles). Works in the background and for multi-GB files; fires input/change events.",
        inputSchema: Schema.object([
            "tab": tabParam,
            "file_path": Schema.string("Absolute local path ('~' expanded)."),
            "selector": Schema.string("CSS selector of the file input (default: first input[type=file], shadow DOM included)."),
        ], required: ["tab", "file_path"]),
        handler: { args in
            let tab = try resolve(try args.requiredString("tab"))
            let file = try FileValidation.validate(try args.requiredString("file_path"))
            let selector = try args.string("selector")
            let sid = try CDPClient.shared.session(for: tab.id)
            let js = findInputJS.replacingOccurrences(of: "__SEL__", with: selector.map { JSONValue.string($0).compactString() } ?? "null")
            let r = try CDPClient.shared.send("Runtime.evaluate", ["expression": .string(js), "returnByValue": false], session: sid)
            guard let objectID = r["result"]?["objectId"]?.stringValue else {
                throw ToolError(code: ErrorCode.elementNotFound, detail: "No <input type=file> found\(selector.map { " for '\($0)'" } ?? "")")
            }
            _ = try CDPClient.shared.send("DOM.setFileInputFiles", ["files": [.string(file.path)], "objectId": .string(objectID)], session: sid)
            let check = try CDPClient.shared.send("Runtime.callFunctionOn", [
                "objectId": .string(objectID), "returnByValue": true,
                "functionDeclaration": "function() { return [...this.files].map(f => ({name: f.name, size: f.size, type: f.type})) }",
            ], session: sid)
            _ = try? CDPClient.shared.send("Runtime.releaseObject", ["objectId": .string(objectID)], session: sid)
            let files = check["result"]?["value"] ?? .array([])
            let ok = files.arrayValue?.first?["size"]?.intValue == file.sizeBytes
            guard ok else {
                throw ToolError(code: ErrorCode.actionFailed, detail: "Input did not report the file after setFileInputFiles",
                                extra: ["input_files": files])
            }
            return ["ok": true, "tab": tabJSON(tab), "selected_path": .string(file.path),
                    "file_size_bytes": .int(file.sizeBytes), "input_files": files]
        }
    )
}
