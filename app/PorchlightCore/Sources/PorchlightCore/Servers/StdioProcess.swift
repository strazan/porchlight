import Foundation

/// A child MCP server speaking newline-delimited JSON-RPC over stdin/stdout.
///
/// `@unchecked Sendable`: `Process` and `Pipe` aren't marked Sendable, but after `init` they're
/// only touched through thread-safe calls, and writes are serialized by `writeLock`.
final class StdioProcess: @unchecked Sendable {
    /// Messages the child writes to stdout. Finishes when stdout closes.
    let messages: AsyncStream<JSONValue>

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let continuation: AsyncStream<JSONValue>.Continuation
    private let writeLock = NSLock()
    private let log: LogSink

    init(command: [String], environment: [String: String]? = nil, log: @escaping LogSink = stderrLog) {
        precondition(!command.isEmpty, "command must not be empty")
        self.log = log
        (messages, continuation) = AsyncStream.makeStream(of: JSONValue.self)
        // `env` does the PATH lookup, so `npx`, `uvx` etc. resolve like in a shell.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        if let environment { process.environment = environment }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    var isRunning: Bool { process.isRunning }

    /// Waits for the process to exit and returns its status. Its stdout can close a moment
    /// before it's reaped, so don't read the status right at end of output.
    func exitStatus() async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.process.waitUntilExit()
                continuation.resume(returning: self.process.terminationStatus)
            }
        }
    }

    /// A child that exits while we write to it must not kill us with SIGPIPE.
    private static let ignoreBrokenPipes: Void = { signal(SIGPIPE, SIG_IGN) }()

    func start() throws {
        Self.ignoreBrokenPipes

        let continuation = self.continuation
        let log = self.log
        let lines = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in lines.append(data) where !line.isEmpty {
                if let message = try? JSONValue.parse(line) {
                    continuation.yield(message)
                } else {
                    log("stdout (not JSON): \(String(decoding: line, as: UTF8.self))")
                }
            }
        }
        let stderrLines = LineBuffer()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for line in stderrLines.append(data) { log(String(decoding: line, as: UTF8.self)) }
        }
        process.terminationHandler = { process in
            log("exited with status \(process.terminationStatus)")
        }
        try process.run()
    }

    func send(_ message: JSONValue) throws {
        var line = message.serialized()
        line.append(0x0A)
        writeLock.lock()
        defer { writeLock.unlock() }
        try stdin.fileHandleForWriting.write(contentsOf: line)
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

/// Splits a byte stream into lines. Only used from one readability handler at a time.
private final class LineBuffer: @unchecked Sendable {
    private var buffer = Data()

    func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            lines.append(Data(line))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }
}
