import Foundation

/// The parts of the Cloudflare v4 API needed to deploy a relay.
public struct CloudflareAPI: Sendable {
    public struct Account: Sendable, Identifiable, Hashable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    struct KVNamespace: Sendable, Hashable {
        let id: String
        let title: String
    }

    // The trailing slash matters: relative paths resolve under v4/, not in place of it.
    private static let base = URL(string: "https://api.cloudflare.com/client/v4/")!

    private let token: String
    private let session: URLSession

    public init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    /// The template for a token with just the permissions Porchlight needs.
    public static let createTokenURL: URL = {
        let permissions = #"[{"key":"workers_scripts","type":"edit"},{"key":"workers_kv_storage","type":"edit"},{"key":"account_settings","type":"read"}]"#
        var components = URLComponents(string: "https://dash.cloudflare.com/profile/api-tokens")!
        components.queryItems = [
            URLQueryItem(name: "permissionGroupKeys", value: permissions),
            URLQueryItem(name: "accountId", value: "*"),
            URLQueryItem(name: "zoneId", value: "all"),
            URLQueryItem(name: "name", value: "Porchlight"),
        ]
        return components.url!
    }()

    public func verifyToken() async throws {
        let result = try await call("GET", "user/tokens/verify")
        guard result["status"]?.stringValue == "active" else { throw CloudflareError.tokenInactive }
    }

    public func accounts() async throws -> [Account] {
        try await list("accounts", perPage: 50).compactMap { item in
            guard let id = item["id"]?.stringValue else { return nil }
            return Account(id: id, name: item["name"]?.stringValue ?? id)
        }
    }

    /// The account's `<subdomain>.workers.dev`, or nil if it hasn't chosen one yet.
    public func workersSubdomain(account: String) async throws -> String? {
        do {
            return try await call("GET", "accounts/\(account)/workers/subdomain")["subdomain"]?.stringValue
        } catch CloudflareError.api(let errors) where errors.contains(where: { $0.code == 10007 }) {
            return nil
        }
    }

    public func createWorkersSubdomain(account: String, name: String) async throws -> String {
        let result = try await call("PUT", "accounts/\(account)/workers/subdomain", json: .object(["subdomain": .string(name)]))
        return result["subdomain"]?.stringValue ?? name
    }

    func kvNamespaces(account: String) async throws -> [KVNamespace] {
        try await list("accounts/\(account)/storage/kv/namespaces", perPage: 100).compactMap { item in
            guard let id = item["id"]?.stringValue, let title = item["title"]?.stringValue else { return nil }
            return KVNamespace(id: id, title: title)
        }
    }

    func createKVNamespace(account: String, title: String) async throws -> KVNamespace {
        let result = try await call("POST", "accounts/\(account)/storage/kv/namespaces", json: .object(["title": .string(title)]))
        guard let id = result["id"]?.stringValue else { throw CloudflareError.unexpectedResponse("KV namespace without an id") }
        return KVNamespace(id: id, title: title)
    }

    func scriptNames(account: String) async throws -> Set<String> {
        guard case .array(let items) = try await call("GET", "accounts/\(account)/workers/scripts") else { return [] }
        return Set(items.compactMap { $0["id"]?.stringValue })
    }

    /// Uploads an ES module Worker with its metadata (bindings, migrations, …).
    func uploadScript(account: String, name: String, module: Data, moduleName: String, metadata: JSONValue) async throws {
        var form = MultipartForm()
        form.append(name: "metadata", contentType: "application/json", data: metadata.serialized())
        form.append(name: moduleName, filename: moduleName, contentType: "application/javascript+module", data: module)
        _ = try await call("PUT", "accounts/\(account)/workers/scripts/\(name)", body: form.body, contentType: form.contentType)
    }

    func enableWorkersDev(account: String, script: String) async throws {
        _ = try await call(
            "POST", "accounts/\(account)/workers/scripts/\(script)/subdomain",
            json: .object(["enabled": .bool(true), "previews_enabled": .bool(false)])
        )
    }

    // MARK: Transport

    private func call(_ method: String, _ path: String, json: JSONValue? = nil) async throws -> JSONValue {
        try await call(method, path, body: json?.serialized(), contentType: json == nil ? nil : "application/json")
    }

    private func call(_ method: String, _ path: String, body: Data?, contentType: String?) async throws -> JSONValue {
        try await send(method, path, body: body, contentType: contentType)["result"] ?? .null
    }

    /// Every item of a paged list.
    private func list(_ path: String, perPage: Int) async throws -> [JSONValue] {
        var items: [JSONValue] = []
        for page in 1... {
            let envelope = try await send("GET", "\(path)?per_page=\(perPage)&page=\(page)", body: nil, contentType: nil)
            guard case .array(let batch)? = envelope["result"] else { break }
            items += batch
            let pages = envelope["result_info"]?["total_pages"]?.intValue ?? 1
            if batch.isEmpty || page >= pages { break }
        }
        return items
    }

    /// The whole response envelope (`result`, `result_info`, …), once Cloudflare reports success.
    private func send(_ method: String, _ path: String, body: Data?, contentType: String?) async throws -> JSONValue {
        guard let url = URL(string: path, relativeTo: Self.base) else { throw CloudflareError.unexpectedResponse("bad path \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let envelope = try? JSONValue.parse(data) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CloudflareError.unexpectedResponse("HTTP \(status)")
        }
        guard envelope["success"] == .bool(true) else {
            var errors: [CloudflareError.Message] = []
            if case .array(let items)? = envelope["errors"] {
                errors = items.map {
                    CloudflareError.Message(code: Int($0["code"]?.intValue ?? 0), message: $0["message"]?.stringValue ?? "Unknown error")
                }
            }
            throw CloudflareError.api(errors)
        }
        return envelope
    }
}

public enum CloudflareError: LocalizedError, Equatable {
    public struct Message: Sendable, Equatable {
        public let code: Int
        public let message: String
    }

    case api([Message])
    case tokenInactive
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .api(let messages) where messages.isEmpty: "Cloudflare refused the request."
        case .api(let messages): messages.map { "\($0.message) (\($0.code))" }.joined(separator: "; ")
        case .tokenInactive: "This API token isn't active."
        case .unexpectedResponse(let detail): "Unexpected response from Cloudflare: \(detail)"
        }
    }
}

/// A `multipart/form-data` body.
struct MultipartForm {
    let boundary = "porchlight-\(UUID().uuidString)"
    private var parts = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// The body, closing boundary included.
    var body: Data { parts + Data("--\(boundary)--\r\n".utf8) }

    mutating func append(name: String, filename: String? = nil, contentType: String, data: Data) {
        var disposition = #"Content-Disposition: form-data; name="\#(name)""#
        if let filename { disposition += #"; filename="\#(filename)""# }
        parts.append(Data("--\(boundary)\r\n\(disposition)\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        parts.append(data)
        parts.append(Data("\r\n".utf8))
    }
}
