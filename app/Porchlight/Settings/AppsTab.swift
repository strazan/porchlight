import PorchlightCore
import SwiftUI

/// The apps with access, and what each may use.
struct AppsTab: View {
    @Environment(AppModel.self) private var model
    @State private var revoking: AppModel.ConnectedApp?
    @State private var editingAccess: AppModel.ConnectedApp?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ListBox {
                Group {
                    if !model.isConnected {
                        ContentUnavailableView(
                            "Not Connected",
                            systemImage: "network.slash",
                            description: Text("Turn Porchlight on to see which apps have access.")
                        )
                    } else if model.apps.isEmpty {
                        ContentUnavailableView {
                            Label("No Apps Yet", systemImage: "person.2")
                        } description: {
                            Text("Add the connector URL as a custom connector in Claude, ChatGPT or another MCP client. You'll approve it on this Mac.")
                        } actions: {
                            CopyButton(text: model.endpoint, label: "Copy Connector URL")
                        }
                    } else {
                        List(model.apps) { app in
                            AppRow(app: app, access: model.access(for: app.id)) {
                                editingAccess = app
                            } revoke: {
                                revoking = app
                            }
                        }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
                    }
                }
                .frame(maxHeight: .infinity)
            } bar: {
                HStack {
                    Text(counted(model.apps.count, "app"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                    Spacer()
                    Button { model.refreshClients() } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 20) }
                        .buttonStyle(.borderless)
                        .help("Refresh")
                        .disabled(!model.isConnected)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            Footnote("Apps reach your servers through the relay after you approve them. Revoking an app stops it right away.")
        }
        .padding(20)
        .onAppear { model.refreshClients() }
        .sheet(item: $editingAccess) { app in AccessEditor(app: app) }
        .confirmationDialog(
            "Revoke access for \(revoking?.latest.clientName ?? "this app")?",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            presenting: revoking
        ) { app in
            Button("Revoke", role: .destructive) { model.revoke(app) }
        } message: { app in
            Text(app.connections.count > 1
                ? "All \(app.connections.count) of its connections stop working right away. To use it again, connect it again and approve it here."
                : "It stops working right away. To use it again, connect it again and approve it here.")
        }
    }
}

private struct AppRow: View {
    let app: AppModel.ConnectedApp
    let access: Set<String>?
    let changeAccess: () -> Void
    let revoke: () -> Void
    @State private var changingIcon = false
    @State private var toolCount: Int?
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(clientID: client.clientID, name: client.clientName, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(client.clientName).font(.body.weight(.medium))
                    if client.clientDomain != nil {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .help("Its name is verified")
                    }
                }
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(accessSummary)
                    .font(.caption)
                    .foregroundStyle(toolCount.map { $0 > AppModel.manyTools } == true ? .orange : .secondary)
                    .lineLimit(1)
            }
            .task(id: "\(model.toolsRevision)|\(access.map { $0.sorted().joined(separator: ",") } ?? "*")") {
                toolCount = await model.toolCount(for: app.id)
            }
            Spacer()
            Menu { actions } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change access or icon, or revoke")
        }
        .padding(.vertical, 4)
        .contextMenu { actions }
        .sheet(isPresented: $changingIcon) {
            IconPicker(
                key: IconStore.key(app: app.id),
                title: "Icon for \(client.clientName)",
                defaultWebsite: model.defaultIconWebsite(forApp: app.id),
                plainLabel: "Initial"
            ) {
                AppIcon(clientID: app.id, name: client.clientName, size: 48)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        Button("Change Access…", action: changeAccess)
        Button("Change Icon…") { changingIcon = true }
        Divider()
        Button("Revoke…", role: .destructive, action: revoke)
    }

    private var client: PairedClient { app.latest }

    private var details: String {
        let origin = client.clientDomain ?? "Unverified name"
        let connections = app.connections.count > 1 ? " · \(counted(app.connections.count, "connection"))" : ""
        return "\(origin) · connected \(client.createdAt.formatted(.relative(presentation: .named)))\(connections)"
    }

    private var accessSummary: String {
        let servers = if let access {
            access.isEmpty ? "Can't use any server" : "Can use " + access.sorted().joined(separator: ", ")
        } else {
            "Can use all servers"
        }
        guard let toolCount, access?.isEmpty != true else { return servers }
        return "\(servers) · \(counted(toolCount, "tool"))"
    }
}
