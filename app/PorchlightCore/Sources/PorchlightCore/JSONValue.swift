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

// MARK: - JSON-RPC helpers

extension JSONValue {
    public var rpcMethod: String? { self["method"]?.stringValue }
    public var rpcID: JSONValue? { self["id"] }
    public var isRequest: Bool { rpcMethod != nil && rpcID != nil }
    public var isNotification: Bool { rpcMethod != nil && rpcID == nil }
    public var isResponse: Bool { rpcMethod == nil && rpcID != nil }

    public static func rpcError(id: JSONValue?, code: Int64, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id ?? .null,
            "error": .object(["code": .int(code), "message": .string(message)]),
        ])
    }
}
