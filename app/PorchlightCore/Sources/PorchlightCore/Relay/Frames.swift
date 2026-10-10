import Foundation

// Wire protocol between the relay and this host. See protocol/PROTOCOL.md.

public enum RelayProtocol {
    public static let version = 1
    // Exact strings: the relay answers pings without waking its Durable Object.
    public static let ping = #"{"type":"ping"}"#
    public static let pong = #"{"type":"pong"}"#
}

public typealias HeaderList = [(name: String, value: String)]

/// An HTTP request tunneled from the relay.
public struct HTTPRequest: Sendable {
    public var id: String
    public var method: String
    public var path: String
    public var headers: HeaderList
    public var body: Data

    public init(id: String, method: String, path: String, headers: HeaderList = [], body: Data = Data()) {
        self.id = id
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The path without its query string.
    public var route: String {
        path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
    }
}

/// Writes one HTTP response back through the relay: `start`, any `chunk`s, then `end`.
public struct HTTPResponder: Sendable {
    public let start: @Sendable (_ status: Int, _ headers: HeaderList) async -> Void
    public let chunk: @Sendable (_ data: Data) async -> Void
    public let end: @Sendable () async -> Void

    public init(
        start: @escaping @Sendable (Int, HeaderList) async -> Void,
        chunk: @escaping @Sendable (Data) async -> Void,
        end: @escaping @Sendable () async -> Void
    ) {
        self.start = start
        self.chunk = chunk
        self.end = end
    }

    public func respond(_ status: Int, _ headers: HeaderList = [], body: Data = Data()) async {
        await start(status, headers)
        if !body.isEmpty { await chunk(body) }
        await end()
    }
}

/// Anything that can answer tunneled HTTP requests.
public protocol HTTPHandler: Sendable {
    func handle(_ request: HTTPRequest, _ responder: HTTPResponder) async
}

enum RelayFrame {
    case req(HTTPRequest)
    case cancel(id: String)
    case pong
    case unknown

    static func decode(_ text: String) -> RelayFrame {
        if text == RelayProtocol.pong { return .pong }
        guard let msg = try? JSONValue.parse(Data(text.utf8)),
              let type = msg["type"]?.stringValue,
              let id = msg["id"]?.stringValue
        else { return .unknown }
        switch type {
        case "req":
            guard let method = msg["method"]?.stringValue,
                  let path = msg["path"]?.stringValue,
                  let b64 = msg["body_b64"]?.stringValue,
                  let body = Data(base64Encoded: b64),
                  case .array(let rawHeaders)? = msg["headers"]
            else { return .unknown }
            let headers: HeaderList = rawHeaders.compactMap {
                guard case .array(let pair) = $0, pair.count == 2,
                      let name = pair[0].stringValue, let value = pair[1].stringValue
                else { return nil }
                return (name, value)
            }
            return .req(HTTPRequest(id: id, method: method, path: path, headers: headers, body: body))
        case "cancel":
            return .cancel(id: id)
        default:
            return .unknown
        }
    }
}

enum HostFrame {
    static func hello(appVersion: String) -> String {
        encode(["type": .string("hello"), "proto": .int(Int64(RelayProtocol.version)), "app_version": .string(appVersion)])
    }

    static func resStart(id: String, status: Int, headers: HeaderList) -> String {
        encode([
            "type": .string("res_start"),
            "id": .string(id),
            "status": .int(Int64(status)),
            "headers": .array(headers.map { .array([.string($0.name), .string($0.value)]) }),
        ])
    }

    static func resChunk(id: String, data: Data) -> String {
        encode(["type": .string("res_chunk"), "id": .string(id), "data_b64": .string(data.base64EncodedString())])
    }

    static func resEnd(id: String) -> String {
        encode(["type": .string("res_end"), "id": .string(id)])
    }

    private static func encode(_ object: [String: JSONValue]) -> String {
        String(decoding: JSONValue.object(object).serialized(), as: UTF8.self)
    }
}
