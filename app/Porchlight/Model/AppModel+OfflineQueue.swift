import Foundation
import PorchlightCore

// Keeping apps working while the Mac is offline: what the relay may answer and save for them,
// and what ran when the Mac came back.
extension AppModel {
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Porchlight")
    }

    /// The key the relay seals requests to while the Mac is offline, made once and kept in
    /// the Keychain. (Losing it only loses what's queued at the time.)
    func queueKey() -> QueueKey {
        if let saved = secrets.read(SecretAccount.queueKey).flatMap({ Data(base64Encoded: $0) }),
           let key = try? QueueKey(rawRepresentation: saved) {
            return key
        }
        let key = QueueKey()
        if !secrets.write(SecretAccount.queueKey, key.rawRepresentation.base64EncodedString()) {
            log("Couldn't save the offline queue's key in the Keychain: requests saved while the Mac is off may be lost")
        }
        return key
    }

    /// Tells the relay, for each app, what it sees and may queue while the Mac is offline.
    /// Debounced: servers, permissions and access often change several times in a row.
    func scheduleCatalogPush() {
        guard let router, let client, isConnected else { return }
        let current = Set(clients.map(\.clientID)).subtracting([""])
        let gone = catalogClients.subtracting(current)
        catalogPush?.cancel()
        catalogPush = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            for id in gone { await client.sendOfflineCatalog(clientID: id, catalog: nil) }
            for id in current.sorted() {
                let catalog = await router.offlineCatalog(for: id)
                guard !Task.isCancelled else { return }
                await client.sendOfflineCatalog(clientID: id, catalog: catalog)
            }
            catalogClients = current
        }
    }

    /// Logs a queued request's outcome, and sums up a batch of them in one notification.
    func queuedFinished(_ item: QueuedRequest, _ outcome: QueuedOutcome) {
        let age = item.queuedAt.formatted(.relative(presentation: .named))
        switch outcome {
        case .ran: log("Ran a request \(item.clientName) made \(age), while the Mac was offline")
        case .failed: log("A request \(item.clientName) made \(age), while the Mac was offline, didn't go through")
        case .unreadable: log("Couldn't read a request \(item.clientName) made \(age) (sealed to an earlier key); skipped")
        }
        queuedSummary.append((item.clientName, outcome))
        queuedNotice?.cancel()
        queuedNotice = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            let summary = queuedSummary
            queuedSummary = []
            QueuedNotice.post(summary)
        }
    }
}
