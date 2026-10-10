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

/// An app asking to connect through the relay, awaiting the owner's decision.
public struct PairingRequest: Sendable, Identifiable, Equatable {
    public let id: String
    /// Also shown on the app's consent page, so the owner can match the two.
    public let code: String
    public let clientName: String
    /// The client's verified domain (for Client ID Metadata Document clients).
    public let clientDomain: String?
    /// Where the tokens will be sent.
    public let redirectHost: String
    /// The tokens go to an app on the owner's computer.
    public let loopback: Bool

    public init(id: String, code: String, clientName: String, clientDomain: String?, redirectHost: String, loopback: Bool) {
        self.id = id
        self.code = code
        self.clientName = clientName
        self.clientDomain = clientDomain
        self.redirectHost = redirectHost
        self.loopback = loopback
    }

    /// `482 913`
    public var formattedCode: String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }
}

/// A client that has been granted access.
public struct PairedClient: Sendable, Identifiable, Equatable {
    /// The grant's id, used to revoke it.
    public let id: String
    public let clientID: String
    public let clientName: String
    public let clientDomain: String?
    public let createdAt: Date
}

/// Things the relay tells the host, other than tunneled requests.
public enum RelayEvent: Sendable {
    case pairingRequested(PairingRequest)
    case clientsChanged([PairedClient])
}

enum RelayFrame {
    case req(HTTPRequest)
    case cancel(id: String)
    case event(RelayEvent)
    case pong
    case unknown

    static func decode(_ text: String) -> RelayFrame {
        if text == RelayProtocol.pong { return .pong }
        guard let msg = try? JSONValue.parse(Data(text.utf8)), let type = msg["type"]?.stringValue else { return .unknown }
        switch type {
        case "req":
            guard let id = msg["id"]?.stringValue,
                  let method = msg["method"]?.stringValue,
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
            guard let id = msg["id"]?.stringValue else { return .unknown }
            return .cancel(id: id)
        case "pair_request":
            guard let id = msg["id"]?.stringValue,
                  let code = msg["code"]?.stringValue,
                  let name = msg["client_name"]?.stringValue,
                  let redirectHost = msg["redirect_host"]?.stringValue
            else { return .unknown }
            return .event(.pairingRequested(PairingRequest(
                id: id, code: code, clientName: name, clientDomain: msg["client_domain"]?.stringValue,
                redirectHost: redirectHost, loopback: msg["loopback"] == .bool(true)
            )))
        case "clients":
            guard case .array(let items)? = msg["items"] else { return .unknown }
            let clients = items.compactMap { item -> PairedClient? in
                guard let grantID = item["grant_id"]?.stringValue, let clientID = item["client_id"]?.stringValue else { return nil }
                let created: Double = switch item["created_at"] {
                case .int(let i)?: Double(i)
                case .double(let d)?: d
                default: 0
                }
                return PairedClient(
                    id: grantID, clientID: clientID,
                    clientName: item["client_name"]?.stringValue ?? clientID,
                    clientDomain: item["client_domain"]?.stringValue,
                    createdAt: Date(timeIntervalSince1970: created)
                )
            }
            return .event(.clientsChanged(clients))
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

    static func pairDecision(id: String, allow: Bool) -> String {
        encode(["type": .string("pair_decision"), "id": .string(id), "allow": .bool(allow)])
    }

    static let listClients = #"{"type":"list_clients"}"#

    static func revokeClient(grantID: String) -> String {
        encode(["type": .string("revoke_client"), "grant_id": .string(grantID)])
    }

    private static func encode(_ object: [String: JSONValue]) -> String {
        String(decoding: JSONValue.object(object).serialized(), as: UTF8.self)
    }
}
