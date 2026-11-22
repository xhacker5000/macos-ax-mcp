import XCTest
@testable import MacOSAXMCP

final class MCPProtocolTests: XCTestCase {
    private let server = MCPServer(registry: .makeDefault())

    private func call(_ line: String) throws -> JSONValue {
        let out = try XCTUnwrap(server.handle(line: line), "expected a response for \(line)")
        XCTAssertFalse(out.contains("\n"), "frames must be single-line")
        return try JSONValue.parse(out)
    }

    func testInitializeEchoesSupportedVersions() throws {
        for v in ["2024-11-05", "2025-03-26"] {
            let r = try call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(v)","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
            XCTAssertEqual(r["id"], .int(1))
            XCTAssertEqual(r["result"]?["protocolVersion"]?.stringValue, v)
            XCTAssertEqual(r["result"]?["capabilities"]?["tools"], .object([:]))
            XCTAssertEqual(r["result"]?["serverInfo"]?["name"]?.stringValue, "macos-ax-mcp")
            XCTAssertEqual(r["result"]?["serverInfo"]?["version"]?.stringValue, "0.2.0")
        }
        let r = try call(#"{"jsonrpc":"2.0","id":"s","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual(r["id"], .string("s"))
        XCTAssertEqual(r["result"]?["protocolVersion"]?.stringValue, ServerInfo.fallbackProtocolVersion)
    }

    func testNotificationsProduceNoResponse() {
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#))
        XCTAssertNil(server.handle(line: "   "))
    }

    func testPing() throws {
        let r = try call(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)
        XCTAssertEqual(r["result"], .object([:]))
    }

    func testToolsListHasStrictSchemas() throws {
        let r = try call(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try XCTUnwrap(r["result"]?["tools"]?.arrayValue)
        XCTAssertEqual(Set(tools.compactMap { $0["name"]?.stringValue }),
                       ["os_check_health", "os_list_windows", "os_handle_file_dialog", "os_ax_snapshot", "os_ax_interact",
                        "browser_list_tabs", "browser_read_page", "browser_console", "browser_eval", "browser_upload_file",
                        "browser_open_tab", "browser_close_tab", "browser_navigate", "browser_click", "browser_type",
                        "browser_key", "browser_screenshot", "browser_network",
                        "browser_scroll", "browser_wait_for", "browser_hover", "browser_drag"])
        for t in tools {
            XCTAssertEqual(t["inputSchema"]?["type"]?.stringValue, "object")
            XCTAssertEqual(t["inputSchema"]?["additionalProperties"], .bool(false))
            XCTAssertFalse(t["description"]?.stringValue?.isEmpty ?? true)
        }
        let fd = try XCTUnwrap(tools.first { $0["name"]?.stringValue == "os_handle_file_dialog" })
        XCTAssertEqual(fd["inputSchema"]?["required"], .array(["file_path"]))
    }

    func testErrors() throws {
        var r = try call("not json")
        XCTAssertEqual(r["error"]?["code"], .int(-32700))
        XCTAssertEqual(r["id"], .null)

        r = try call(#"{"jsonrpc":"2.0","id":3}"#)
        XCTAssertEqual(r["error"]?["code"], .int(-32600))
        XCTAssertEqual(r["id"], .int(3))

        r = try call(#"{"jsonrpc":"1.0","id":4,"method":"ping"}"#)
        XCTAssertEqual(r["error"]?["code"], .int(-32600))

        r = try call(#"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#)
        XCTAssertEqual(r["error"]?["code"], .int(-32601))

        r = try call(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nope"}}"#)
        XCTAssertEqual(r["error"]?["code"], .int(-32602))

        r = try call(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"os_check_health","arguments":[1]}}"#)
        XCTAssertEqual(r["error"]?["code"], .int(-32602))
    }

    func testToolErrorIsStructuredNotFatal() throws {
        let r = try call(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"os_handle_file_dialog","arguments":{}}}"#)
        XCTAssertEqual(r["result"]?["isError"], .bool(true))
        let text = try XCTUnwrap(r["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        let payload = try JSONValue.parse(text)
        XCTAssertEqual(payload["ok"], .bool(false))
        XCTAssertEqual(payload["error_code"]?.stringValue, ErrorCode.invalidArgument)
        XCTAssertNotNil(payload["error_detail"]?.stringValue)
    }

    func testBatch() throws {
        let out = try XCTUnwrap(server.handle(line: #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"ping"}]"#))
        let arr = try XCTUnwrap(try JSONValue.parse(out).arrayValue)
        XCTAssertEqual(arr.count, 2)
    }

    // MARK: End-to-end over real stdio pipes

    private func binaryURL() throws -> URL {
        let dir = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let url = dir.appendingPathComponent("macos-ax-mcp")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("binary not built at \(url.path); run `swift build` first")
        }
        return url
    }

    func testStdioProcessFramingAndPurity() throws {
        let proc = Process()
        proc.executableURL = try binaryURL()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr
        try proc.run()

        let frames = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"xctest","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"os_check_health","arguments":{"prompt_permission":false}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"os_handle_file_dialog","arguments":{"file_path":"/definitely/not/here.mp4"}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"ping"}"#,
        ]
        stdin.fileHandleForWriting.write(Data((frames.joined(separator: "\n") + "\n").utf8))
        try stdin.fileHandleForWriting.close()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(proc.terminationStatus, 0)

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("\n"), "every frame must be newline-terminated")
        XCTAssertFalse(text.contains("Content-Length"))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        XCTAssertEqual(lines.count, 5, "5 requests with ids -> exactly 5 frames, notification -> none:\n\(text)")
        var ids: [JSONValue] = []
        for line in lines {
            let v = try JSONValue.parse(String(line)) // throws on any non-JSON pollution
            XCTAssertEqual(v["jsonrpc"]?.stringValue, "2.0")
            ids.append(v["id"] ?? .null)
            if v["id"] == .int(3) {
                let payload = try JSONValue.parse(v["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? "")
                XCTAssertEqual(payload["ok"], .bool(true))
                XCTAssertNotNil(payload["accessibility_trusted"]?.boolValue)
            }
            if v["id"] == .int(4) {
                XCTAssertEqual(v["result"]?["isError"], .bool(true))
                let payload = try JSONValue.parse(v["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? "")
                let code = payload["error_code"]?.stringValue
                XCTAssertTrue(code == ErrorCode.tccUntrusted || code == ErrorCode.fileNotFound, "got \(code ?? "nil")")
            }
        }
        XCTAssertEqual(ids, [.int(1), .int(2), .int(3), .int(4), .int(5)])
    }
}
