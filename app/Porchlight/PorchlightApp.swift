import PorchlightCore
import SwiftUI

@main
struct PorchlightApp: App {
    @State private var model: AppModel

    init() {
        #if DEBUG
        if let directory = Snapshots.requestedDirectory {
            // Render the design snapshots instead of running (and touch nothing real).
            let defaults = UserDefaults(suiteName: "porchlight.snapshots") ?? .standard
            _model = State(initialValue: AppModel(defaults: defaults, store: ServerStore(url: URL(fileURLWithPath: "/dev/null")), sampleMode: true))
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
            Image(systemName: model.state.menuBarSymbol)
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
}
