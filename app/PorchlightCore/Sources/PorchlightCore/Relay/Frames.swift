import Foundation

// Wire protocol between the relay and this Mac (the host). See protocol/PROTOCOL.md.

enum RelayProtocol {
    static let version = 1
    // Exact strings: the relay answers pings without waking its Durable Object.
    static let ping = #"{"type":"ping"}"#
    static let pong = #"{"type":"pong"}"#

    // Who sent a tunneled request, set by the relay from its OAuth (percent-encoded). The
    // relay drops any `porchlight-*` header an app sends, so apps can't set these.
    static let clientIDHeader = "porchlight-client-id"
    static let clientNameHeader = "porchlight-client-name"
    /// Set on requests saved while the Mac was offline, when they're run (see `RelayClient`).
    static let queuedAtHeader = "porchlight-queued-at"
}

enum RelayFrame {
    case req(HTTPRequest)
    case queued(QueuedRequest)
    case cancel(id: String)
    case event(RelayEvent)
    case pong
    case unknown

    static func decode(_ text: String) -> RelayFrame {
        if text == RelayProtocol.pong { return .pong }
        guard let frame = try? JSONValue.parse(Data(text.utf8)), let type = frame["type"]?.stringValue else { return .unknown }
        switch type {
        case "req":
            guard let id = frame["id"]?.stringValue,
                  let method = frame["method"]?.stringValue,
                  let path = frame["path"]?.stringValue,
                  let body = frame["body_b64"]?.stringValue.flatMap({ Data(base64Encoded: $0) }),
                  case .array(let rawHeaders)? = frame["headers"]
            else { return .unknown }
            let headers: HeaderList = rawHeaders.compactMap {
                guard case .array(let pair) = $0, pair.count == 2,
                      let name = pair[0].stringValue, let value = pair[1].stringValue
                else { return nil }
                return (name, value)
            }
            return .req(HTTPRequest(id: id, method: method, path: path, headers: headers, body: body))
        case "cancel":
            guard let id = frame["id"]?.stringValue else { return .unknown }
            return .cancel(id: id)
        case "queued":
            guard let id = frame["id"]?.stringValue,
                  let path = frame["path"]?.stringValue,
                  let sealed = frame["sealed"]?.stringValue.flatMap({ Data(base64Encoded: $0) })
            else { return .unknown }
            return .queued(QueuedRequest(
                id: id, clientID: frame["client_id"]?.stringValue ?? "", clientName: frame["client_name"]?.stringValue ?? "",
                path: path, queuedAt: Date(timeIntervalSince1970: (frame["queued_at"]?.numberValue ?? 0) / 1000), sealed: sealed
            ))
        case "pair_request":
            guard let id = frame["id"]?.stringValue,
                  let code = frame["code"]?.stringValue,
                  let name = frame["client_name"]?.stringValue,
                  let redirectHost = frame["redirect_host"]?.stringValue
            else { return .unknown }
            return .event(.pairingRequested(PairingRequest(
                id: id, code: code, clientID: frame["client_id"]?.stringValue ?? "",
                clientName: name, clientDomain: frame["client_domain"]?.stringValue,
                redirectHost: redirectHost, loopback: frame["loopback"] == .bool(true)
            )))
        case "clients":
            guard case .array(let items)? = frame["items"] else { return .unknown }
            let clients = items.compactMap { item -> PairedClient? in
                guard let grantID = item["grant_id"]?.stringValue, let clientID = item["client_id"]?.stringValue else { return nil }
                return PairedClient(
                    id: grantID, clientID: clientID,
                    clientName: item["client_name"]?.stringValue ?? clientID,
                    clientDomain: item["client_domain"]?.stringValue,
                    createdAt: Date(timeIntervalSince1970: item["created_at"]?.numberValue ?? 0)
                )
            }
            return .event(.clientsChanged(clients))
        default:
            return .unknown
        }
    }
}

enum HostFrame {
    static func hello(appVersion: String, queueKey: String? = nil) -> String {
        var frame: [String: JSONValue] = ["type": .string("hello"), "proto": .int(Int64(RelayProtocol.version)), "app_version": .string(appVersion)]
        if let queueKey { frame["queue_key"] = .string(queueKey) }
        return encode(frame)
    }

    /// `catalog` nil: forget what this app sees offline.
    static func offlineCatalog(clientID: String, catalog: JSONValue?) -> String {
        encode(["type": .string("offline_catalog"), "client_id": .string(clientID), "catalog": catalog ?? .null])
    }

    static func queuedDone(id: String) -> String {
        encode(["type": .string("queued_done"), "id": .string(id)])
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
