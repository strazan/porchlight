import Foundation
import PorchlightCore

// Apps: answering their requests, what they may use, and revoking them.
extension AppModel {
    /// An app with access, and its connections (e.g. one per connector it added).
    struct ConnectedApp: Identifiable {
        let connections: [PairedClient]
        var id: String { latest.clientID }
        var latest: PairedClient { connections[0] }
    }

    /// Apps with access, newest first. Grouped by client ID, which is also what access is set by.
    var apps: [ConnectedApp] {
        var order: [String] = []
        var byClient: [String: [PairedClient]] = [:]
        for client in clients {
            if byClient[client.clientID] == nil { order.append(client.clientID) }
            byClient[client.clientID, default: []].append(client)
        }
        return order.compactMap { byClient[$0].map(ConnectedApp.init) }
    }

    /// The servers an app may use, or nil if it may use all of them.
    func access(for clientID: String) -> Set<String>? {
        clientAccess[clientID]
    }

    func setAccess(clientID: String, servers: Set<String>?) {
        clientAccess[clientID] = servers
    }

    /// Where an app's icon comes from unless overridden: its verified domain.
    func defaultIconWebsite(forApp clientID: String) -> String? {
        clients.first { $0.clientID == clientID }?.clientDomain
    }

    // MARK: Answering

    func requestApproval(_ request: ToolApprovalRequest) async -> ToolApproval {
        log("\(request.client.name) wants to run \(request.tool) on \(request.server)")
        return await prompts.approval(for: request)
    }

    func answer(_ request: ToolApprovalRequest, with approval: ToolApproval) {
        guard prompts.resolve(request, with: approval) else { return }
        if approval == .allowAlways, var server = servers.first(where: { $0.name == request.server }) {
            server.toolPolicy.overrides[request.tool] = .allow
            update(server)
            log("Always allowing \(request.tool) on \(request.server)")
        }
    }

    /// `servers`: when allowing, the servers the app may use, or nil for all of them.
    func answer(_ request: PairingRequest, allow: Bool, servers: Set<String>? = nil) {
        prompts.remove(request)
        if allow {
            setAccess(clientID: request.clientID, servers: servers)
            // Where its access goes is a good place to find its icon (an app on this Mac isn't).
            if let website = request.clientDomain ?? (request.loopback ? nil : request.redirectHost) {
                icons.learnWebsite(website, for: IconStore.key(app: request.clientID))
            }
        }
        log("\(allow ? "Approved" : "Denied") \(request.clientName)")
        send("answer \(request.clientName)") { await $0.decidePairing(request.id, allow: allow) }
    }

    func showPendingPrompt() {
        promptPanel.update(focus: true)
    }

    // MARK: Revoking

    /// Revokes every connection the app has.
    func revoke(_ app: ConnectedApp) {
        log("Revoked \(app.latest.clientName)")
        // No servers rather than no setting (which means all), in case a connection outlives
        // the revoke. Approving the app again sets its access afresh.
        clientAccess[app.id] = []
        for grant in app.connections.map(\.id) {
            send("revoke \(app.latest.clientName)") { await $0.revokeClient(grant) }
        }
    }

    /// Asks the relay for the current list of apps.
    func refreshClients() {
        guard let client else { return }
        Task { await client.refreshClients() }
    }

    /// After switching to another relay (or deploying from a new Mac), apps connected before
    /// have no access settings here, which would mean all servers. They start with none.
    func lockUnknownApps() {
        guard defaults.bool(forKey: "lockUnknownApps") else { return }
        defaults.set(false, forKey: "lockUnknownApps")
        let unknown = Set(clients.map(\.clientID)).subtracting(clientAccess.keys)
        guard !unknown.isEmpty else { return }
        for clientID in unknown { clientAccess[clientID] = [] }
        let apps = unknown.count == 1 ? "An app" : "\(unknown.count) apps"
        log("\(apps) connected to this relay before can't use any servers until you choose in Settings → Apps")
    }
}
