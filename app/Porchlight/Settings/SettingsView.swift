import PorchlightCore
import SwiftUI

struct SettingsView: View {
    enum Tab: Hashable, CaseIterable {
        case servers, apps, relay, general
    }

    @Environment(AppModel.self) private var model
    @State private var tab: Tab

    init(tab: Tab = .servers) {
        _tab = State(initialValue: tab)
    }

    var body: some View {
        TabView(selection: $tab) {
            ServersTab().tabItem { Label("Servers", systemImage: "server.rack") }.tag(Tab.servers)
            AppsTab().tabItem { Label("Apps", systemImage: "person.2") }.tag(Tab.apps)
            RelayTab().tabItem { Label("Relay", systemImage: "network") }.tag(Tab.relay)
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
        }
        .frame(width: 620, height: 480)
        .onAppear(perform: openRequestedTab)
        .onChange(of: model.requestedSettingsTab) { openRequestedTab() }
    }

    private func openRequestedTab() {
        if let requested = model.requestedSettingsTab {
            tab = requested
            model.requestedSettingsTab = nil
        }
    }
}
