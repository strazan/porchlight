import AppKit
import PorchlightCore
import SwiftUI

/// The menu bar popover.
struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    /// The popover's own window, to close it when a row opens something else.
    @State private var menuWindow: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            if let waiting = waitingSummary {
                WaitingCard(text: waiting) {
                    closeMenu()
                    model.showPendingPrompt()
                }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }

            Divider().padding(.horizontal, 14)

            Group {
                if model.isSetUp {
                    connected
                } else {
                    GettingStarted { tab in show(settings: tab) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().padding(.horizontal, 14)

            VStack(spacing: 0) {
                MenuRow(title: "Settings…", shortcut: "⌘,") { show(settings: nil) }
                    .keyboardShortcut(",")
                MenuRow(title: "Activity") { show("activity") }
                MenuRow(title: "Quit Porchlight", shortcut: "⌘Q") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(6)
        }
        .frame(width: 320)
        .background(WindowReader(window: $menuWindow))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Porchlight").font(.headline)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(statusIsProblem ? Color.red : .secondary)
                    .lineLimit(2)
            }
            Spacer()
            Toggle("Porchlight", isOn: Binding(get: { model.isOn }, set: { model.setOn($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!model.isConfigured)
                .help(model.isOn ? "Turn off: cloud agents can't reach your servers" : "Turn on")
        }
    }

    private var statusLine: String {
        switch model.state {
        case .off: model.isConfigured ? "Off" : "Not set up yet"
        case .starting, .relay(.connecting): "Connecting…"
        case .relay(.connected):
            switch model.servers.filter(\.enabled).count {
            case 0: "Connected · no servers yet"
            case 1: "Connected · 1 server"
            case let n: "Connected · \(n) servers"
            }
        case .relay(.disconnected(let reason)): reason
        }
    }

    private var statusIsProblem: Bool {
        if case .relay(.disconnected) = model.state { return true }
        return false
    }

    private var waitingSummary: String? {
        if let request = model.pendingPairings.first { return "\(request.clientName) wants to connect" }
        if let request = model.pendingApprovals.first { return "\(request.clientName) wants to use \(request.title ?? request.tool)" }
        return nil
    }

    // MARK: Connected

    private var connected: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Connector URL")
                HStack(spacing: 8) {
                    Text(model.endpoint.replacingOccurrences(of: "https://", with: ""))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    CopyButton(text: model.endpoint, help: "Copy the URL to add as a connector in Claude or ChatGPT")
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            }

            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Servers")
                let enabled = model.servers.filter(\.enabled)
                if enabled.isEmpty {
                    HStack {
                        Text("None yet").foregroundStyle(.secondary)
                        Spacer()
                        Button("Add Server…") { show(settings: .servers) }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                    .padding(.vertical, 2)
                } else {
                    ForEach(enabled) { server in
                        ServerMenuRow(server: server, status: model.status(of: server), url: model.endpoint(for: server))
                    }
                }
            }
        }
    }

    private func show(_ id: String) {
        closeMenu()
        openWindow(id: id)
        NSApp.activate()
    }

    private func show(settings tab: SettingsView.Tab?) {
        if let tab { model.requestedSettingsTab = tab }
        show("settings")
    }
}

extension MenuContent {
    /// A window-style menu bar extra doesn't close itself when a button opens a window.
    private func closeMenu() {
        menuWindow?.close()
    }
}

/// Finds the NSWindow a view lives in.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if window !== view.window {
            DispatchQueue.main.async { window = view.window }
        }
    }
}

struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .kerning(0.4)
    }
}

/// Something waiting for the owner's answer.
private struct WaitingCard: View {
    let text: String
    let review: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.badge.fill")
                .foregroundStyle(Color.porchlight)
            Text(text)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Review", action: review)
                .controlSize(.small)
        }
        .padding(10)
        .background(Color.porchlight.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
    }
}

/// One server: status, name, and (on hover) its own URL to copy.
private struct ServerMenuRow: View {
    let server: ServerConfig
    let status: UpstreamStatus
    let url: String
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 9) {
                ServerIcon(server: server, size: 18, status: status)
                Text(server.name).font(.callout.weight(.medium))
                Spacer(minLength: 4)
                if hovering {
                    CopyButton(text: url, help: "Copy the URL for just \(server.name)")
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                } else {
                    Text(status.label)
                        .font(.caption)
                        .foregroundStyle(status.isFailure ? Color.red : .secondary)
                }
            }
            if let problem = status.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 27)
                    .help(problem)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy URL for \(server.name)") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
        }
    }
}

/// The checklist shown until Porchlight is set up.
private struct GettingStarted: View {
    @Environment(AppModel.self) private var model
    let open: (SettingsView.Tab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Let cloud agents like Claude and ChatGPT use the MCP servers on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Set up your relay", done: model.isConfigured)
                step(2, "Add servers", done: !model.servers.isEmpty)
                step(3, "Connect an app", done: !model.clients.isEmpty)
            }
            Button {
                open(model.isConfigured ? .servers : .relay)
            } label: {
                Text(model.isConfigured ? "Add Servers…" : "Set Up Porchlight…").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.porchlight)
            .controlSize(.large)
        }
    }

    private func step(_ number: Int, _ title: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.secondary.opacity(0.15))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            Text(title)
                .font(.callout)
                .foregroundStyle(done ? .secondary : .primary)
                .strikethrough(done, color: .secondary)
        }
    }
}
