import Foundation
import PorchlightCore

// Turning Porchlight on and off, and what the relay tells it.
extension AppModel {
    func setOn(_ on: Bool) {
        if on { Task { await start() } } else { stop() }
    }

    func start() async {
        guard state == .off, let url = hostURL else { return }
        state = .starting
        log("Resolving shell environment…")
        let environment = await ShellEnvironment.resolve()
        shellEnvironment = environment
        guard state == .starting else { return } // switched off meanwhile

        let router = Router(
            environment: environment,
            log: { [weak self] server, line in
                Task { @MainActor in self?.log(line, server: server) }
            },
            onStatus: { [weak self] server, status in
                Task { @MainActor in self?.serverStatus[server] = status }
            },
            approve: { [weak self] request in
                await self?.requestApproval(request) ?? .deny
            },
            onActivity: { [weak self] event in
                Task { @MainActor in self?.recordActivity(event) }
            }
        )
        await router.apply(servers)
        await router.setClientAccess(clientAccess)
        await router.warmUp()
        let client = RelayClient(
            url: url,
            secret: secret,
            handler: router,
            appVersion: "app-\(Porchlight.version)",
            queueKey: queueKey(),
            ledger: QueueLedger(file: Self.supportDirectory.appending(path: "queue-finished.json")) { [weak self] line in
                Task { @MainActor in self?.log(line) }
            },
            onStatus: { [weak self] status in
                Task { @MainActor in self?.relayStatusChanged(status) }
            },
            onEvent: { [weak self] event in
                Task { @MainActor in self?.relayEvent(event) }
            }
        )
        self.router = router
        self.client = client
        runner = Task { await client.run() }
        power.hold(keepAwake)
        log("Connecting to \(relayURL)")
    }

    func stop() {
        runner?.cancel()
        runner = nil
        routerSync?.cancel()
        catalogPush?.cancel()
        catalogClients = []
        if let router { Task { await router.stopAll() } }
        router = nil
        client = nil
        serverStatus = [:]
        clients = []
        prompts.clear()
        power.hold(false)
        if state != .off { log("Stopped") }
        state = .off
    }

    func restart() {
        stop()
        Task { await start() }
    }

    func connectivityChanged() {
        guard let client else { return }
        log("Network changed or Mac woke up; reconnecting")
        Task { await client.reconnectNow() }
    }

    private func relayEvent(_ event: RelayEvent) {
        switch event {
        case .pairingRequested(let request):
            // Anyone can ask to connect, so nothing is fetched for a request (like its icon)
            // until it's approved.
            log("\(request.clientName) wants to connect (code \(request.formattedCode))")
            prompts.add(request)
        case .clientsChanged(let clients):
            self.clients = clients.sorted { $0.createdAt > $1.createdAt }
            lockUnknownApps()
            scheduleCatalogPush()
        case .queuedFinished(let item, let outcome):
            queuedFinished(item, outcome)
        }
    }

    private func relayStatusChanged(_ status: RelayClient.Status) {
        guard runner != nil else { return } // a late update after stop()
        state = .relay(status)
        switch status {
        case .connecting: break
        case .connected:
            log("Relay connected")
            scheduleCatalogPush()
            toolsRevision += 1
        case .disconnected(let reason): log("Relay disconnected: \(reason)")
        }
    }

    /// Sends a relay message, noting in the log if it couldn't (Porchlight is off or offline).
    func send(_ what: String, _ message: @escaping @Sendable (RelayClient) async -> Bool) {
        guard let client else { return log("Couldn't \(what): Porchlight isn't connected") }
        Task {
            if await !message(client) { log("Couldn't \(what): the relay connection dropped") }
        }
    }
}
