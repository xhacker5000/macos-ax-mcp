import Foundation

// MARK: - Errors

enum ErrorCode {
    static let invalidArgument = "ERR_INVALID_ARGUMENT"
    static let tccUntrusted = "ERR_TCC_UNTRUSTED"
    static let invalidPath = "ERR_INVALID_PATH"
    static let fileNotFound = "ERR_FILE_NOT_FOUND"
    static let fileNotReadable = "ERR_FILE_NOT_READABLE"
    static let appNotRunning = "ERR_APP_NOT_RUNNING"
    static let activationFailed = "ERR_ACTIVATION_FAILED"
    static let focusLost = "ERR_FOCUS_LOST"
    static let dialogNotFound = "ERR_DIALOG_NOT_FOUND"
    static let gotoSheetNotFound = "ERR_GOTO_SHEET_NOT_FOUND"
    static let gotoSheetStuck = "ERR_GOTO_SHEET_STUCK"
    static let confirmButtonNotFound = "ERR_CONFIRM_BUTTON_NOT_FOUND"
    static let confirmButtonDisabled = "ERR_CONFIRM_BUTTON_DISABLED"
    static let dialogStillOpen = "ERR_DIALOG_STILL_OPEN"
    static let eventPostFailed = "ERR_EVENT_POST_FAILED"
    static let noWindows = "ERR_NO_WINDOWS"
    static let elementNotFound = "ERR_ELEMENT_NOT_FOUND"
    static let elementStale = "ERR_ELEMENT_STALE"
    static let actionFailed = "ERR_ACTION_FAILED"
    static let internalError = "ERR_INTERNAL"
    static let elementNotVisible = "ERR_ELEMENT_NOT_VISIBLE"
    static let cdpNotEnabled = "ERR_CDP_NOT_ENABLED"
    static let cdpNotApproved = "ERR_CDP_NOT_APPROVED"
    static let cdpDisconnected = "ERR_CDP_DISCONNECTED"
    static let cdpTimeout = "ERR_CDP_TIMEOUT"
    static let cdpCommandFailed = "ERR_CDP_COMMAND_FAILED"
    static let tabNotFound = "ERR_TAB_NOT_FOUND"
    static let tabAmbiguous = "ERR_TAB_AMBIGUOUS"
    static let jsException = "ERR_JS_EXCEPTION"
    static let userTabProtected = "ERR_USER_TAB_PROTECTED"
    static let navigationFailed = "ERR_NAVIGATION_FAILED"
    static let tabHidden = "ERR_TAB_HIDDEN"
}

struct ToolError: Error {
    let code: String
    let detail: String
    var extra: [String: JSONValue] = [:]

    var payload: JSONValue {
        var o: [String: JSONValue] = ["ok": false, "error_code": .string(code), "error_detail": .string(detail)]
        for (k, v) in extra where o[k] == nil { o[k] = v }
        return .object(o)
    }

    static func invalid(_ detail: String) -> ToolError { ToolError(code: ErrorCode.invalidArgument, detail: detail) }
}

// MARK: - Argument parsing

struct Args {
    let raw: [String: JSONValue]

    init(_ raw: [String: JSONValue] = [:]) { self.raw = raw }

    private func present(_ key: String) -> JSONValue? {
        guard let v = raw[key], v != .null else { return nil }
        return v
    }

    func string(_ key: String) throws -> String? {
        guard let v = present(key) else { return nil }
        guard case .string(let s) = v else { throw ToolError.invalid("'\(key)' must be a string") }
        return s
    }

    func requiredString(_ key: String) throws -> String {
        guard let s = try string(key), !s.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError.invalid("'\(key)' is required and must be a non-empty string")
        }
        return s
    }

    func bool(_ key: String, default def: Bool) throws -> Bool {
        guard let v = present(key) else { return def }
        guard case .bool(let b) = v else { throw ToolError.invalid("'\(key)' must be a boolean") }
        return b
    }

    func int(_ key: String, default def: Int, range: ClosedRange<Int>) throws -> Int {
        guard let v = present(key) else { return def }
        guard let i = v.intValue else { throw ToolError.invalid("'\(key)' must be an integer") }
        guard range.contains(i) else {
            throw ToolError.invalid("'\(key)' must be in \(range.lowerBound)...\(range.upperBound), got \(i)")
        }
        return i
    }

    func enumeration(_ key: String, allowed: [String], default def: String) throws -> String {
        guard let s = try string(key) else { return def }
        guard allowed.contains(s) else {
            throw ToolError.invalid("'\(key)' must be one of \(allowed.joined(separator: ", ")), got '\(s)'")
        }
        return s
    }
}

// MARK: - Registry

struct ToolDefinition {
    let name: String
    let description: String
    let inputSchema: JSONValue
    let handler: (Args) throws -> JSONValue

    var listing: JSONValue {
        ["name": .string(name), "description": .string(description), "inputSchema": inputSchema]
    }
}

final class ToolRegistry {
    let tools: [ToolDefinition]
    private let byName: [String: ToolDefinition]

    init(tools: [ToolDefinition]) {
        self.tools = tools
        self.byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static func makeDefault() -> ToolRegistry {
        ToolRegistry(tools: [
            HealthTool.definition,
            WindowsTool.definition,
            FileDialogTool.definition,
            SnapshotTool.definition,
            InteractTool.definition,
        ] + BrowserTools.definitions + BrowserActions.definitions)
    }

    func listJSON() -> JSONValue { .array(tools.map(\.listing)) }

    func has(_ name: String) -> Bool { byName[name] != nil }

    /// Returns nil for an unknown tool. Never throws: tool failures become structured payloads.
    func call(name: String, arguments: [String: JSONValue]) -> (payload: JSONValue, isError: Bool)? {
        guard let tool = byName[name] else { return nil }
        let start = Date()
        Poll.pump(0.005) // let NSWorkspace process pending app/focus notifications
        let outcome: (JSONValue, Bool)
        do {
            outcome = (try tool.handler(Args(arguments)), false)
        } catch let e as ToolError {
            outcome = (e.payload, true)
        } catch {
            outcome = (ToolError(code: ErrorCode.internalError, detail: "\(error)").payload, true)
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let code = outcome.0["error_code"]?.stringValue ?? "ok"
        Log.info("tools/call \(name) -> \(code) in \(ms)ms")
        return outcome
    }
}

// MARK: - Schema helpers

enum Schema {
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var o: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
        return .object(o)
    }

    static func string(_ description: String, enumValues: [String]? = nil, defaultValue: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let enumValues { o["enum"] = .array(enumValues.map { .string($0) }) }
        if let defaultValue { o["default"] = .string(defaultValue) }
        return .object(o)
    }

    static func bool(_ description: String, defaultValue: Bool) -> JSONValue {
        ["type": "boolean", "description": .string(description), "default": .bool(defaultValue)]
    }

    static func int(_ description: String, defaultValue: Int, min: Int, max: Int) -> JSONValue {
        ["type": "integer", "description": .string(description), "default": .int(defaultValue),
         "minimum": .int(min), "maximum": .int(max)]
    }
}
