import Foundation

/// Minimal Chrome DevTools Protocol client over URLSessionWebSocketTask (no third-party deps).
///
/// Connects to the user's *running* Chrome via the endpoint Chrome writes to `DevToolsActivePort` when
/// chrome://inspect/#remote-debugging -> "Allow remote debugging for this browser instance" is on.
/// Chrome asks the user to approve every new connection, so one connection is kept for the process lifetime.
final class CDPClient: @unchecked Sendable {
    static let shared = CDPClient()

    struct ConsoleEntry {
        let seq: Int
        let source: String      // console | exception | log
        let level: String
        let text: String
        let url: String?
        let line: Int?
        let timestamp: Double?

        var json: JSONValue {
            var o: [String: JSONValue] = ["seq": .int(seq), "source": .string(source), "level": .string(level), "text": .string(text)]
            if let url, !url.isEmpty { o["url"] = .string(url) }
            if let line { o["line"] = .int(line) }
            if let timestamp { o["timestamp_ms"] = .int(Int(timestamp)) }
            return .object(o)
        }
    }

    private final class Pending {
        let semaphore = DispatchSemaphore(value: 0)
        var response: JSONValue?
        var failure: String?
    }

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var endpoint: URL?
    private var nextID = 1
    private var pending: [Int: Pending] = [:]
    private var sessionsByTarget: [String: String] = [:]
    private var consoleBySession: [String: [ConsoleEntry]] = [:]
    private var consoleSeq = 0
    private var connected = false

    struct NetworkEntry {
        let seq: Int
        let requestID: String
        var url: String
        var method: String
        var resourceType: String
        var status: Int?
        var mimeType: String?
        var encodedBytes: Int?
        var failure: String?
        var finished = false
        var startTime: Double?
        var endTime: Double?

        var json: JSONValue {
            var o: [String: JSONValue] = ["seq": .int(seq), "request_id": .string(requestID), "url": .string(String(url.prefix(500))),
                                          "method": .string(method), "type": .string(resourceType), "finished": .bool(finished)]
            if let status { o["status"] = .int(status) }
            if let mimeType { o["mime_type"] = .string(mimeType) }
            if let encodedBytes { o["encoded_bytes"] = .int(encodedBytes) }
            if let failure { o["failure"] = .string(failure) }
            if let s = startTime, let e = endTime { o["duration_ms"] = .int(Int((e - s) * 1000)) }
            return .object(o)
        }
    }

    private var networkBySession: [String: [String: NetworkEntry]] = [:]
    private var networkEnabled: Set<String> = []
    private var networkSeq = 0
    /// Tabs created by this server process (safe to navigate/close without user confirmation).
    private var ownedTargets: Set<String> = []
    static let networkCap = 2000

    static let consoleCap = 1000
    static let approvalTimeout: TimeInterval = 60

    static var portFilePath: String {
        if let p = ProcessInfo.processInfo.environment["MACOS_AX_MCP_CDP_PORT_FILE"], !p.isEmpty { return p }
        return NSHomeDirectory() + "/Library/Application Support/Google/Chrome/DevToolsActivePort"
    }

    static let enableHint = "In Chrome open chrome://inspect/#remote-debugging and tick 'Allow remote debugging for this browser instance'."

    // MARK: Connection

