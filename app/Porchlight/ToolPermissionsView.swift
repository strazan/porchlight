import PorchlightCore
import SwiftUI

/// Per-tool permissions for one server, edited in place on its policy.
struct ToolPermissionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let config: ServerConfig
    @Binding var policy: ToolPolicy
    @State private var tools: [Router.ToolSummary]?
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
        let count = policy.overrides.count
        return count == 0 ? "All tools on Default" : count == 1 ? "1 tool set individually" : "\(count) tools set individually"
    }

    private func row(_ tool: Router.ToolSummary) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.title ?? tool.name).font(.body.weight(.medium))
                    if tool.readOnly { Badge(text: "read-only", color: .green) }
                    if tool.destructive { Badge(text: "destructive", color: .red) }
                }
                if tool.title != nil {
                    Text(tool.name).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let description = tool.description {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            Picker("Permission", selection: binding(for: tool)) {
                Text("Default (\(policy.defaultPermission(readOnly: tool.readOnly).title))").tag(ToolPermission?.none)
                Divider()
                ForEach(ToolPermission.allCases, id: \.self) { Text($0.title).tag(ToolPermission?.some($0)) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .frame(width: 170, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private func binding(for tool: Router.ToolSummary) -> Binding<ToolPermission?> {
        Binding(
            get: { policy.overrides[tool.name] },
            set: { policy.overrides[tool.name] = $0 }
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
