import Foundation
import Testing
@testable import PorchlightCore

/// A fake Cloudflare API: records requests and answers from `respond`.
final class StubCloudflare: URLProtocol, @unchecked Sendable {
    struct Recorded {
        let method: String
        let path: String
        let body: Data
        let contentType: String?
    }

    nonisolated(unsafe) static var respond: (_ method: String, _ path: String) -> (Int, String) = { _, _ in (404, "{}") }
    static let requests = Locked<[Recorded]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let path = url.path.replacingOccurrences(of: "/client/v4/", with: "") + (url.query.map { "?\($0)" } ?? "")
        let method = request.httpMethod ?? "GET"
        Self.requests.withLock {
            $0.append(Recorded(method: method, path: path, body: Self.body(of: request), contentType: request.value(forHTTPHeaderField: "Content-Type")))
        }
        let (status, body) = Self.respond(method, path)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands uploads to protocols as a stream.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubCloudflare.self]
        return URLSession(configuration: configuration)
    }
}

func ok(_ result: String) -> (Int, String) { (200, #"{"success":true,"errors":[],"result":\#(result)}"#) }

let testBundle = try! RelayBundle(
    module: Data("export default {}".utf8),
    manifest: try! JSONValue.parse(Data(#"{"main_module":"worker.js","compatibility_date":"2026-10-01","compatibility_flags":["global_fetch_strictly_public"],"durable_object_classes":["Hub"],"sha256":"abc"}"#.utf8))
)

/// Tests share the stub's static state, so they run one at a time.
@Suite(.serialized) struct DeployTests {
    init() {
        StubCloudflare.requests.withLock { $0.removeAll() }
    }

    func deployer() -> RelayDeployer {
        let session = StubCloudflare.session
        return RelayDeployer(api: CloudflareAPI(token: "t", session: session), bundle: testBundle, session: session)
    }

    @Test func firstDeployCreatesEverything() async throws {
        StubCloudflare.respond = { method, path in
            switch (method, path) {
            case ("GET", "accounts/acc/workers/subdomain"): ok(#"{"subdomain":"sigge"}"#)
            case ("GET", "accounts/acc/storage/kv/namespaces?per_page=100"): ok("[]")
            case ("POST", "accounts/acc/storage/kv/namespaces"): ok(#"{"id":"kv1","title":"porchlight-relay-oauth"}"#)
            case ("GET", "accounts/acc/workers/scripts"): ok("[]")
            case ("PUT", "accounts/acc/workers/scripts/porchlight-relay"): ok("{}")
            case ("POST", "accounts/acc/workers/scripts/porchlight-relay/subdomain"): ok(#"{"enabled":true}"#)
            default: (404, #"{"success":false,"errors":[{"code":0,"message":"unexpected \#(method) \#(path)"}]}"#)
            }
        }
        let steps = Locked<[RelayDeployer.Step]>([])
        // The relay never comes online here; a short timeout keeps the test fast.
        await #expect(throws: DeployError.self) {
            _ = try await deployer().deploy(account: "acc", hostSecret: "s3cret", liveTimeout: .milliseconds(10)) { step in
                steps.withLock { $0.append(step) }
            }
        }
        #expect(steps.value == RelayDeployer.Step.allCases)

        let requests = StubCloudflare.requests.value
        let upload = try #require(requests.first { $0.method == "PUT" })
        #expect(upload.contentType?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = String(decoding: upload.body, as: UTF8.self)
        #expect(body.contains(#"name="worker.js"; filename="worker.js""#))
        #expect(body.contains("Content-Type: application/javascript+module"))
        #expect(body.contains("export default {}"))

        let metadata = try #require(multipartPart(named: "metadata", in: upload))
        #expect(metadata["main_module"] == .string("worker.js"))
        #expect(metadata["compatibility_flags"] == .array([.string("global_fetch_strictly_public")]))
        #expect(metadata["migrations"]?["new_sqlite_classes"] == .array([.string("Hub")]))
        guard case .array(let bindings)? = metadata["bindings"] else {
            Issue.record("no bindings")
            return
        }
        #expect(bindings.contains(.object(["type": .string("kv_namespace"), "name": .string("OAUTH_KV"), "namespace_id": .string("kv1")])))
        #expect(bindings.contains(.object(["type": .string("secret_text"), "name": .string("HOST_SECRET"), "text": .string("s3cret")])))
    }

    @Test func updatesReuseStorageAndSkipMigrations() async throws {
        StubCloudflare.respond = { method, path in
            switch (method, path) {
            case ("GET", "accounts/acc/workers/subdomain"): ok(#"{"subdomain":"sigge"}"#)
            case ("GET", "accounts/acc/storage/kv/namespaces?per_page=100"): ok(#"[{"id":"kv1","title":"porchlight-relay-oauth"}]"#)
            case ("GET", "accounts/acc/workers/scripts"): ok(#"[{"id":"porchlight-relay"}]"#)
            case ("PUT", _), ("POST", _): ok("{}")
            default: (404, #"{"success":false,"errors":[]}"#)
            }
        }
        _ = try? await deployer().deploy(account: "acc", hostSecret: "s", liveTimeout: .milliseconds(10))
        let requests = StubCloudflare.requests.value
        #expect(!requests.contains { $0.method == "POST" && $0.path.hasSuffix("kv/namespaces") })
        let upload = try #require(requests.first { $0.method == "PUT" })
        #expect(multipartPart(named: "metadata", in: upload)?["migrations"] == nil)
    }

    @Test func reportsAMissingWorkersSubdomain() async {
        StubCloudflare.respond = { _, _ in
            (404, #"{"success":false,"errors":[{"code":10007,"message":"workers.api.error.not_found"}]}"#)
        }
        await #expect(throws: DeployError.noWorkersSubdomain) {
            _ = try await deployer().deploy(account: "acc", hostSecret: "s", liveTimeout: .milliseconds(10))
        }
    }

    @Test func surfacesCloudflareErrors() async {
        StubCloudflare.respond = { _, _ in
            (403, #"{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}"#)
        }
        let api = CloudflareAPI(token: "bad", session: StubCloudflare.session)
        await #expect(throws: CloudflareError.api([.init(code: 10000, message: "Authentication error")])) {
            try await api.verifyToken()
        }
    }

    @Test func tokenTemplateNamesTheNeededPermissions() throws {
        let components = try #require(URLComponents(url: CloudflareAPI.createTokenURL, resolvingAgainstBaseURL: false))
        let permissions = try #require(components.queryItems?.first { $0.name == "permissionGroupKeys" }?.value)
        #expect(permissions.contains("workers_scripts"))
        #expect(permissions.contains("workers_kv_storage"))
    }
}

/// Parses one part of a recorded multipart body as JSON.
func multipartPart(named name: String, in request: StubCloudflare.Recorded) -> JSONValue? {
    let body = String(decoding: request.body, as: UTF8.self)
    guard let header = body.range(of: #"name="\#(name)""#),
          let start = body.range(of: "\r\n\r\n", range: header.upperBound..<body.endIndex),
          let end = body.range(of: "\r\n--", range: start.upperBound..<body.endIndex)
    else { return nil }
    return try? JSONValue.parse(Data(body[start.upperBound..<end.lowerBound].utf8))
}
