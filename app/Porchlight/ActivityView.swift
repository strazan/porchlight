import PorchlightCore
import SwiftUI

/// What cloud apps have been doing through Porchlight.
struct ActivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.activity.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Requests from connected apps show up here as they happen.")
                )
            } else {
                Table(model.activity.reversed()) {
                    TableColumn("Time") { event in
                        Text(event.date, format: .dateTime.hour().minute().second())
                            .foregroundStyle(.secondary)
                    }
                    .width(70)
                    TableColumn("App") { event in Text(event.client.name) }
                        .width(min: 80, ideal: 110)
                    TableColumn("Request") { event in
                        Text(event.tool ?? event.method)
                            .font(.body.monospaced())
                            .help(event.method)
                    }
                    .width(min: 120, ideal: 200)
                    TableColumn("Server") { event in
                        Text(event.server ?? "all").foregroundStyle(event.server == nil ? .secondary : .primary)
                    }
                    .width(min: 70, ideal: 100)
                    TableColumn("Time Taken") { event in
                        Text(event.duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow, maximumUnitCount: 1)))
                            .foregroundStyle(.secondary)
                    }
                    .width(80)
                    TableColumn("Result") { event in OutcomeLabel(outcome: event.outcome) }
                        .width(min: 120, ideal: 240)
                }
            }
        }
        .toolbar {
            Button("Clear") { model.clearActivity() }
                .disabled(model.activity.isEmpty)
        }
        .frame(minWidth: 760, minHeight: 320)
    }
}

private struct OutcomeLabel: View {
    let outcome: ActivityEvent.Outcome

    var body: some View {
        switch outcome {
        case .ok:
            Label("OK", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .help(message)
        case .denied(let reason):
            Label("Declined", systemImage: "hand.raised.fill")
                .foregroundStyle(.orange)
                .help(reason)
        }
    }
}
