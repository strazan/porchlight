import PorchlightCore
import SwiftUI

@main
struct PorchlightApp: App {
    @State private var model: AppModel

    init() {
        #if DEBUG
        if let directory = Snapshots.requestedDirectory {
            // Render the design snapshots instead of running (and touch nothing real).
            _model = State(initialValue: AppModel(defaults: UserDefaults(suiteName: "porchlight.snapshots")!, store: ServerStore(url: URL(fileURLWithPath: "/dev/null")), preview: true))
            DispatchQueue.main.async { Snapshots.run(into: directory) }
            return
        }
        #endif
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environment(model)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Window("Porchlight Settings", id: "settings") {
            SettingsView().environment(model)
        }
        .windowResizability(.contentSize)

        Window("Activity", id: "activity") {
            ActivityView().environment(model)
        }
    }

    /// A porch light: on when connected, dim while trying, crossed out on failure.
    private var menuBarSymbol: String {
        switch model.state {
        case .off: "lightbulb"
        case .starting, .relay(.connecting): "lightbulb.min"
        case .relay(.connected): "lightbulb.fill"
        case .relay(.disconnected): "lightbulb.slash"
        }
    }
}
