import AppKit
import PorchlightCore
import SwiftUI

struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(relayColor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Porchlight").font(.headline)
                    Text(model.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.isOn }, set: { model.setOn($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!model.isConfigured)
            }

            if let request = model.pendingPairings.first {
                Button { model.showPendingPairing() } label: {
                    HStack {
                        Image(systemName: "bell.badge.fill").foregroundStyle(.orange)
                        Text("\(request.clientName) wants to connect")
                        Spacer()
                        Text("Review").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            if !model.isConfigured {
                Text("Add your relay URL and secret in Settings to get started.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Divider()
                CopyableURL(label: "All servers", url: model.endpoint)
                Divider()
                let enabled = model.servers.filter(\.enabled)
                if enabled.isEmpty {
                    Text("No servers yet. Add or import them in Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(enabled) { server in
                            ServerMenuRow(server: server, status: model.status(of: server), url: model.endpoint(for: server))
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button("Settings…") { show("settings") }
                Button("Logs") { show("logs") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
    }

    private var relayColor: Color {
        switch model.state {
        case .off: .gray
        case .starting, .relay(.connecting): .yellow
        case .relay(.connected): .green
        case .relay(.disconnected): .red
        }
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate()
    }
}

private struct ServerMenuRow: View {
    let server: ServerConfig
    let status: StdioUpstream.Status
    let url: String

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: status)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name).font(.callout.weight(.medium))
                Text(status.label)
                    .font(.caption)
                    .foregroundStyle(status.isFailure ? .red : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            CopyButton(text: url, help: "Copy this server's URL")
        }
    }
}

struct CopyableURL: View {
    let label: String
    let url: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(url).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            CopyButton(text: url, help: "Copy URL")
        }
    }
}

struct CopyButton: View {
    let text: String
    let help: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

struct StatusDot: View {
    let status: StdioUpstream.Status

    var body: some View {
        Circle().fill(status.color).frame(width: 7, height: 7)
    }
}

extension StdioUpstream.Status {
    var color: Color {
        switch self {
        case .idle: .gray
        case .starting: .yellow
        case .running: .green
        case .failed: .red
        }
    }

    var label: String {
        switch self {
        case .idle: "Idle"
        case .starting: "Starting…"
        case .running: "Running"
        case .failed(let reason): reason
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
