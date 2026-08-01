import SwiftUI

enum ObservationSortOption: String, CaseIterable, Identifiable {
    case encounterNumber = "Encounter Number"
    case timestamp = "Timestamp"
    case stepCount = "Step Count"
    case movementMode = "Movement Mode"

    var id: String { rawValue }
}

enum ObservationFilter: String, CaseIterable, Identifiable {
    case all = "All Modes"
    case walking = "Walking"
    case running = "Running"
    case mixedUncertain = "Mixed/Uncertain"

    var id: String { rawValue }

    var movementMode: MovementMode? {
        switch self {
        case .all: return nil
        case .walking: return .walking
        case .running: return .running
        case .mixedUncertain: return .mixedUncertain
        }
    }
}

struct RecordsView: View {
    @EnvironmentObject private var store: AppStore

    @State private var selectedSessionID: UUID?
    @State private var sortOption: ObservationSortOption = .encounterNumber
    @State private var filter: ObservationFilter = .all
    @State private var searchText = ""
    @State private var editingObservation: EncounterObservation?
    @State private var deletingObservation: EncounterObservation?
    @State private var showingSessions = false
    @State private var showingDeletedHistory = false
    @State private var presentedError: PresentedError?

    var body: some View {
        NavigationView {
            Group {
                if let session = selectedSession {
                    List {
                        Section {
                            sessionSelector(session)
                        }

                        if displayedObservations.isEmpty {
                            emptyRecordsRow
                        } else {
                            Section("Observations") {
                                ForEach(displayedObservations) { observation in
                                    ObservationRow(observation: observation)
                                        .contentShape(Rectangle())
                                        .onTapGesture { editingObservation = observation }
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button(role: .destructive) {
                                                deletingObservation = observation
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                            Button {
                                                editingObservation = observation
                                            } label: {
                                                Label("Edit", systemImage: "pencil")
                                            }
                                            .tint(.accentColor)
                                        }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "folder.badge.plus")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No Session Available")
                            .font(.headline)
                        Button("Manage Sessions") { showingSessions = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Records")
            .searchable(text: $searchText, prompt: "Search session and notes")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showingDeletedHistory = true
                    } label: {
                        Image(systemName: "trash.slash")
                    }
                    .accessibilityLabel("Recently deleted observations")
                    .disabled(selectedSession.map { store.deletedObservations(for: $0.id).isEmpty } ?? true)

                    sortAndFilterMenu

                    Button {
                        showingSessions = true
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Manage sessions")
                }
            }
            .sheet(item: $editingObservation) { observation in
                ObservationEditorView(observation: observation)
                    .environmentObject(store)
            }
            .sheet(isPresented: $showingSessions) {
                SessionManagementView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showingDeletedHistory) {
                if let session = selectedSession {
                    DeletedObservationsView(session: session)
                        .environmentObject(store)
                }
            }
            .alert(item: $deletingObservation) { observation in
                Alert(
                    title: Text("Delete Observation?"),
                    message: Text("Encounter #\(observation.encounterNumber), \(observation.stepCount) steps, will move to the temporary deletion history."),
                    primaryButton: .destructive(Text("Delete")) {
                        delete(observation)
                    },
                    secondaryButton: .cancel()
                )
            }
            .presentedErrorAlert($presentedError)
            .onAppear(perform: ensureSelection)
            .onChange(of: store.state.activeSessionID) { _ in ensureSelection() }
            .onChange(of: store.state.sessions.map(\.id)) { _ in ensureSelection() }
        }
        .navigationViewStyle(.stack)
    }

    private var selectedSession: EncounterSession? {
        let id = selectedSessionID ?? store.state.activeSessionID
        return store.state.sessions.first { $0.id == id }
    }

    private var displayedObservations: [EncounterObservation] {
        guard let session = selectedSession else { return [] }
        let query = normalized(searchText)
        let sessionNameMatches = [
            session.name,
            session.notes ?? "",
            session.testingConditionNotes ?? "",
            session.dungeon ?? "",
            session.mapAreaDescription ?? ""
        ].contains { normalized($0).contains(query) }
        var values = store.observations(for: session.id).filter { observation in
            let matchesMode = filter.movementMode.map { observation.movementMode == $0 } ?? true
            guard matchesMode else { return false }
            guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            return sessionNameMatches
                || normalized(observation.note ?? "").contains(query)
                || normalized(observation.questionableReason ?? "").contains(query)
        }

        values.sort { lhs, rhs in
            switch sortOption {
            case .encounterNumber:
                return lhs.encounterNumber < rhs.encounterNumber
            case .timestamp:
                return lhs.submittedAt < rhs.submittedAt
            case .stepCount:
                return lhs.stepCount == rhs.stepCount
                    ? lhs.encounterNumber < rhs.encounterNumber
                    : lhs.stepCount < rhs.stepCount
            case .movementMode:
                return lhs.movementMode.displayName == rhs.movementMode.displayName
                    ? lhs.encounterNumber < rhs.encounterNumber
                    : lhs.movementMode.displayName < rhs.movementMode.displayName
            }
        }
        return values
    }

    private var sortAndFilterMenu: some View {
        Menu {
            Menu("Sort") {
                Picker("Sort", selection: $sortOption) {
                    ForEach(ObservationSortOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            }
            Menu("Filter") {
                Picker("Movement mode", selection: $filter) {
                    ForEach(ObservationFilter.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            }
        } label: {
            Image(systemName: filter == .all ? "arrow.up.arrow.down" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Sort and filter observations")
    }

    private func sessionSelector(_ session: EncounterSession) -> some View {
        Menu {
            ForEach(store.state.sessions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { candidate in
                Button {
                    selectedSessionID = candidate.id
                } label: {
                    if candidate.id == session.id {
                        Label(candidate.name, systemImage: "checkmark")
                    } else {
                        Text(candidate.name)
                    }
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Viewing Session")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(session.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .accessibilityHint("Choose another session to view")
    }

    private var emptyRecordsRow: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text(searchText.isEmpty && filter == .all ? "No observations in this session" : "No matching observations")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private func ensureSelection() {
        if let selectedSessionID, store.state.sessions.contains(where: { $0.id == selectedSessionID }) {
            return
        }
        selectedSessionID = store.state.activeSessionID
    }

    private func delete(_ observation: EncounterObservation) {
        do {
            try store.deleteObservation(id: observation.id)
        } catch {
            presentedError = PresentedError(title: "Unable to Delete Observation", error: error)
        }
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

struct ObservationRow: View {
    let observation: EncounterObservation

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("#\(observation.encounterNumber)")
                        .font(.headline.monospacedDigit())
                    if observation.isQuestionable {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .accessibilityLabel("Questionable data")
                    }
                }
                Text(observation.submittedAt, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(observation.submittedAt, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(observation.stepCount)")
                    .font(.title2.bold().monospacedDigit())
                Text(observation.movementMode.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Double-tap to edit this observation")
    }

    private var accessibilityDescription: String {
        var value = "Encounter \(observation.encounterNumber), \(observation.stepCount) steps, \(observation.movementMode.displayName), submitted \(observation.submittedAt.formatted(date: .abbreviated, time: .shortened))"
        if observation.isQuestionable { value += ", marked questionable" }
        return value
    }
}
