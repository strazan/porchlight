import AppKit
import PorchlightCore
import SwiftUI

/// A floating panel asking the owner to approve an app that wants to connect. It shows
/// itself while `AppModel.pendingPairings` has entries, one at a time.
@MainActor
final class PairingPanel: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private var panel: NSPanel?

    init(model: AppModel) {
        self.model = model
    }

    func update(bringToFront: Bool = false) {
        guard !model.pendingPairings.isEmpty else {
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
        panel.title = "Approve Connection"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        // A hosting controller sizes the panel to fit the view.
        panel.contentViewController = NSHostingController(rootView: PairingView().environment(model))
        return panel
    }

    /// Closing the panel declines the request: never grant access by accident. With more
    /// requests waiting, it stays open on the next one.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let request = model.pendingPairings.first { model.decide(request, allow: false) }
        return model.pendingPairings.isEmpty
    }
}

private struct PairingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let request = model.pendingPairings.first {
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

                if model.pendingPairings.count > 1 {
                    Text("\(model.pendingPairings.count - 1) more waiting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 20)
            .frame(width: 400)
        }
    }
}
