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
        VStack(alignment: .leading, spacing: 12) {
            Text("Tools on \(config.name)").font(.title3.weight(.semibold))
            Text("“Default” follows the server's setting: \(policy.defaultPermission.title.lowercased()).")
                .font(.callout)
                .foregroundStyle(.secondary)

            Group {
                if let tools {
                    if tools.isEmpty {
                        ContentUnavailableView("No Tools", systemImage: "wrench.and.screwdriver", description: Text("This server doesn't offer any tools."))
                    } else {
                        List(tools) { tool in row(tool) }
                    }
                } else if let error {
                    ContentUnavailableView("Couldn't Load Tools", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView("Asking the server for its tools…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .task { await load() }
    }

    private func row(_ tool: Router.ToolSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
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
            Spacer()
            Picker("", selection: binding(for: tool)) {
                Text("Default (\(policy.defaultPermission(readOnly: tool.readOnly).title))").tag(ToolPermission?.none)
                ForEach(ToolPermission.allCases, id: \.self) { Text($0.title).tag(ToolPermission?.some($0)) }
            }
            .labelsHidden()
            .frame(width: 150)
        }
        .padding(.vertical, 2)
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

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
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

extension ToolPolicy.Default {
    var title: String {
        switch self {
        case .allowAll: "Run tools without asking"
        case .askForChanges: "Ask before tools that make changes"
        case .askAll: "Ask before every tool"
        }
    }
}
