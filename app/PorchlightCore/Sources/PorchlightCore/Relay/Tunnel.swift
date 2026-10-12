import Foundation

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
