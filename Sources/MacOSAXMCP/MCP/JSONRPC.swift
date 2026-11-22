import Foundation

// MARK: - JSONValue

/// A fully Codable, order-independent JSON value used for params, results and tool payloads.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d.isFinite ? d : 0)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && abs(d) < 9.0e15: return Int(d)
        default: return nil
        }
    }

    // MARK: Serialization helpers

    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
                                    : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// Single-line compact JSON (JSONEncoder escapes control characters, so no raw newlines).
    func compactString() -> String {
        guard let data = try? JSONValue.encoder().encode(self),
              let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }

    func prettyString() -> String {
        guard let data = try? JSONValue.encoder(pretty: true).encode(self),
              let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }

    static func parse(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
                     ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    // Deliberately NOT ExpressibleByNilLiteral: it would silently turn `nil` into `.null` inside
    // `JSONValue?` expressions (e.g. a missing request id would look like an explicit null id).
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
}

// MARK: - JSON-RPC 2.0 models

enum RPCErrorCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}

struct RPCErrorObject: Codable, Error, Equatable {
    let code: Int
    let message: String
    var data: JSONValue?
}

struct RPCRequest: Decodable {
    let jsonrpc: String
    let method: String
    /// `nil` means the key was absent (notification). `.null` means an explicit null id.
    let id: JSONValue?
    let params: JSONValue?

    var isNotification: Bool { id == nil }

    enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try c.decode(String.self, forKey: .jsonrpc)
        method = try c.decode(String.self, forKey: .method)
        id = c.contains(.id) ? try c.decode(JSONValue.self, forKey: .id) : nil
        params = try c.decodeIfPresent(JSONValue.self, forKey: .params)
    }
}

struct RPCResponse: Encodable {
    let jsonrpc = "2.0"
    let id: JSONValue
    let result: JSONValue?
    let error: RPCErrorObject?

    static func success(id: JSONValue, result: JSONValue) -> RPCResponse {
        RPCResponse(id: id, result: result, error: nil)
    }

    static func failure(id: JSONValue, code: Int, message: String, data: JSONValue? = nil) -> RPCResponse {
        RPCResponse(id: id, result: nil, error: RPCErrorObject(code: code, message: message, data: data))
    }
}
