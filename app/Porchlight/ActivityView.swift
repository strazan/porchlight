import PorchlightCore
import SwiftUI

/// What cloud apps have been doing through Porchlight, and what the servers printed.
struct ActivityView: View {
    enum Page: Hashable {
        case requests
        case logs
    }

    @Environment(AppModel.self) private var model
    @State private var page: Page = .requests

    var body: some View {
        Group {
            switch page {
            case .requests: requests
            case .logs: LogsView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $page) {
                    Text("Requests").tag(Page.requests)
                    Text("Logs").tag(Page.logs)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Clear") {
                    switch page {
                    case .requests: model.clearActivity()
                    case .logs: model.clearLogs()
                    }
                }
                .disabled(page == .requests ? model.activity.isEmpty : model.logs.isEmpty)
            }
        }
        .frame(minWidth: 780, minHeight: 360)
    }

    @ViewBuilder private var requests: some View {
        if model.activity.isEmpty {
            ContentUnavailableView(
                "No Requests Yet",
                systemImage: "list.bullet.rectangle",
                description: Text("Requests from connected apps show up here as they happen.")
            )
        } else {
            Table(model.activity.reversed()) {
                TableColumn("Time") { event in
                    Text(event.date, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(72)
                TableColumn("App") { event in
                    HStack(spacing: 6) {
                        AppIcon(clientID: event.client.id, name: event.client.name, size: 16)
                        Text(event.client.name)
                    }
                }
                .width(min: 90, ideal: 120)
                TableColumn("Request") { event in
                    HStack(spacing: 6) {
                        Text(event.tool ?? event.method)
                            .font(.body.monospaced())
                            .help(event.method)
                        if let queuedAt = event.queuedAt {
                            Badge(text: "queued", color: .orange)
                                .help("Made \(queuedAt.formatted(.relative(presentation: .named))), while your Mac was offline")
                        }
                    }
                }
                .width(min: 120, ideal: 190)
                TableColumn("Server") { event in
                    Text(event.server ?? "—").foregroundStyle(event.server == nil ? .tertiary : .primary)
                }
                .width(min: 70, ideal: 100)
                TableColumn("Duration") { event in
                    Text(event.duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow, maximumUnitCount: 1)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(70)
                TableColumn("Result") { event in OutcomeLabel(outcome: event.outcome) }
                    .width(min: 120, ideal: 220)
            }
        }
    }
}

private struct OutcomeLabel: View {
    let outcome: ActivityEvent.Outcome

    var body: some View {
        switch outcome {
        case .ok:
            Label("OK", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .error(let message):
            Label(UpstreamStatus.explain(message), systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .help(message)
        case .denied(let reason):
            Label("Denied", systemImage: "hand.raised.fill")
                .foregroundStyle(.orange)
                .help(reason)
        }
    }
}
