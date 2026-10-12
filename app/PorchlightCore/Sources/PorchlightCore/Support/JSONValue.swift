import Foundation

/// An arbitrary JSON value. Integers are kept apart from doubles so JSON-RPC ids
/// round-trip exactly.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        get {
            if case .object(let o) = self { return o[key] }
            return nil
        }
        set {
            if case .object(var o) = self {
                o[key] = newValue
                self = .object(o)
            }
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int64? {
        if case .int(let i) = self { return i }
        return nil
    }

    /// A number as a double, whether JSON wrote it with a fraction or not.
    var numberValue: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func serialized() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        // Encoding a JSONValue cannot fail: every case maps to valid JSON.
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }
}

// MARK: - JSON-RPC

extension JSONValue {
    public var rpcMethod: String? { self["method"]?.stringValue }
    public var rpcID: JSONValue? { self["id"] }
    var isRequest: Bool { rpcMethod != nil && rpcID != nil }
    var isNotification: Bool { rpcMethod != nil && rpcID == nil }
    var isResponse: Bool { rpcMethod == nil && rpcID != nil }

    /// A request. Without an `id`, for an upstream to send under its own.
    static func rpcRequest(_ method: String, id: JSONValue? = nil, params: [String: JSONValue]? = nil) -> JSONValue {
        var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let id { message["id"] = id }
        if let params { message["params"] = .object(params) }
        return .object(message)
    }

    static func rpcResult(id: JSONValue? = nil, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id ?? .null, "result": result])
    }

    static func rpcError(id: JSONValue?, code: RPCErrorCode, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id ?? .null,
            "error": .object(["code": .int(code.rawValue), "message": .string(message)]),
        ])
    }

    /// A `tools/call` result with one text block. With `isError`, the model reads why the call failed.
    static func toolResult(id: JSONValue?, _ text: String, isError: Bool) -> JSONValue {
        rpcResult(id: id, .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError),
        ]))
    }

    /// Why a response is a failure: its JSON-RPC error, or the text of a tool result marked
    /// `isError`. Nil when it succeeded.
    var failure: String? {
        if let error = self["error"] { return error["message"]?.stringValue ?? "Error" }
        guard self["result"]?["isError"] == .bool(true) else { return nil }
        if case .array(let content)? = self["result"]?["content"], let text = content.first?["text"]?.stringValue { return text }
        return "The tool reported an error"
    }
}

/// JSON-RPC's error codes, and the MCP ones Porchlight uses.
enum RPCErrorCode: Int64 {
    case parseError = -32700
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
    case requestCancelled = -32800
    case resourceNotFound = -32002
}
