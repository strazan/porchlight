import Foundation

/// The relay Worker as built by `npm run bundle` in relay/.
public struct RelayBundle: Sendable {
    public let module: Data
    public let mainModule: String
    public let compatibilityDate: String
    public let compatibilityFlags: [String]
    public let durableObjectClasses: [String]
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
              let date = manifest["compatibility_date"]?.stringValue,
              let sha = manifest["sha256"]?.stringValue
        else { throw DeployError.bundleMissing }
        self.module = module
        mainModule = main
        compatibilityDate = date
        sha256 = sha
        compatibilityFlags = if case .array(let flags)? = manifest["compatibility_flags"] { flags.compactMap(\.stringValue) } else { [] }
        durableObjectClasses = if case .array(let classes)? = manifest["durable_object_classes"] { classes.compactMap(\.stringValue) } else { [] }
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
        agentSecret: String,
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
            metadata: metadata(kvNamespace: kv.id, agentSecret: agentSecret, firstDeploy: !exists)
        )

        progress(.route)
        try await api.enableWorkersDev(account: account, script: scriptName)

        progress(.live)
        let url = URL(string: "https://\(scriptName).\(subdomain).workers.dev")!
        try await waitUntilLive(url, timeout: liveTimeout)
        return url
    }

    func metadata(kvNamespace: String, agentSecret: String, firstDeploy: Bool) -> JSONValue {
        var metadata: [String: JSONValue] = [
            "main_module": .string(bundle.mainModule),
            "compatibility_date": .string(bundle.compatibilityDate),
            "compatibility_flags": .array(bundle.compatibilityFlags.map(JSONValue.string)),
            "bindings": .array([
                .object(["type": .string("durable_object_namespace"), "name": .string("HUB"), "class_name": .string("Hub")]),
                .object(["type": .string("kv_namespace"), "name": .string("OAUTH_KV"), "namespace_id": .string(kvNamespace)]),
                .object(["type": .string("secret_text"), "name": .string("AGENT_SECRET"), "text": .string(agentSecret)]),
            ]),
            "observability": .object(["enabled": .bool(true)]),
        ]
        // The relay has one migration so far; it only applies when the script is created.
        if firstDeploy {
            metadata["migrations"] = .object([
                "new_tag": .string("v1"),
                "new_sqlite_classes": .array(bundle.durableObjectClasses.map(JSONValue.string)),
            ])
        }
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
