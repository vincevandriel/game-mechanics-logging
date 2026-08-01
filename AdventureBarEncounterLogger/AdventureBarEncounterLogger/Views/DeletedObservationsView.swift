import SwiftUI

struct DeletedObservationsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let session: EncounterSession

    @State private var restoring: DeletedObservation?
    @State private var presentedError: PresentedError?

    var body: some View {
        NavigationView {
            List {
                if deletedItems.isEmpty {
                    Text("There are no temporarily deleted observations for this session.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(deletedItems) { deleted in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Encounter #\(deleted.observation.encounterNumber)")
                                    .font(.headline)
                                Text("Deleted \(deleted.deletedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("\(deleted.observation.stepCount) steps")
                                    .font(.headline.monospacedDigit())
                                Text(deleted.observation.movementMode.displayName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { restoring = deleted }
                        .swipeActions {
                            Button("Restore") { restoring = deleted }
                                .tint(.green)
                        }
                        .accessibilityHint("Double-tap to restore this observation")
                    }
                }
            }
            .navigationTitle("Recently Deleted")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(item: $restoring) { item in
                Alert(
                    title: Text("Restore Observation?"),
                    message: Text("Encounter #\(item.observation.encounterNumber) will return to \(session.name)."),
                    primaryButton: .default(Text("Restore")) {
                        restore(item)
                    },
                    secondaryButton: .cancel()
                )
            }
            .presentedErrorAlert($presentedError)
        }
        .navigationViewStyle(.stack)
    }

    private var deletedItems: [DeletedObservation] {
        store.deletedObservations(for: session.id)
            .sorted { $0.deletedAt > $1.deletedAt }
    }

    private func restore(_ item: DeletedObservation) {
        do {
            try store.restoreDeletedObservation(id: item.id)
        } catch {
            presentedError = PresentedError(title: "Unable to Restore Observation", error: error)
        }
    }
}
