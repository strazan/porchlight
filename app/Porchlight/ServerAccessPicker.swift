import SwiftUI

/// Chooses which servers an app may use: all of them (including ones added later), or a
/// selection. `selection` is nil for all.
struct ServerAccessPicker: View {
    let servers: [String]
    @Binding var selection: Set<String>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Access", selection: Binding(
                get: { selection == nil },
                set: { all in selection = all ? nil : Set(servers) }
            )) {
                Text("All servers").tag(true)
                Text("Only some").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let chosen = selection {
                if servers.isEmpty {
                    Text("No servers yet.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(servers, id: \.self) { server in
                    Toggle(server, isOn: Binding(
                        get: { chosen.contains(server) },
                        set: { on in selection = on ? chosen.union([server]) : chosen.subtracting([server]) }
                    ))
                    .toggleStyle(.checkbox)
                }
                if chosen.isEmpty {
                    Text("It won't be able to use any server.").font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("Including servers you add later.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
