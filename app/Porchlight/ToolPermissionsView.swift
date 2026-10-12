import PorchlightCore
import SwiftUI

/// Per-tool permissions for one server, edited in place on its policy.
struct ToolPermissionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let config: ServerConfig
    @Binding var policy: ToolPolicy
    @State private var tools: [ToolSummary]?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "Tools on \(config.name)",
                subtitle: "Tools left on Default follow the server's setting: \(policy.defaultPermission.title.lowercased()).",
                systemImage: "checklist"
            )
            .padding(20)

            Group {
                if let tools {
                    if tools.isEmpty {
                        ContentUnavailableView("No Tools", systemImage: "wrench.and.screwdriver", description: Text("This server doesn't offer any tools."))
                    } else {
                        List(tools) { tool in row(tool) }
                            .listStyle(.inset)
                    }
                } else if let error {
                    ContentUnavailableView("Couldn't Load Tools", systemImage: "exclamationmark.triangle", description: Text(UpstreamStatus.explain(error)))
                } else {
                    ProgressView("Asking \(config.name) for its tools…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Text(summary).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 580, height: 500)
        .task { await load() }
    }

    private var summary: String {
        let count = Set(policy.overrides.keys).union(policy.offline.keys).count
        return count == 0 ? "All tools on Default" : "\(counted(count, "tool")) set individually"
    }

    private func row(_ tool: ToolSummary) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.hints.title ?? tool.name).font(.body.weight(.medium))
                    if tool.hints.readOnly { Badge(text: "read-only", color: .green) }
                    if tool.hints.declaresDestructive { Badge(text: "destructive", color: .red) }
                }
                if tool.hints.title != nil {
                    Text(tool.name).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let description = tool.description {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Picker("Permission", selection: binding(for: tool)) {
                    Text("Default (\(policy.defaultPermission(readOnly: tool.hints.readOnly).title))").tag(ToolPermission?.none)
                    Divider()
                    ForEach(ToolPermission.allCases, id: \.self) { Text($0.title).tag(ToolPermission?.some($0)) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                // Read-only calls can't wait: nobody would get the answer.
                if !tool.hints.readOnly {
                    Toggle("Queue when offline", isOn: queueBinding(for: tool))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .disabled(policy.permission(for: tool.name, readOnly: false) == .deny)
                        .help("While your Mac is offline, the relay saves calls to this tool and runs them when it's back, asking first if the tool is set to Ask.")
                }
            }
            .frame(width: 170, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private func binding(for tool: ToolSummary) -> Binding<ToolPermission?> {
        Binding(
            get: { policy.overrides[tool.name] },
            set: { policy.overrides[tool.name] = $0 }
        )
    }

    /// Stores an override only when it differs from the default (on for additive tools).
    private func queueBinding(for tool: ToolSummary) -> Binding<Bool> {
        Binding(
            get: { policy.queuesOffline(tool.name, readOnly: tool.hints.readOnly, destructive: tool.hints.destructive) },
            set: { policy.offline[tool.name] = $0 == tool.hints.additive ? nil : $0 }
        )
    }

    private func load() async {
        switch await model.probe(config) {
        case .success(let found): tools = found.tools
        case .failure(let failure): error = failure.message
        }
    }
}

extension ToolPermission {
    var title: String {
        switch self {
        case .allow: "Allow"
        case .ask: "Ask"
        case .deny: "Block"
        }
    }
}
