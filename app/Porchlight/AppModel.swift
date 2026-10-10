import Foundation
import Observation
import PorchlightCore

struct LogLine: Identifiable {
    let id: Int
    let date: Date
    let text: String
}

@MainActor @Observable
final class AppModel {
    enum State: Equatable {
        case off
        case starting
        case relay(RelayClient.Status)
    }

    var relayURL: String { didSet { defaults.set(relayURL, forKey: "relayURL") } }
    var serverName: String { didSet { defaults.set(serverName, forKey: "serverName") } }
    var serverCommand: String { didSet { defaults.set(serverCommand, forKey: "serverCommand") } }
    var secret: String { didSet { Keychain.write("agentSecret", secret) } }

    private(set) var state: State = .off
    private(set) var logs: [LogLine] = []

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var bridge: StdioBridge?
    @ObservationIgnored private var nextLogID = 0
    private static let maxLogLines = 2000

    init() {
        relayURL = defaults.string(forKey: "relayURL") ?? "http://localhost:8787"
        serverName = defaults.string(forKey: "serverName") ?? "everything"
        serverCommand = defaults.string(forKey: "serverCommand") ?? "npx -y @modelcontextprotocol/server-everything"
        secret = Keychain.read("agentSecret") ?? ""
        if isConfigured { Task { await start() } }
    }

    var isConfigured: Bool {
        !secret.isEmpty && agentURL != nil && !splitCommandLine(serverCommand).isEmpty
    }

    var isOn: Bool { state != .off }

    var isConnected: Bool { state == .relay(.connected) }

    /// The URL to give MCP clients.
    var endpoint: String {
        var base = relayURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        return base + "/mcp"
    }

    var serverEndpoint: String {
        endpoint.replacingOccurrences(of: "/mcp", with: "/s/\(serverName)/mcp", options: .backwards)
    }

    var statusText: String {
        switch state {
        case .off: "Off"
        case .starting, .relay(.connecting): "Connecting…"
        case .relay(.connected): "Connected"
        case .relay(.disconnected(let reason)): reason
        }
    }

    /// The relay's WebSocket endpoint, derived from its public URL.
    var agentURL: URL? {
        guard var components = URLComponents(string: relayURL.trimmingCharacters(in: .whitespaces)) else { return nil }
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        guard components.host != nil else { return nil }
        components.path = "/agent"
        return components.url
    }

    func setOn(_ on: Bool) {
        if on { Task { await start() } } else { stop() }
    }

    func start() async {
        guard state == .off, let url = agentURL else { return }
        let command = splitCommandLine(serverCommand)
        guard !command.isEmpty else { return }
        state = .starting
        log("Resolving shell environment…")
        let environment = await ShellEnvironment.resolve()
        guard state == .starting else { return } // switched off meanwhile

        let sink: LogSink = { [weak self] line in
            Task { @MainActor in self?.log(line) }
        }
        let bridge = StdioBridge(name: serverName, command: command, environment: environment, log: sink)
        let client = RelayClient(url: url, secret: secret, handler: bridge, appVersion: "app-0.0.1") { [weak self] status in
            Task { @MainActor in self?.relayStatusChanged(status) }
        }
        self.bridge = bridge
        runner = Task { await client.run() }
        log("Serving \(serverName) via \(relayURL)")
    }

    func stop() {
        runner?.cancel()
        runner = nil
        if let bridge { Task { await bridge.stop() } }
        bridge = nil
        if state != .off { log("Stopped") }
        state = .off
    }

    func restart() {
        stop()
        Task { await start() }
    }

    func clearLogs() {
        logs.removeAll()
    }

    private func relayStatusChanged(_ status: RelayClient.Status) {
        guard runner != nil else { return } // a late update after stop()
        state = .relay(status)
        switch status {
        case .connecting: break
        case .connected: log("Relay connected")
        case .disconnected(let reason): log("Relay disconnected: \(reason)")
        }
    }

    private func log(_ text: String) {
        logs.append(LogLine(id: nextLogID, date: Date(), text: text))
        nextLogID += 1
        if logs.count > Self.maxLogLines { logs.removeFirst(logs.count - Self.maxLogLines) }
    }
}
