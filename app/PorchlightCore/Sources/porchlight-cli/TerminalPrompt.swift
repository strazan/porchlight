import Foundation
import PorchlightCore

/// One question at a time on the terminal; no terminal (or end of input) means no.
actor TerminalPrompt {
    func ask(_ question: String) async -> String {
        stderrLog(question)
        FileHandle.standardError.write(Data("> ".utf8))
        let answer = await Task.detached { readLine() }.value
        return answer?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    }
}

/// The queue key in `path`, made and saved there (readable only by you) if it's missing.
func loadQueueKey(_ path: String) -> QueueKey {
    let url = URL(fileURLWithPath: path)
    if let saved = try? Data(contentsOf: url), let key = try? QueueKey(rawRepresentation: saved) { return key }
    let key = QueueKey()
    guard FileManager.default.createFile(atPath: url.path, contents: key.rawRepresentation, attributes: [.posixPermissions: 0o600]) else {
        fail("couldn't write the queue key to \(path)")
    }
    return key
}
