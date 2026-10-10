import Foundation

/// The environment a login shell would have.
///
/// Apps launched from Finder get a minimal PATH, so `npx`, `uvx`, Homebrew binaries
/// and the like wouldn't be found. Running the user's shell once fixes that.
public enum ShellEnvironment {
    public static func resolve(timeout: TimeInterval = 5) async -> [String: String] {
        let base = ProcessInfo.processInfo.environment
        let shell = base["SHELL"] ?? "/bin/zsh"
        let marker = "__PORCHLIGHT_ENV__"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -i too: many people set PATH in .zshrc, which only interactive shells read.
        process.arguments = ["-l", "-i", "-c", "printf '\(marker)'; /usr/bin/env -0"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return base
        }
        let output = await withTaskGroup(of: Data?.self) { group in
            group.addTask { stdout.fileHandleForReading.readDataToEndOfFile() }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            if first == nil, process.isRunning { process.terminate() }
            group.cancelAll()
            return first
        }
        guard let output else { return base }
        return base.merging(parse(output, after: marker)) { _, shell in shell }
    }

    static func parse(_ data: Data, after marker: String) -> [String: String] {
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: marker, options: .backwards) else { return [:] }
        var environment: [String: String] = [:]
        for entry in text[range.upperBound...].split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return environment
    }
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
