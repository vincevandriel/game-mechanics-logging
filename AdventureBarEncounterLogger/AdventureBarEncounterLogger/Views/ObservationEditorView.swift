import SwiftUI

struct ObservationEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private let original: EncounterObservation

    @State private var stepCountText: String
    @State private var movementMode: MovementMode
    @State private var uncertaintyText: String
    @State private var note: String
    @State private var isQuestionable: Bool
    @State private var questionableReason: String
    @State private var editReason = ""
    @State private var presentedError: PresentedError?

    init(observation: EncounterObservation) {
        original = observation
        _stepCountText = State(initialValue: String(observation.stepCount))
        _movementMode = State(initialValue: observation.movementMode)
        _uncertaintyText = State(initialValue: String(observation.measurementUncertainty))
        _note = State(initialValue: observation.note ?? "")
        _isQuestionable = State(initialValue: observation.isQuestionable)
        _questionableReason = State(initialValue: observation.questionableReason ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Raw Observation") {
                    HStack {
                        Text("Encounter")
                        Spacer()
                        Text("#\(original.encounterNumber)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }

                    TextField("Step count", text: $stepCountText)
                        .keyboardType(.numberPad)
                        .accessibilityHint("Enter the raw successful-tile count exactly")

                    Picker("Movement mode", selection: $movementMode) {
                        ForEach(MovementMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    HStack {
                        Text("Measurement uncertainty")
                        Spacer()
                        Text("\u{00B1}")
                            .foregroundColor(.secondary)
                        TextField("Uncertainty", text: $uncertaintyText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 70)
                    }
                }

                Section("Data Quality") {
                    Toggle("Questionable data", isOn: $isQuestionable)
                    if isQuestionable {
                        TextField("Reason (optional)", text: $questionableReason)
                    }
                }

                Section("Observation Note") {
                    TextEditor(text: $note)
                        .frame(minHeight: 90)
                        .accessibilityLabel("Observation note")
                }

                Section {
                    TextEditor(text: $editReason)
                        .frame(minHeight: 70)
                        .accessibilityLabel("Why was this record edited? Optional")
                } header: {
                    Text("Edit Reason")
                } footer: {
                    Text("Saving creates an audit entry. Previous raw values remain in the audit history.")
                }

                Section("Recorded Metadata") {
                    HStack(alignment: .top) {
                        Text("Submitted")
                        Spacer()
                        Text(original.submittedAt, format: .dateTime.year().month().day().hour().minute().second())
                            .multilineTextAlignment(.trailing)
                    }
                    HStack(alignment: .top) {
                        Text("Source")
                        Spacer()
                        Text(original.source)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Observation ID")
                        Text(original.id.uuidString)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if !original.auditHistory.isEmpty {
                    Section("Audit History") {
                        ForEach(original.auditHistory.sorted { $0.editedAt > $1.editedAt }) { entry in
                            AuditEntryRow(entry: entry)
                        }
                    }
                }
            }
            .navigationTitle("Edit Observation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(validatedStepCount == nil || validatedUncertainty == nil)
                }
            }
            .presentedErrorAlert($presentedError)
        }
        .navigationViewStyle(.stack)
    }

    private var validatedStepCount: Int? {
        guard let value = Int(stepCountText), value >= 0 else { return nil }
        return value
    }

    private var validatedUncertainty: Int? {
        guard let value = Int(uncertaintyText), value >= 0 else { return nil }
        return value
    }

    private func save() {
        guard let stepCount = validatedStepCount, let uncertainty = validatedUncertainty else {
            presentedError = PresentedError(
                title: "Invalid Values",
                message: "Step count and measurement uncertainty must be zero or a positive whole number."
            )
            return
        }

        var updated = original
        updated.stepCount = stepCount
        updated.movementMode = movementMode
        updated.measurementUncertainty = uncertainty
        updated.note = note.nilIfBlank
        updated.isQuestionable = isQuestionable
        updated.questionableReason = isQuestionable ? questionableReason.nilIfBlank : nil

        do {
            try store.updateObservation(
                id: original.id,
                stepCount: updated.stepCount,
                movementMode: updated.movementMode,
                measurementUncertainty: updated.measurementUncertainty,
                note: updated.note,
                isQuestionable: updated.isQuestionable,
                questionableReason: updated.questionableReason,
                editReason: editReason.nilIfBlank
            )
            dismiss()
        } catch {
            presentedError = PresentedError(title: "Unable to Save Observation", error: error)
        }
    }
}

private struct AuditEntryRow: View {
    let entry: ObservationAuditEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.editedAt, format: .dateTime.year().month().day().hour().minute().second())
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text("Steps")
                Spacer()
                HStack(spacing: 5) {
                    Text("\(entry.previousStepCount)")
                    Image(systemName: "arrow.right")
                        .accessibilityLabel("changed to")
                    Text("\(entry.newStepCount)")
                }
                .monospacedDigit()
            }

            HStack(alignment: .top) {
                Text("Mode")
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(entry.previousMovementMode.displayName)
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                            .accessibilityLabel("changed to")
                        Text(entry.newMovementMode.displayName)
                    }
                }
            }

            if let reason = entry.reason {
                Text("Reason: \(reason)")
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
