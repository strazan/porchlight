#if DEBUG
import AppKit
import PorchlightCore
import SwiftUI

/// Renders every screen with sample data to PNGs, in light and dark, then quits.
///
///     PORCHLIGHT_SNAPSHOTS=/tmp/shots Porchlight.app/Contents/MacOS/Porchlight
///
/// For reviewing the design without clicking through the app. Never touches the real
/// settings, Keychain or relay.
@MainActor
enum Snapshots {
    static var requestedDirectory: URL? {
        ProcessInfo.processInfo.environment["PORCHLIGHT_SNAPSHOTS"].map { URL(fileURLWithPath: $0) }
    }

    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Controls draw in their active colors only in the active app.
        NSApp.activate()
        let only = ProcessInfo.processInfo.environment["PORCHLIGHT_SNAPSHOTS_ONLY"]
        Task {
            if ProcessInfo.processInfo.environment["PORCHLIGHT_SNAPSHOTS_ONLINE"] != nil { await prefetchIcons() }
            for shot in catalog() where only.map({ shot.name.contains($0) }) ?? true {
                for dark in [false, true] {
                    render(shot, dark: dark, into: directory)
                }
            }
            exit(0)
        }
    }

    struct Shot {
        let name: String
        let scenario: AppModel.SampleScenario
        /// Nil: size to fit.
        let size: CGSize?
        let view: AnyView
    }

    private static func catalog() -> [Shot] {
        let obsidian = sample(.everything).servers[0]
        let github = sample(.everything).servers[2]
        let chatgpt = sample(.everything).clients[1]
        func shot(_ name: String, _ scenario: AppModel.SampleScenario, _ size: CGSize? = nil, _ view: some View) -> Shot {
            Shot(name: name, scenario: scenario, size: size, view: AnyView(view))
        }
        return [
            shot("menu", .everything, nil, MenuContent()),
            shot("menu-first-run", .firstRun, nil, MenuContent()),
            shot("menu-waiting", .waitingForToolApproval, nil, MenuContent()),
            shot("menu-off", .switchedOff, nil, MenuContent()),
            shot("settings-servers", .everything, nil, SettingsView(tab: .servers)),
            shot("settings-servers-empty", .firstRun, nil, SettingsView(tab: .servers)),
            shot("settings-apps", .everything, nil, SettingsView(tab: .apps)),
            shot("settings-relay", .everything, nil, SettingsView(tab: .relay)),
            shot("settings-relay-first-run", .firstRun, nil, SettingsView(tab: .relay)),
            shot("settings-general", .everything, nil, SettingsView(tab: .general)),
            shot("editor-new", .everything, nil, ServerEditor(server: ServerConfig(name: "", command: ""), isNew: true)),
            shot("editor-command", .everything, nil, ServerEditor(server: github, isNew: false)),
            shot("editor-url", .everything, nil, ServerEditor(server: obsidian, isNew: false)),
            shot("tool-permissions", .everything, nil, ToolPermissionsView(config: obsidian, policy: .constant(obsidian.toolPolicy))),
            shot("import", .everything, nil, ImportView()),
            shot("access", .everything, nil, AccessEditor(client: chatgpt)),
            shot("prompt-approval", .waitingForToolApproval, nil, PromptView()),
            shot("prompt-pairing", .waitingForPairing, nil, PromptView()),
            shot("activity", .everything, CGSize(width: 820, height: 340), ActivityView()),
            shot("logs", .everything, CGSize(width: 780, height: 300), LogsView()),
            shot("deploy-token", .firstRun, nil, DeployView()),
            shot("deploy-progress", .firstRun, nil, DeployView(stage: .deploying(.upload))),
            shot("deploy-done", .firstRun, nil, DeployView(stage: .done(URL(string: "https://porchlight-relay.sigge.workers.dev")!))),
        ]
    }

    /// Loads the sample apps' and servers' real icons before rendering.
    private static func prefetchIcons() async {
        for scenario in [AppModel.SampleScenario.everything, .waitingForToolApproval, .waitingForPairing] {
            let model = sample(scenario)
            for client in model.clients {
                await model.icons.load(key: IconStore.key(app: client.clientID), defaultWebsite: client.clientDomain)
            }
            for request in model.pendingPairings {
                if let domain = request.clientDomain { model.icons.learnWebsite(domain, for: IconStore.key(app: request.clientID)) }
                await model.icons.load(key: IconStore.key(app: request.clientID), defaultWebsite: request.clientDomain)
            }
            for server in model.servers {
                await model.icons.load(key: IconStore.key(server: server), defaultWebsite: ServerIconHint.domain(for: server))
            }
        }
    }

    private static var models: [String: AppModel] = [:]

    /// One isolated model per scenario: throwaway defaults and server store.
    private static func sample(_ scenario: AppModel.SampleScenario) -> AppModel {
        let key = "\(scenario)"
        if let model = models[key] { return model }
        let suite = "porchlight.snapshots.\(key)"
        UserDefaults().removePersistentDomain(forName: suite)
        let store = ServerStore(url: FileManager.default.temporaryDirectory.appending(path: "porchlight-snapshots/\(key).json"))
        let model = AppModel(defaults: UserDefaults(suiteName: suite)!, store: store, preview: true)
        model.loadSampleData(scenario)
        models[key] = model
        return model
    }

    private static func render(_ shot: Shot, dark: Bool, into directory: URL) {
        let model = sample(shot.scenario)
        let root = shot.view
            .environment(model)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        let size = shot.size ?? hosting.fittingSize
        let window = KeyWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.makeKeyAndOrderFront(nil)
        // Let SwiftUI lay out, load lists and run onAppear tasks.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        let file = directory.appending(path: "\(shot.name)\(dark ? "-dark" : "").png")
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }
}
/// Controls draw as active only in the key window.
private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
#endif
