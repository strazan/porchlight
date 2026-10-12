import Foundation

/// Who sent a request, as the relay identified them (see `RelayProtocol` for the headers).
public struct ClientIdentity: Sendable, Equatable {
    /// The OAuth client ID. Empty for requests that didn't come through the relay's OAuth.
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name.displayName()
    }

    init(headers request: HTTPRequest) {
        let decode = { (name: String) in request.header(name).flatMap { $0.removingPercentEncoding } ?? "" }
        let name = decode(RelayProtocol.clientNameHeader)
        self.init(id: decode(RelayProtocol.clientIDHeader), name: name.isEmpty ? "Unknown app" : name)
    }
}

extension String {
    /// Apps name themselves when they register. This keeps a name to one plain line, so it
    /// can't fake a second line ("Published by…") or reorder text with direction overrides.
    func displayName(limit: Int = 80) -> String {
        var plain = ""
        var space = false
        for scalar in unicodeScalars {
            // Invisible formatting (direction overrides, zero-width spaces) goes; breaks become spaces.
            if scalar.properties.generalCategory == .format { continue }
            if scalar.properties.generalCategory == .control || scalar.properties.isWhitespace {
                space = !plain.isEmpty
            } else {
                if space { plain.unicodeScalars.append(" ") }
                plain.unicodeScalars.append(scalar)
                space = false
            }
        }
        return plain.count > limit ? String(plain.prefix(limit)) : plain
    }
}
