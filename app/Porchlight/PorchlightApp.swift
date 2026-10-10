import SwiftUI

@main
struct PorchlightApp: App {
    @State private var model = AppModel()

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

        Window("Porchlight Logs", id: "logs") {
            LogsView().environment(model)
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
