import Foundation

enum ServerInfo {
    static let name = "macos-ax-mcp"
    static let version = "0.1.0"
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let fallbackProtocolVersion = "2025-03-26"
    static let instructions = """
    OS-boundary execution layer for macOS. Use os_handle_file_dialog to complete an already-open native \
    file chooser (NSOpenPanel) with an absolute path (IME-safe, any file size). Use os_ax_snapshot + \
    os_ax_interact for native AppKit UI (sheets, dialogs, toolbars). Browser web content is out of scope: \
    use the browser extension for DOM work. Run os_check_health first if calls fail with ERR_TCC_UNTRUSTED.
    """
}

/// Newline-delimited JSON-RPC 2.0 MCP server (stdio transport).
final class MCPServer {
    let registry: ToolRegistry
    private(set) var negotiatedProtocolVersion: String?

    init(registry: ToolRegistry) {
        self.registry = registry
    }

    // MARK: Transport

    /// Blocking stdio loop. All protocol frames go to `outputFD`; nothing else is ever written there.
    func runStdio(outputFD: Int32) {
        Log.info("server start pid=\(getpid()) version=\(ServerInfo.version)")
        while let line = readLine(strippingNewline: true) {
            if let response = handle(line: line) {
                FDWriter.writeLine(response, fd: outputFD)
            }
        }
        Log.info("stdin closed, exiting")
    }

    // MARK: Framing / routing (pure, unit-testable)

    /// Handles one inbound frame. Returns a single-line JSON response, or nil when nothing must be sent.
    func handle(line rawLine: String) -> String? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return nil }
        let data = Data(line.utf8)

        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return encode(.failure(id: .null, code: RPCErrorCode.parseError, message: "Parse error"))
        }

        if case .array(let batch) = message {
            if batch.isEmpty {
                return encode(.failure(id: .null, code: RPCErrorCode.invalidRequest, message: "Invalid Request: empty batch"))
            }
            let responses = batch.compactMap { element -> RPCResponse? in
                let elementData = (try? JSONValue.encoder().encode(element)) ?? Data()
                return handleMessage(value: element, data: elementData)
            }
            if responses.isEmpty { return nil }
            guard let out = try? JSONValue.encoder().encode(responses) else { return nil }
            return String(data: out, encoding: .utf8)
        }

        return handleMessage(value: message, data: data).flatMap(encode)
    }

    private func handleMessage(value: JSONValue, data: Data) -> RPCResponse? {
        guard case .object(let obj) = value else {
            return .failure(id: .null, code: RPCErrorCode.invalidRequest, message: "Invalid Request")
        }
        // Responses from the client (e.g. to server-initiated requests) are ignored.
        if obj["method"] == nil && (obj["result"] != nil || obj["error"] != nil) { return nil }

        guard let request = try? JSONDecoder().decode(RPCRequest.self, from: data), request.jsonrpc == "2.0" else {
            return .failure(id: validID(obj["id"]) ?? .null, code: RPCErrorCode.invalidRequest, message: "Invalid Request")
        }

        guard let id = request.id else {
            handleNotification(request)
            return nil
        }
        guard validID(id) != nil else {
            return .failure(id: .null, code: RPCErrorCode.invalidRequest, message: "Invalid Request: id must be string, number or null")
        }

        do {
            let result = try dispatch(request)
            return .success(id: id, result: result)
        } catch let e as RPCErrorObject {
            return .failure(id: id, code: e.code, message: e.message, data: e.data)
        } catch {
            return .failure(id: id, code: RPCErrorCode.internalError, message: "Internal error: \(error)")
        }
    }

    private func validID(_ id: JSONValue?) -> JSONValue? {
        guard let id else { return nil }
        switch id {
        case .string, .int, .null: return id
        case .double(let d) where d.rounded() == d: return id
        default: return nil
        }
    }

    private func handleNotification(_ request: RPCRequest) {
        // notifications/initialized, notifications/cancelled, etc. are accepted silently.
        Log.debug("notification \(request.method)")
    }

    private func dispatch(_ request: RPCRequest) throws -> JSONValue {
        switch request.method {
        case "initialize":
            return initialize(params: request.params)
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": registry.listJSON()]
        case "tools/call":
            return try callTool(params: request.params)
        default:
            throw RPCErrorObject(code: RPCErrorCode.methodNotFound, message: "Method not found: \(request.method)")
        }
    }

    private func initialize(params: JSONValue?) -> JSONValue {
        let requested = params?["protocolVersion"]?.stringValue
        let version = requested.flatMap { ServerInfo.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? ServerInfo.fallbackProtocolVersion
        negotiatedProtocolVersion = version
        let client = params?["clientInfo"]?["name"]?.stringValue ?? "unknown"
        Log.info("initialize client=\(client) requested=\(requested ?? "nil") negotiated=\(version)")
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": .string(ServerInfo.name), "version": .string(ServerInfo.version)],
            "instructions": .string(ServerInfo.instructions),
        ]
    }

    private func callTool(params: JSONValue?) throws -> JSONValue {
        guard let name = params?["name"]?.stringValue else {
            throw RPCErrorObject(code: RPCErrorCode.invalidParams, message: "Invalid params: 'name' (string) is required")
        }
        let rawArgs = params?["arguments"] ?? .object([:])
        let arguments: [String: JSONValue]
        switch rawArgs {
        case .object(let o): arguments = o
        case .null: arguments = [:]
        default:
            throw RPCErrorObject(code: RPCErrorCode.invalidParams, message: "Invalid params: 'arguments' must be an object")
        }
        guard let outcome = registry.call(name: name, arguments: arguments) else {
            throw RPCErrorObject(code: RPCErrorCode.invalidParams, message: "Unknown tool: \(name)")
        }
        return [
            "content": [["type": "text", "text": .string(outcome.payload.compactString())]],
            "isError": .bool(outcome.isError),
        ]
    }

    private func encode(_ response: RPCResponse) -> String? {
        guard let data = try? JSONValue.encoder().encode(response) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Raw POSIX writer: immune to FileHandle ObjC exceptions on EPIPE.
enum FDWriter {
    static func writeLine(_ s: String, fd: Int32) {
        var bytes = Array(s.utf8)
        bytes.append(0x0A)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                return
            }
            offset += n
        }
    }
}

/// Diagnostics: never stdout. Appends to /tmp/macos-ax-mcp.log; mirrors to stderr when --verbose.
enum Log {
    static var verbose = false
    static var path = "/tmp/macos-ax-mcp.log"
    private static let formatter = ISO8601DateFormatter()

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }
    static func debug(_ message: String) { if verbose { write("DEBUG", message) } }

    private static func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)"
        if verbose { FDWriter.writeLine(line, fd: STDERR_FILENO) }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        if fd >= 0 {
            FDWriter.writeLine(line, fd: fd)
            close(fd)
        }
    }
}
