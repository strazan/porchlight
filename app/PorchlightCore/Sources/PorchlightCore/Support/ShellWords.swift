import Foundation

/// Quotes an argument for display, only if it needs it.
func shellQuoted(_ arg: String) -> String {
    let safe = arg.allSatisfy { $0.isLetter || $0.isNumber || "-_./:@=+,~%".contains($0) }
    if safe, !arg.isEmpty { return arg }
    return "'" + arg.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

/// Splits a command line into arguments, honoring single quotes, double quotes and
/// backslash escapes, the way a shell would (without expansion).
public func splitCommandLine(_ line: String) -> [String] {
    var args: [String] = []
    var current = ""
    var inArg = false
    var quote: Character?
    var escaped = false
    for ch in line {
        if escaped {
            current.append(ch)
            escaped = false
        } else if ch == "\\" && quote != "'" {
            escaped = true
            inArg = true
        } else if let q = quote {
            if ch == q { quote = nil } else { current.append(ch) }
        } else if ch == "'" || ch == "\"" {
            quote = ch
            inArg = true
        } else if ch.isWhitespace {
            if inArg {
                args.append(current)
                current = ""
                inArg = false
            }
        } else {
            current.append(ch)
            inArg = true
        }
    }
    if inArg { args.append(current) }
    return args
}
