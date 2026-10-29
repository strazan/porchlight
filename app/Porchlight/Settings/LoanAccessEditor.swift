import PorchlightCore
import SwiftUI

struct LoanAccessEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let loan: Loan
    @State private var selected: [String: Set<String>]
    @State private var saving = false

    init(loan: Loan) {
        self.loan = loan
        _selected = State(initialValue: loan.allowedTools)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Tool access for \(loan.borrower)",
                        subtitle: "Only this person’s app connection changes. Access expires \(loan.expiresAt.formatted(date: .abbreviated, time: .shortened)).",
                        systemImage: "checklist")
            LoanToolPicker(selection: $selected)
            HStack {
                Text(counted(selected.values.reduce(0) { $0 + $1.count }, "allowed tool")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    saving = true
                    Task {
                        if await model.updateLoan(loan, allowedTools: selected) { dismiss() }
                        saving = false
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .disabled(saving)
        .alert("Couldn't Save Access", isPresented: Binding(get: { model.lendingError != nil }, set: { if !$0 { model.lendingError = nil } })) {
            Button("OK") { model.lendingError = nil }
        } message: { Text(model.lendingError ?? "") }
    }
}
