import PorchlightCore
import SwiftUI

/// The servers Porchlight serves.
struct ServersTab: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<ServerConfig.ID> = []
    @State private var editing: ServerConfig?
    @State private var changingIcon: ServerConfig?
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ListBox {
                if model.servers.isEmpty {
                    ContentUnavailableView {
                        Label("No Servers Yet", systemImage: "server.rack")
                    } description: {
                        Text("Add an MCP server that runs on this Mac, or import the ones you use in Claude Desktop, Claude Code or Cursor.")
                    } actions: {
                        Button("Import…") { importing = true }
                        Button("Add Server…") { editing = newServer() }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    List(selection: $selection) {
                        ForEach(model.servers) { server in
                            ServerRow(server: server) { editing = server }
                                .tag(server.id)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .contextMenu(forSelectionType: ServerConfig.ID.self) { ids in
                        if ids.count == 1, let server = server(ids.first) {
                            Button("Edit…") { editing = server }
                            Button("Change Icon…") { changingIcon = server }
                            Divider()
                        }
                        Button("Remove", role: .destructive) { model.remove(ids) }
                    } primaryAction: { ids in
                        if let server = server(ids.first) { editing = server }
                    }
                    .onDeleteCommand { model.remove(selection) }
                }
            } bar: {
                ListBar(add: { editing = newServer() }, remove: { model.remove(selection) }, canRemove: !selection.isEmpty) {
                    if !model.servers.isEmpty {
                        Button("Import…") { importing = true }
                            .padding(.trailing, 6)
                    }
                }
            }
            if !model.servers.isEmpty {
                ToolCountNote()
            }
        }
        .padding(20)
        .sheet(item: $editing) { server in
            ServerEditor(server: server, isNew: !model.servers.contains { $0.id == server.id })
        }
        .sheet(isPresented: $importing) { ImportView() }
        .sheet(item: $changingIcon) { server in ServerIconPicker(server: server) }
    }

    private func server(_ id: ServerConfig.ID?) -> ServerConfig? {
        model.servers.first { $0.id == id }
    }

    private func newServer() -> ServerConfig {
        ServerConfig(name: "", command: "")
    }
}

private struct ServerRow: View {
    @Environment(AppModel.self) private var model
    let server: ServerConfig
    let edit: () -> Void

    var body: some View {
        let status = server.enabled ? model.status(of: server) : .idle
        HStack(spacing: 12) {
            ServerIcon(server: server, size: 30, status: status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name).font(.body.weight(.medium))
                    if server.transport == .http { Badge(text: "URL", color: .secondary) }
                }
                Text(server.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let problem = status.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button(action: edit) { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Edit \(server.name)")
            Toggle("Enabled", isOn: Binding(get: { server.enabled }, set: { model.setEnabled($0, for: server) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

/// How many tools cloud agents get in one connector, with advice when it's a lot.
private struct ToolCountNote: View {
    @Environment(AppModel.self) private var model
    @State private var count: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let count, count > AppModel.manyTools {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Footnote(text)
        }
        .task(id: model.toolsRevision) { count = await model.toolCount(for: nil) }
    }

    private var text: String {
        guard let count else { return "Cloud agents see each server's tools as server__tool. Double-click a server to edit it." }
        if count > AppModel.manyTools {
            return "Cloud agents see \(count) tools in one connector. With that many they can pick the wrong one, and every "
                + "message costs more: block tools you don't use in each server's settings, or add busy servers as their own connectors."
        }
        return "Cloud agents see \(counted(count, "tool")), named server__tool. Double-click a server to edit it."
    }
}