    static func readEndpoint() throws -> URL {
        guard let text = try? String(contentsOfFile: portFilePath, encoding: .utf8) else {
            throw ToolError(code: ErrorCode.cdpNotEnabled, detail: "Chrome remote debugging is not enabled (\(portFilePath) missing). \(enableHint)")
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 2, let port = Int(lines[0]), lines[1].hasPrefix("/devtools/browser/"),
              let url = URL(string: "ws://127.0.0.1:\(port)\(lines[1])") else {
            throw ToolError(code: ErrorCode.cdpNotEnabled, detail: "Unrecognised DevToolsActivePort contents. \(enableHint)")
        }
        return url
    }

    /// Connects if needed. The first command after connecting blocks until the user approves in Chrome.
    func ensureConnected() throws {
        let url = try CDPClient.readEndpoint()
        lock.lock()
        let reuse = connected && endpoint == url
        lock.unlock()
        if reuse { return }

        disconnect(reason: "reconnecting")
        let session = URLSession(configuration: .ephemeral)
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = 256 << 20
        lock.lock()
        task = t
        urlSession = session
        endpoint = url
        connected = true
        lock.unlock()
        t.resume()
        receiveLoop(t)
        Log.info("cdp: connecting \(url.absoluteString) (waiting for user approval in Chrome)")
        do {
            _ = try rawSend("Browser.getVersion", [:], session: nil, timeout: CDPClient.approvalTimeout)
            Log.info("cdp: connected")
        } catch let e as ToolError {
            disconnect(reason: "handshake failed")
            if e.code == ErrorCode.cdpTimeout {
                throw ToolError(code: ErrorCode.cdpNotApproved,
                                detail: "Chrome did not accept the debugging connection within \(Int(CDPClient.approvalTimeout))s. Click 'Allow' in Chrome's prompt and retry.")
            }
            throw e
        }
    }

    func disconnect(reason: String) {
        lock.lock()
        let t = task
        let s = urlSession
        task = nil
        urlSession = nil
        connected = false
        sessionsByTarget.removeAll()
        networkEnabled.removeAll()
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        for p in waiting.values { p.failure = "connection closed (\(reason))"; p.semaphore.signal() }
        t?.cancel(with: .goingAway, reason: nil)
        s?.invalidateAndCancel()
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                Log.info("cdp: receive ended: \(error.localizedDescription)")
                self.lock.lock()
                let current = self.task === t
                self.lock.unlock()
                if current { self.disconnect(reason: error.localizedDescription) }
            case .success(let message):
                let text: String?
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: text = nil
                }
                if let text, let value = try? JSONValue.parse(text) { self.handle(value) }
                self.receiveLoop(t)
            }
        }
    }

    private func handle(_ message: JSONValue) {
        if let id = message["id"]?.intValue {
            lock.lock()
            let p = pending.removeValue(forKey: id)
            lock.unlock()
            if let p {
                if let err = message["error"] {
                    p.failure = err["message"]?.stringValue ?? err.compactString()
                } else {
                    p.response = message["result"] ?? .object([:])
                }
                p.semaphore.signal()
            }
            return
        }
        guard let method = message["method"]?.stringValue else { return }
        let params = message["params"] ?? .object([:])
        let sessionID = message["sessionId"]?.stringValue
        switch method {
        case "Runtime.consoleAPICalled":
            guard let sessionID else { return }
            let args = params["args"]?.arrayValue ?? []
            let text = args.map(CDPClient.remoteObjectText).joined(separator: " ")
            let frame = params["stackTrace"]?["callFrames"]?.arrayValue?.first
            appendConsole(sessionID, source: "console", level: params["type"]?.stringValue ?? "log", text: text,
                          url: frame?["url"]?.stringValue, line: frame?["lineNumber"]?.intValue.map { $0 + 1 },
                          timestamp: CDPClient.number(params["timestamp"]))
        case "Runtime.exceptionThrown":
            guard let sessionID else { return }
            let d = params["exceptionDetails"] ?? .object([:])
            let desc = d["exception"]?["description"]?.stringValue ?? d["text"]?.stringValue ?? "exception"
            appendConsole(sessionID, source: "exception", level: "error", text: desc, url: d["url"]?.stringValue,
                          line: d["lineNumber"]?.intValue.map { $0 + 1 }, timestamp: CDPClient.number(params["timestamp"]))
        case "Log.entryAdded":
            guard let sessionID else { return }
            let e = params["entry"] ?? .object([:])
            appendConsole(sessionID, source: "log:" + (e["source"]?.stringValue ?? "other"), level: e["level"]?.stringValue ?? "info",
                          text: e["text"]?.stringValue ?? "", url: e["url"]?.stringValue,
                          line: e["lineNumber"]?.intValue.map { $0 + 1 }, timestamp: CDPClient.number(e["timestamp"]))
        case "Network.requestWillBeSent":
            guard let sid = sessionID, let rid = params["requestId"]?.stringValue else { return }
            lock.lock()
            networkSeq += 1
            var map = networkBySession[sid] ?? [:]
            map[rid] = NetworkEntry(seq: networkSeq, requestID: rid, url: params["request"]?["url"]?.stringValue ?? "",
                                    method: params["request"]?["method"]?.stringValue ?? "GET",
                                    resourceType: params["type"]?.stringValue ?? "Other",
                                    startTime: CDPClient.number(params["timestamp"]))
            if map.count > CDPClient.networkCap, let oldest = map.min(by: { $0.value.seq < $1.value.seq })?.key { map[oldest] = nil }
            networkBySession[sid] = map
            lock.unlock()
        case "Network.responseReceived":
            guard let sid = sessionID, let rid = params["requestId"]?.stringValue else { return }
            lock.lock()
            networkBySession[sid]?[rid]?.status = params["response"]?["status"]?.intValue
            networkBySession[sid]?[rid]?.mimeType = params["response"]?["mimeType"]?.stringValue
            lock.unlock()
        case "Network.loadingFinished":
            guard let sid = sessionID, let rid = params["requestId"]?.stringValue else { return }
            lock.lock()
            networkBySession[sid]?[rid]?.finished = true
            networkBySession[sid]?[rid]?.encodedBytes = CDPClient.number(params["encodedDataLength"]).map { Int($0) }
            networkBySession[sid]?[rid]?.endTime = CDPClient.number(params["timestamp"])
            lock.unlock()
        case "Network.loadingFailed":
            guard let sid = sessionID, let rid = params["requestId"]?.stringValue else { return }
            lock.lock()
            networkBySession[sid]?[rid]?.finished = true
            networkBySession[sid]?[rid]?.failure = (params["canceled"]?.boolValue == true ? "canceled: " : "") + (params["errorText"]?.stringValue ?? "failed")
            networkBySession[sid]?[rid]?.endTime = CDPClient.number(params["timestamp"])
            lock.unlock()
        case "Target.detachedFromTarget":
            lock.lock()
            if let sid = params["sessionId"]?.stringValue {
                sessionsByTarget = sessionsByTarget.filter { $0.value != sid }
                consoleBySession[sid] = nil
                networkBySession[sid] = nil
                networkEnabled.remove(sid)
            }
            lock.unlock()
        default:
            break
        }
    }

    private func appendConsole(_ session: String, source: String, level: String, text: String, url: String?, line: Int?, timestamp: Double?) {
        lock.lock()
        consoleSeq += 1
        var list = consoleBySession[session] ?? []
        list.append(ConsoleEntry(seq: consoleSeq, source: source, level: level, text: String(text.prefix(4000)),
                                 url: url, line: line, timestamp: timestamp))
        if list.count > CDPClient.consoleCap { list.removeFirst(list.count - CDPClient.consoleCap) }
        consoleBySession[session] = list
        lock.unlock()
    }

    static func number(_ v: JSONValue?) -> Double? {
        switch v {
        case .int(let i)?: return Double(i)
        case .double(let d)?: return d
        default: return nil
        }
    }

    static func remoteObjectText(_ o: JSONValue) -> String {
        if let v = o["value"] {
            switch v {
            case .string(let s): return s
            case .null: return "null"
            default: return v.compactString()
            }
        }
        if let u = o["unserializableValue"]?.stringValue { return u }
        if let d = o["description"]?.stringValue { return d }
        return o["type"]?.stringValue ?? "?"
    }

    // MARK: Commands

    private func rawSend(_ method: String, _ params: JSONValue, session: String?, timeout: TimeInterval) throws -> JSONValue {
        lock.lock()
        guard let t = task, connected else {
            lock.unlock()
            throw ToolError(code: ErrorCode.cdpDisconnected, detail: "Not connected to Chrome")
        }
        let id = nextID
        nextID += 1
        let p = Pending()
        pending[id] = p
        lock.unlock()

        var frame: [String: JSONValue] = ["id": .int(id), "method": .string(method), "params": params]
        if let session { frame["sessionId"] = .string(session) }
        t.send(.string(JSONValue.object(frame).compactString())) { [weak self] error in
            guard let error, let self else { return }
            self.lock.lock()
            let waiting = self.pending.removeValue(forKey: id)
            self.lock.unlock()
            waiting?.failure = "send failed: \(error.localizedDescription)"
            waiting?.semaphore.signal()
        }
        if p.semaphore.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock()
            pending[id] = nil
            lock.unlock()
            throw ToolError(code: ErrorCode.cdpTimeout, detail: "\(method) timed out after \(Int(timeout))s")
        }
        if let failure = p.failure {
            throw ToolError(code: ErrorCode.cdpCommandFailed, detail: "\(method): \(failure)")
        }
        return p.response ?? .object([:])
    }

    /// Sends a command, reconnecting once if the socket dropped (e.g. Chrome restarted).
    func send(_ method: String, _ params: JSONValue = .object([:]), session: String? = nil, timeout: TimeInterval = 20) throws -> JSONValue {
        try ensureConnected()
        do {
            return try rawSend(method, params, session: session, timeout: timeout)
        } catch let e as ToolError where e.code == ErrorCode.cdpDisconnected {
            try ensureConnected()
            return try rawSend(method, params, session: session, timeout: timeout)
        }
    }

    /// Attaches (flattened) to a page target once and enables Runtime/Log so console events are collected.
    func session(for targetID: String) throws -> String {
        try ensureConnected()
        lock.lock()
        let existing = sessionsByTarget[targetID]
        lock.unlock()
        if let existing { return existing }
        let r = try send("Target.attachToTarget", ["targetId": .string(targetID), "flatten": true])
        guard let sid = r["sessionId"]?.stringValue else {
            throw ToolError(code: ErrorCode.cdpCommandFailed, detail: "attachToTarget returned no sessionId")
        }
        lock.lock()
        sessionsByTarget[targetID] = sid
        lock.unlock()
        // Runtime.enable replays console messages Chrome still has buffered for this page.
        _ = try? send("Runtime.enable", [:], session: sid)
        _ = try? send("Log.enable", [:], session: sid)
        Poll.sleep(ms: 150) // let replayed events arrive
        return sid
    }

    func consoleEntries(session: String, afterSeq: Int) -> [ConsoleEntry] {
        lock.lock()
        defer { lock.unlock() }
        return (consoleBySession[session] ?? []).filter { $0.seq > afterSeq }
    }

    func enableNetwork(session: String) throws -> Bool {
        lock.lock()
        let already = networkEnabled.contains(session)
        lock.unlock()
        if already { return false }
        _ = try send("Network.enable", ["maxTotalBufferSize": 50_000_000, "maxResourceBufferSize": 10_000_000], session: session)
        lock.lock()
        networkEnabled.insert(session)
        lock.unlock()
        return true
    }

    func networkEntries(session: String, afterSeq: Int) -> [NetworkEntry] {
        lock.lock()
        defer { lock.unlock() }
        return (networkBySession[session] ?? [:]).values.filter { $0.seq > afterSeq }.sorted { $0.seq < $1.seq }
    }

    func markOwned(_ targetID: String) {
        lock.lock()
        ownedTargets.insert(targetID)
        lock.unlock()
    }

    func isOwned(_ targetID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ownedTargets.contains(targetID)
    }

    func forget(_ targetID: String) {
        lock.lock()
        ownedTargets.remove(targetID)
        sessionsByTarget[targetID] = nil
        lock.unlock()
    }

    /// Evaluates JS in the page and returns the by-value result.
    func evaluate(session: String, expression: String, awaitPromise: Bool = true, timeout: TimeInterval = 20) throws -> JSONValue {
        let r = try send("Runtime.evaluate", [
            "expression": .string(expression), "returnByValue": true, "awaitPromise": .bool(awaitPromise),
            "userGesture": true, "replMode": true,
        ], session: session, timeout: timeout)
        if let ex = r["exceptionDetails"] {
            let desc = ex["exception"]?["description"]?.stringValue ?? ex["text"]?.stringValue ?? "exception"
            throw ToolError(code: ErrorCode.jsException, detail: desc)
        }
        return r["result"]?["value"] ?? .null
    }
}
