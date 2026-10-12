import Foundation

/// Where a host name points: this Mac, its network, or the internet.
enum Hosts {
    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(normalized(host))
    }

    /// Loopback, `.local` names and private-network addresses.
    static func isLocal(_ host: String) -> Bool {
        let host = normalized(host)
        if isLoopback(host) || host == "0.0.0.0" || host.hasSuffix(".local") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 || octets[0] == 127 || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 172 && (16...31).contains(octets[1]))
    }

    /// A public DNS name: not an IP address, not a single label, not a local-only domain.
    static func isPublicName(_ host: String) -> Bool {
        let host = normalized(host)
        let localSuffixes = [".local", ".localhost", ".internal", ".lan", ".home.arpa"]
        let ipLiteral = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
        return host.contains(".") && !ipLiteral && !localSuffixes.contains { host.hasSuffix($0) }
    }

    private static func normalized(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
}
