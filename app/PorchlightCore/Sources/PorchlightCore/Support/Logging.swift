import Foundation

public typealias LogSink = @Sendable (String) -> Void

public let stderrLog: LogSink = { line in
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

/// A command line for logs, with what looks like a credential masked: the value after a flag
/// like `--api-key`, `--token=…`, and the query of any URL.
public func loggableCommandLine(_ command: [String]) -> String {
    let sensitive = /(?i)(key|token|secret|passw|auth|credential|bearer)/
    var masked: [String] = []
    var maskNext = false
    for arg in command {
        defer { maskNext = arg.hasPrefix("-") && !arg.contains("=") && arg.contains(sensitive) }
        if maskNext {
            masked.append("***")
        } else if arg.hasPrefix("-"), let eq = arg.firstIndex(of: "="), arg[..<eq].contains(sensitive) {
            masked.append(String(arg[...eq]) + "***")
        } else {
            masked.append(shellQuoted(loggableURL(arg)))
        }
    }
    return masked.joined(separator: " ")
}

/// A URL for logs, without its query (where tokens often go) or password.
public func loggableURL(_ string: String) -> String {
    guard var parts = URLComponents(string: string), parts.scheme != nil, parts.host != nil,
          parts.query != nil || parts.password != nil
    else { return string }
    if parts.query != nil { parts.percentEncodedQuery = "***" }
    if parts.password != nil { parts.percentEncodedPassword = "***" }
    return parts.string ?? string
}
