import Foundation

/// The queued requests this Mac has finished, so one delivered again (the relay resends
/// until it hears back) never runs twice. Keeps the most recent ones, in a file if given.
public final class QueueLedger: Sendable {
    static let limit = 500

    private let file: URL?
    private let log: LogSink
    private let finished: Locked<[String]>

    public init(file: URL? = nil, log: @escaping LogSink = stderrLog) {
        self.file = file
        self.log = log
        var saved: [String] = []
        if let file, FileManager.default.fileExists(atPath: file.path) {
            do {
                saved = try JSONDecoder().decode([String].self, from: Data(contentsOf: file))
            } catch {
                log("Couldn't read the list of finished queued requests (\(error.localizedDescription)); starting a new one")
            }
        }
        finished = Locked(saved)
    }

    public func contains(_ id: String) -> Bool {
        finished.withLock { $0.contains(id) }
    }

    public func add(_ id: String) {
        let snapshot = finished.withLock { ids -> [String] in
            guard !ids.contains(id) else { return ids }
            ids.append(id)
            if ids.count > Self.limit { ids.removeFirst(ids.count - Self.limit) }
            return ids
        }
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        } catch {
            log("Couldn't save the list of finished queued requests: \(error.localizedDescription)")
        }
    }
}
