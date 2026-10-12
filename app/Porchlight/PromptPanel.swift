import AppKit
import PorchlightCore
import SwiftUI

/// A floating panel for things that need the owner's answer: an app that wants to connect,
/// or a tool call that needs approval. It shows while either list has entries, one
/// request at a time, pairings first.
@MainActor
final class PromptPanel: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private var panel: NSPanel?

    init(model: AppModel) {
        self.model = model
    }

    private var hasPrompts: Bool { model.prompts.count > 0 }

    /// Shows the panel while there's something to answer. It only takes keyboard focus when
    /// the owner asks for it (`focus`): a prompt that pops up while they're typing elsewhere
    /// mustn't catch a Return meant for another app.
    func update(focus: Bool = false) {
        guard hasPrompts else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            NSSound(named: "Glass")?.play()
            panel.center()
            panel.orderFrontRegardless()
        }
        if focus {
            panel.orderFrontRegardless()
            panel.makeKey()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            // Non-activating, like Spotlight: once clicked it takes focus (Return, Esc) without
            // activating Porchlight, so its other windows stay put and focus returns when it closes.
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Porchlight"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        // A hosting controller sizes the panel to fit the view.
        panel.contentViewController = NSHostingController(rootView: PromptView().environment(model))
        return panel
    }

    /// Closing the panel declines what it shows: never grant access by accident. With more
    /// requests waiting, it stays open on the next one.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch model.prompts.current {
        case .pairing(let request): model.answer(request, allow: false)
        case .approval(let request): model.answer(request, with: .deny)
        case nil: break
        }
        return !hasPrompts
    }
}

struct PromptView: View {
    @Environment(AppModel.self) private var model
    /// Off for a moment whenever a different request appears, so a click or Return meant for
    /// the previous one can't answer it.
    @State private var armed = false

    var body: some View {
        let prompt = model.prompts.current
        Group {
            switch prompt {
            case .pairing(let request): PairingView(request: request)
            case .approval(let request): ApprovalView(request: request)
            case nil: EmptyView()
            }
        }
        .disabled(!armed && !model.isSampleMode)
        .padding(24)
        .frame(width: 440)
        .task(id: prompt?.key) {
            model.prompts.shown = prompt?.key
            armed = false
            try? await Task.sleep(for: .milliseconds(800))
            armed = true
        }
    }
}

/// The layout both prompts share: who's asking and what, details, then the answer.
private struct PromptLayout<Details: View, Buttons: View>: View {
    let clientID: String
    let appName: String
    let title: String
    let subtitle: String
    @ViewBuilder var details: Details
    @ViewBuilder var buttons: Buttons
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: title, subtitle: subtitle) {
                AppIcon(clientID: clientID, name: appName, size: 40)
            }
            details
            HStack(spacing: 8) {
                buttons
            }
            .controlSize(.large)
            let waiting = model.prompts.count - 1
            if waiting > 0 {
                Text("\(waiting) more waiting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

private struct PairingView: View {
    @Environment(AppModel.self) private var model
    let request: PairingRequest
    @State private var access: Set<String>?

    var body: some View {
        PromptLayout(
            clientID: request.clientID,
            appName: request.clientName,
            title: "Connect \(request.clientName)?",
            subtitle: origin
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if request.loopback {
                    Label("Access goes to an app on this Mac. Allow only if you just started connecting from it.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 6) {
                    Text("Your browser should show the same code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(request.formattedCode)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .kerning(2)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.porchlight.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                if !request.clientID.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What it can use").font(.callout.weight(.medium))
                        ServerAccessPicker(servers: model.servers.filter(\.enabled).map(\.name), selection: $access)
                    }
                }
            }
        } buttons: {
            Button("Deny", role: .cancel) { model.answer(request, allow: false) }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Allow") { model.answer(request, allow: true, servers: access) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .onChange(of: request.id) { access = nil }
    }

    private var origin: String {
        let who = request.clientDomain.map { "Published by \($0)" } ?? "This app named itself; its name isn't verified"
        return "\(who). Access goes to \(request.redirectHost)."
    }
}

private struct ApprovalView: View {
    @Environment(AppModel.self) private var model
    let request: ToolApprovalRequest

    var body: some View {
        PromptLayout(
            clientID: request.client.id,
            appName: request.client.name,
            title: "\(request.client.name) wants to use \(request.title ?? request.tool)",
            subtitle: subtitle
        ) {
            ArgumentsView(arguments: request.arguments)
        } buttons: {
            Button("Deny", role: .cancel) { model.answer(request, with: .deny) }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Always Allow") { model.answer(request, with: .allowAlways) }
                .help("Stop asking about \(request.tool) on \(request.server). You can change this in the server's settings.")
            Button("Allow Once") { model.answer(request, with: .allowOnce) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }
}

extension ApprovalView {
    private var subtitle: String {
        let what = "\(request.tool) on \(request.server)"
        guard let queuedAt = request.queuedAt else { return what }
        return "\(what). Asked \(queuedAt.formatted(.relative(presentation: .named))), while your Mac was offline."
    }
}

/// A tool call's arguments as labeled fields; anything nested as formatted JSON.
private struct ArgumentsView: View {
    let arguments: JSONValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if case .object(let fields) = arguments, !fields.isEmpty {
                    ForEach(fields.keys.sorted(), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            Text(Self.display(fields[key] ?? .null))
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else if case .object = arguments {
                    Text("No arguments").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(Self.display(arguments)).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(maxHeight: 200)
        .fixedSize(horizontal: false, vertical: true)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    static func display(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .array, .object:
            guard let object = try? JSONSerialization.jsonObject(with: value.serialized(), options: [.fragmentsAllowed]),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
            else { return String(decoding: value.serialized(), as: UTF8.self) }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
