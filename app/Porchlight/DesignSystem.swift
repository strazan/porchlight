import AppKit
import PorchlightCore
import SwiftUI

// Shared look: a warm porch-light amber for Porchlight's own moments (the lightbulb, "on",
// things waiting for you), system colors for everything else.

extension Color {
    /// Porchlight's accent: the glow of a porch light.
    static let porchlight = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.00, green: 0.76, blue: 0.30, alpha: 1)
            : NSColor(red: 0.91, green: 0.58, blue: 0.10, alpha: 1)
    })
}

// MARK: - Status

extension UpstreamStatus {
    var color: Color {
        switch self {
        case .idle: .secondary.opacity(0.5)
        case .starting: .yellow
        case .running: .green
        case .failed: .red
        }
    }

    /// Short, for lists.
    var label: String {
        switch self {
        case .idle: "Idle"
        case .starting: "Starting…"
        case .running: "Running"
        case .failed: "Not running"
        }
    }

    /// What went wrong, in words, when it failed.
    var problem: String? {
        guard case .failed(let reason) = self else { return nil }
        return Self.explain(reason)
    }

    var isFailure: Bool { problem != nil }

    /// Common exit codes, said plainly.
    static func explain(_ reason: String) -> String {
        if reason.hasSuffix("status 127") { return "Command not found. Check the command, or that it's installed." }
        if reason.hasSuffix("status 126") { return "The command can't be run (permissions?)." }
        if reason == "Exited" { return "It stopped unexpectedly." }
        return reason
    }
}

struct StatusDot: View {
    let color: Color
    var diameter: CGFloat = 8

    init(_ color: Color, diameter: CGFloat = 8) {
        self.color = color
        self.diameter = diameter
    }

    init(status: UpstreamStatus, diameter: CGFloat = 8) {
        color = status.color
        self.diameter = diameter
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
    }
}

// MARK: - Menu rows

/// A full-width row for the menu bar popover that highlights on hover, like a menu item.
struct MenuRow: View {
    let title: String
    var systemImage: String?
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Headers and identity

/// The title block at the top of a sheet or panel.
struct SheetHeader: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var tint: Color = .porchlight

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A round badge with an app's initial, tinted by its name.
struct AppAvatar: View {
    let name: String
    var size: CGFloat = 28

    private static let tints: [Color] = [.orange, .blue, .green, .purple, .pink, .teal, .indigo]

    var body: some View {
        let tint = Self.tints[abs(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % Self.tints.count]
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: Circle())
    }
}

/// A short colored label, like "read-only".
struct Badge: View {
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

// MARK: - Copying

struct CopyButton: View {
    let text: String
    var label: String?
    var help = "Copy"
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
            if let label {
                Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
        }
        .help(help)
    }
}

// MARK: - List bars

/// The `+ −` bar attached to the bottom of a list, as in System Settings.
struct ListBar<Trailing: View>: View {
    let add: () -> Void
    let remove: () -> Void
    let canRemove: Bool
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            Button(action: add) { Image(systemName: "plus").frame(width: 24, height: 20) }
                .help("Add")
            Divider().frame(height: 14)
            Button(action: remove) { Image(systemName: "minus").frame(width: 24, height: 20) }
                .disabled(!canRemove)
                .help("Remove")
            Spacer()
            trailing
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
}
