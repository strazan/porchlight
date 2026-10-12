import Foundation
import PorchlightCore

let options = Options(CommandLine.arguments.dropFirst())
let servers = options.servers()

if options.checkOnly {
    var failed = false
    for server in servers where server.enabled {
        switch await ServerProbe.run(server, environment: ProcessInfo.processInfo.environment) {
        case .success(let found): print("✓ \(server.name): \(found.serverName), \(found.tools.count) tools")
        case .failure(let error):
            failed = true
            print("✗ \(server.name): \(error.message)")
        }
    }
    exit(failed ? 1 : 0)
}

guard options.relay != nil else { fail("--relay is required") }
guard let relayURL = options.hostURL() else { fail("invalid relay URL \(options.relay ?? "")") }
guard let secret = ProcessInfo.processInfo.environment["PORCHLIGHT_SECRET"], !secret.isEmpty else {
    fail("PORCHLIGHT_SECRET is not set")
}

let prompt = TerminalPrompt()
let router = Router(
    environment: ProcessInfo.processInfo.environment,
    approve: { request in
        let answer = await prompt.ask("""

            \(request.client.name) wants to run \(request.tool) on \(request.server) with:
            \(String(decoding: request.arguments.serialized(), as: UTF8.self))
            Allow? [y]es / [N]o / [a]lways for this tool
            """)
        switch answer {
        case "a", "always":
            stderrLog("allowing \(request.tool) for the rest of this session")
            return .allowAlways
        case "y", "yes": return .allowOnce
        default: return .deny
        }
    }
)
await router.apply(servers)
for server in servers where server.enabled {
    stderrLog("serving \(server.name): \(server.transport == .http ? loggableURL(server.url) : loggableCommandLine(server.commandLine))")
}

let queueKey = options.queueKey.map(loadQueueKey)

let (events, eventSink) = AsyncStream.makeStream(of: RelayEvent.self)
let client = RelayClient(
    url: relayURL,
    secret: secret,
    handler: router,
    appVersion: "cli-\(Porchlight.version)",
    queueKey: queueKey,
    ledger: QueueLedger(file: options.queueKey.map { URL(fileURLWithPath: $0 + ".finished.json") }),
    onStatus: { status in
        switch status {
        case .connecting: stderrLog("relay: connecting to \(relayURL.absoluteString)")
        case .connected: stderrLog("relay: connected")
        case .disconnected(let reason): stderrLog("relay: disconnected (\(reason))")
        }
    },
    onEvent: { eventSink.yield($0) }
)

// Apps connecting through the relay need the owner's approval: ask on the terminal.
Task {
    for await event in events {
        switch event {
        case .pairingRequested(let request):
            let origin = request.clientDomain.map { "published by \($0)" } ?? "unverified name"
            let answer = await prompt.ask("""

                \(request.clientName) (\(origin)) wants to connect; access goes to \(request.redirectHost).
                Check that the browser shows code \(request.formattedCode).
                Allow? [y/N]
                """)
            let allow = answer.hasPrefix("y")
            await client.decidePairing(request.id, allow: allow)
            stderrLog(allow ? "approved \(request.clientName)" : "denied \(request.clientName)")
        case .clientsChanged(let clients):
            let names = clients.map(\.clientName)
            stderrLog("apps with access: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
            // What each app sees, and may queue, while this Mac is offline.
            guard queueKey != nil else { continue }
            for clientID in Set(clients.map(\.clientID)) where !clientID.isEmpty {
                await client.sendOfflineCatalog(clientID: clientID, catalog: await router.offlineCatalog(for: clientID))
            }
            stderrLog("offline catalogs sent")
        case .queuedFinished(let item, let outcome):
            stderrLog("queued request from \(item.clientName), made \(item.queuedAt.formatted(.relative(presentation: .named))): \(outcome)")
        }
    }
}

let runner = Task { await client.run() }

// On Ctrl-C or SIGTERM, stop serving; the child servers are stopped below.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let signals = [SIGINT, SIGTERM].map { sig in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { @Sendable in runner.cancel() }
    source.resume()
    return source
}

// Top-level code is async (it awaits above), so the main queue is already serviced and
// dispatchMain() would trap. Instead, wait here until a signal cancels the runner.
await runner.value
await router.stopAll()
