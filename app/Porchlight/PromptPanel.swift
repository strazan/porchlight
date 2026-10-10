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

    private var hasPrompts: Bool { !model.pendingPairings.isEmpty || !model.pendingApprovals.isEmpty }

    func update(bringToFront: Bool = false) {
        guard hasPrompts else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if bringToFront || !panel.isVisible {
            if !panel.isVisible { NSSound(named: "Glass")?.play() }
            panel.center()
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Porchlight"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        // A hosting controller sizes the panel to fit the view.
        panel.contentViewController = NSHostingController(rootView: PromptView().environment(model))
        return panel
    }

    /// Closing the panel declines what it shows: never grant access by accident. With more
    /// requests waiting, it stays open on the next one.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let request = model.pendingPairings.first {
            model.decide(request, allow: false)
        } else if let request = model.pendingApprovals.first {
            model.answer(request, with: .deny)
        }
        return !hasPrompts
    }
}

private struct PromptView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let request = model.pendingPairings.first {
                PairingView(request: request)
            } else if let request = model.pendingApprovals.first {
                ApprovalView(request: request)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(width: 420)
    }
}

private struct PairingView: View {
    @Environment(AppModel.self) private var model
    let request: PairingRequest

    var body: some View {
            VStack(spacing: 14) {
                Image(systemName: "lightbulb.max.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.yellow)
                Text("Connect \(request.clientName)?")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                VStack(spacing: 6) {
                    if let domain = request.clientDomain {
                        Label("Published by \(domain)", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("This app named itself; its name isn't verified", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text("Access will be sent to **\(request.redirectHost)**.")
                        .foregroundStyle(.secondary)
                    if request.loopback {
                        Text("That's an app on this computer. Allow only if you just started connecting from it.")
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                }
                .font(.callout)

                VStack(spacing: 4) {
                    Text("Check that your browser shows this code:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(request.formattedCode)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)

                Text("It will be able to use all your enabled servers. You can revoke access in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack {
                    Button("Deny", role: .cancel) { model.decide(request, allow: false) }
                        .keyboardShortcut(.cancelAction)
                    Button("Allow") { model.decide(request, allow: true) }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)

                WaitingCount(count: model.pendingPairings.count + model.pendingApprovals.count - 1)
            }
    }
}

private struct ApprovalView: View {
    @Environment(AppModel.self) private var model
    let request: ToolApprovalRequest

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            VStack(spacing: 4) {
                Text("\(request.clientName) wants to use \(request.title ?? request.tool)")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("\(request.tool) on \(request.server)")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(prettyJSON(request.arguments))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 180)
            .fixedSize(horizontal: false, vertical: true)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Deny", role: .cancel) { model.answer(request, with: .deny) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Always Allow") { model.answer(request, with: .allowAlways) }
                Button("Allow Once") { model.answer(request, with: .allowOnce) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)

            Text("Always Allow stops asking about \(request.tool) on \(request.server). You can change that in Settings → Servers.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            WaitingCount(count: model.pendingPairings.count + model.pendingApprovals.count - 1)
        }
    }

    private func prettyJSON(_ value: JSONValue) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: value.serialized(), options: [.fragmentsAllowed]),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return String(decoding: value.serialized(), as: UTF8.self) }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct WaitingCount: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count) more waiting")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
