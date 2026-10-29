import PorchlightCore
import SwiftUI

/// A per-connection allowlist. Loading a catalog never selects anything automatically.
struct LoanToolPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: [String: Set<String>]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Allowed tools").font(.callout.weight(.medium))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.servers.filter { $0.enabled || selection[$0.name]?.isEmpty == false }) { server in
                        LoanServerTools(server: server, selection: $selection)
                    }
                    if model.servers.isEmpty {
                        Text("Add a server in Settings → Servers first.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 190)
            Text("Unchecked and newly added tools stay blocked. Server blocks and approval prompts still apply. Resource and prompt endpoints aren’t shared.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LoanServerTools: View {
    @Environment(AppModel.self) private var model
    let server: ServerConfig
    @Binding var selection: [String: Set<String>]
    @State private var tools: [ToolSummary]?
    @State private var error: String?

    private var selected: Set<String> { selection[server.name] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(server.name).font(.callout.weight(.semibold))
            if let tools {
                if tools.isEmpty { Text("No tools available").font(.caption).foregroundStyle(.secondary) }
                ForEach(tools) { tool in
                    let blocked = server.toolPolicy.permission(for: tool.name, readOnly: tool.hints.readOnly) == .deny
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(isOn: binding(tool.name)) {
                            Text(tool.hints.title.map { "\($0) (\(tool.name))" } ?? tool.name)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(blocked && !selected.contains(tool.name))
                        if blocked {
                            Text("Blocked in the server’s settings").font(.caption).foregroundStyle(.secondary)
                        } else if let description = tool.description {
                            Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { Task { await load() } }
            } else {
                ProgressView("Loading tools…").controlSize(.small)
            }
            // Keep saved selections visible even if the server is unavailable or a tool disappeared.
            ForEach(selected.subtracting(Set((tools ?? []).map(\.name))).sorted(), id: \.self) { name in
                Toggle("\(name) (unavailable)", isOn: binding(name)).toggleStyle(.checkbox)
            }
        }
        .task(id: server) { await load() }
    }

    private func binding(_ name: String) -> Binding<Bool> {
        Binding(get: { selected.contains(name) }, set: { on in
            let updated = on ? selected.union([name]) : selected.subtracting([name])
            selection[server.name] = updated.isEmpty ? nil : updated
        })
    }

    private func load() async {
        error = nil
        switch await model.lendingTools(on: server) {
        case .success(let tools): self.tools = tools
        case .failure(let failure): error = failure.message
        }
    }
}
