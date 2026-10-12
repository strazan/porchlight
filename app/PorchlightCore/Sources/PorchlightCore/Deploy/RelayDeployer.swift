import Foundation

/// The relay Worker as built by `npm run bundle` in relay/.
public struct RelayBundle: Sendable {
    let module: Data
    let mainModule: String
    /// What wrangler would send with the script (see relay/scripts/bundle.mjs): bindings
    /// still missing the KV namespace id and the secret's value, and the first migration.
    let metadata: JSONValue
    /// Identifies this build, to tell whether a deployed relay is out of date.
    public let sha256: String

    /// Loads `relay-worker.js` and `relay-bundle.json` from `bundle`'s resources.
    public init(bundle: Bundle) throws {
        guard let moduleURL = bundle.url(forResource: "relay-worker", withExtension: "js"),
              let manifestURL = bundle.url(forResource: "relay-bundle", withExtension: "json")
        else { throw DeployError.bundleMissing }
        try self.init(module: Data(contentsOf: moduleURL), manifest: JSONValue.parse(Data(contentsOf: manifestURL)))
    }

    init(module: Data, manifest: JSONValue) throws {
        guard let main = manifest["main_module"]?.stringValue,
              manifest["compatibility_date"]?.stringValue != nil,
              case .array = manifest["bindings"],
              let sha = manifest["sha256"]?.stringValue
        else { throw DeployError.bundleMissing }
        self.module = module
        mainModule = main
        metadata = manifest
        sha256 = sha
    }
}

/// Deploys the relay to a Cloudflare account, or updates it in place.
public struct RelayDeployer: Sendable {
    public enum Step: Int, Sendable, CaseIterable, Comparable {
        case subdomain
        case storage
        case upload
        case route
        case live

        public var title: String {
            switch self {
            case .subdomain: "Finding your workers.dev subdomain"
            case .storage: "Setting up storage for logins"
            case .upload: "Uploading the relay"
            case .route: "Publishing it on workers.dev"
            case .live: "Waiting for it to come online"
            }
        }

        public static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public static let defaultScriptName = "porchlight-relay"
    static let kvTitle = "porchlight-relay-oauth"

    private let api: CloudflareAPI
    private let bundle: RelayBundle
    private let session: URLSession

    public init(api: CloudflareAPI, bundle: RelayBundle, session: URLSession = .shared) {
        self.api = api
        self.bundle = bundle
        self.session = session
    }

    /// Deploys (or updates) the relay and returns its public URL once it answers.
    public func deploy(
        account: String,
        scriptName: String = defaultScriptName,
        hostSecret: String,
        liveTimeout: Duration = .seconds(120),
        progress: @Sendable (Step) -> Void = { _ in }
    ) async throws -> URL {
        progress(.subdomain)
        guard let subdomain = try await api.workersSubdomain(account: account) else { throw DeployError.noWorkersSubdomain }

        progress(.storage)
        let kv: CloudflareAPI.KVNamespace
        if let existing = try await api.kvNamespaces(account: account).first(where: { $0.title == Self.kvTitle }) {
            kv = existing
        } else {
            kv = try await api.createKVNamespace(account: account, title: Self.kvTitle)
        }

        progress(.upload)
        let exists = try await api.scriptNames(account: account).contains(scriptName)
        try await api.uploadScript(
            account: account,
            name: scriptName,
            module: bundle.module,
            moduleName: bundle.mainModule,
            metadata: metadata(kvNamespace: kv.id, hostSecret: hostSecret, firstDeploy: !exists)
        )

        progress(.route)
        try await api.enableWorkersDev(account: account, script: scriptName)

        progress(.live)
        guard let url = URL(string: "https://\(scriptName).\(subdomain).workers.dev") else { throw DeployError.noWorkersSubdomain }
        try await waitUntilLive(url, timeout: liveTimeout)
        return url
    }

    func metadata(kvNamespace: String, hostSecret: String, firstDeploy: Bool) -> JSONValue {
        let manifest = bundle.metadata
        var bindings: [JSONValue] = []
        if case .array(let declared)? = manifest["bindings"] {
            for var binding in declared {
                switch binding["type"]?.stringValue {
                case "kv_namespace": binding["namespace_id"] = .string(kvNamespace)
                case "secret_text": binding["text"] = .string(hostSecret)
                default: break
                }
                bindings.append(binding)
            }
        }
        var metadata: [String: JSONValue] = [
            "main_module": .string(bundle.mainModule),
            "compatibility_date": manifest["compatibility_date"] ?? .null,
            "compatibility_flags": manifest["compatibility_flags"] ?? .array([]),
            "bindings": .array(bindings),
            "observability": manifest["observability"] ?? .object(["enabled": .bool(false)]),
        ]
        // Migrations only apply when the script is created; updates keep its Durable Objects.
        if firstDeploy, let migration = manifest["migration"] { metadata["migrations"] = migration }
        return .object(metadata)
    }

    /// A new workers.dev route (and especially a new subdomain) takes a moment to resolve.
    func waitUntilLive(_ url: URL, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        let health = url.appending(path: "health")
        while ContinuousClock.now < deadline {
            if let (data, response) = try? await session.data(from: health),
               (response as? HTTPURLResponse)?.statusCode == 200,
               (try? JSONValue.parse(data))?["ok"] == .bool(true) {
                return
            }
            try await Task.sleep(for: min(.seconds(2), deadline - ContinuousClock.now))
        }
        throw DeployError.notLive(url)
    }
}

public enum DeployError: LocalizedError, Equatable {
    case bundleMissing
    case noWorkersSubdomain
    case notLive(URL)

    public var errorDescription: String? {
        switch self {
        case .bundleMissing: "The relay isn't bundled with this build of Porchlight."
        case .noWorkersSubdomain: "This account hasn't chosen a workers.dev subdomain yet."
        case .notLive(let url): "The relay was deployed but \(url.host() ?? "it") isn't answering yet. New workers.dev subdomains can take a few minutes; try again shortly."
        }
    }
}
