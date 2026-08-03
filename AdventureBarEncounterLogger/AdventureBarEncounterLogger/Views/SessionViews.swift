import SwiftUI

struct SessionManagementView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var showingCreateSession = false
    @State private var editingSession: EncounterSession?
    @State private var deletingSession: EncounterSession?
    @State private var requestedActiveSession: EncounterSession?
    @State private var showingSessionSwitchOptions = false
    @State private var presentedError: PresentedError?

    var body: some View {
        NavigationView {
            List {
                Section("Available Sessions") {
                    ForEach(activeSessions) { session in
                        sessionRow(session)
                    }
                }

                if !archivedSessions.isEmpty {
                    Section("Archived Sessions") {
                        ForEach(archivedSessions) { session in
                            sessionRow(session)
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingCreateSession = true
                    } label: {
                        Label("New Session", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingCreateSession) {
                SessionEditorView(session: nil)
                    .environmentObject(store)
            }
            .sheet(item: $editingSession) { session in
                SessionEditorView(session: session)
                    .environmentObject(store)
            }
            .alert(item: $deletingSession) { session in
                Alert(
                    title: Text("Delete Session?"),
                    message: Text("\(session.name) and all of its observations will be deleted. This cannot be undone from the session list."),
                    primaryButton: .destructive(Text("Delete")) {
                        delete(session)
                    },
                    secondaryButton: .cancel()
                )
            }
            .confirmationDialog(
                "Switch Active Session?",
                isPresented: $showingSessionSwitchOptions,
                titleVisibility: .visible
            ) {
                Button("Reset Count and Switch", role: .destructive) {
                    resolveSessionSwitch(.resetCurrentCount)
                }
                Button("Preserve Count and Switch") {
                    resolveSessionSwitch(.preserveCurrentCount)
                }
                Button("Cancel", role: .cancel) {
                    requestedActiveSession = nil
                }
            } message: {
                Text("The unfinished count is \(store.currentCount). Choose explicitly whether it belongs with the new active session.")
            }
            .presentedErrorAlert($presentedError)
        }
        .navigationViewStyle(.stack)
    }

    private var activeSessions: [EncounterSession] {
        store.state.sessions
            .filter { !$0.isArchived }
            .sorted { $0.lastModifiedAt > $1.lastModifiedAt }
    }

    private var archivedSessions: [EncounterSession] {
        store.state.sessions
            .filter(\.isArchived)
            .sorted { $0.lastModifiedAt > $1.lastModifiedAt }
    }

    private func sessionRow(_ session: EncounterSession) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.name)
                    .font(.headline)
                Text("\(store.observations(for: session.id).count) observations")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if session.isArchived {
                    Label("Archived", systemImage: "archivebox")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if store.state.activeSessionID == session.id {
                Text("Active")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.accentColor)
                    .accessibilityAddTraits(.isSelected)
            }

            Menu {
                if !session.isArchived && store.state.activeSessionID != session.id {
                    Button {
                        makeActive(session)
                    } label: {
                        Label("Make Active", systemImage: "checkmark.circle")
                    }
                }

                Button {
                    editingSession = session
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Button {
                    setArchived(session, archived: !session.isArchived)
                } label: {
                    Label(
                        session.isArchived ? "Restore" : "Archive",
                        systemImage: session.isArchived ? "tray.and.arrow.up" : "archivebox"
                    )
                }

                Button(role: .destructive) {
                    deletingSession = session
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Actions for \(session.name)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !session.isArchived else { return }
            makeActive(session)
        }
    }

    private func makeActive(_ session: EncounterSession) {
        guard store.state.activeSessionID != session.id else { return }
        if store.currentCount > 0 {
            requestedActiveSession = session
            showingSessionSwitchOptions = true
            return
        }
        activate(session, resolution: nil)
    }

    private func resolveSessionSwitch(_ resolution: SessionSwitchResolution) {
        guard let session = requestedActiveSession else { return }
        requestedActiveSession = nil
        activate(session, resolution: resolution)
    }

    private func activate(_ session: EncounterSession, resolution: SessionSwitchResolution?) {
        do {
            try store.setActiveSession(id: session.id, resolution: resolution)
            FeedbackController.play(
                .selection,
                hapticsEnabled: store.state.settings.hapticsEnabled,
                soundEnabled: store.state.settings.soundFeedbackEnabled
            )
        } catch {
            presentedError = PresentedError(title: "Unable to Select Session", error: error)
        }
    }

    private func setArchived(_ session: EncounterSession, archived: Bool) {
        do {
            try store.setSessionArchived(id: session.id, isArchived: archived)
        } catch {
            presentedError = PresentedError(title: "Unable to Update Session", error: error)
        }
    }

    private func delete(_ session: EncounterSession) {
        do {
            try store.deleteSession(id: session.id)
        } catch {
            presentedError = PresentedError(title: "Unable to Delete Session", error: error)
        }
    }
}

struct SessionEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private let originalSession: EncounterSession?

    @State private var name: String
    @State private var gameVersion: String
    @State private var dungeon: String
    @State private var mapAreaDescription: String
    @State private var testingConditionNotes: String
    @State private var notes: String
    @State private var showingCreationOptions = false
    @State private var presentedError: PresentedError?

    init(session: EncounterSession?) {
        originalSession = session
        _name = State(initialValue: session?.name ?? "")
        _gameVersion = State(initialValue: session?.gameVersion ?? "Nintendo Switch")
        _dungeon = State(initialValue: session?.dungeon ?? "")
        _mapAreaDescription = State(initialValue: session?.mapAreaDescription ?? "")
        _testingConditionNotes = State(initialValue: session?.testingConditionNotes ?? "")
        _notes = State(initialValue: session?.notes ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Session") {
                    TextField("Session name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Game version", text: $gameVersion)
                }

                Section("Optional Location") {
                    TextField("Dungeon or location", text: $dungeon)
                    TextField("Map-area description", text: $mapAreaDescription)
                }

                Section("Optional Notes") {
                    TextEditor(text: $testingConditionNotes)
                        .frame(minHeight: 90)
                        .accessibilityLabel("Testing-condition notes")
                    TextEditor(text: $notes)
                        .frame(minHeight: 90)
                        .accessibilityLabel("General notes")
                }
            }
            .navigationTitle(originalSession == nil ? "New Session" : "Edit Session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmedName.isEmpty || gameVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog(
                "Create and Activate Session?",
                isPresented: $showingCreationOptions,
                titleVisibility: .visible
            ) {
                Button("Reset Count and Create", role: .destructive) {
                    createNewSession(makeActive: true, resolution: .resetCurrentCount)
                }
                Button("Preserve Count and Create") {
                    createNewSession(makeActive: true, resolution: .preserveCurrentCount)
                }
                Button("Create Without Activating") {
                    createNewSession(makeActive: false, resolution: nil)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The unfinished count is \(store.currentCount). Preserving it deliberately assigns that interval to the new session.")
            }
            .presentedErrorAlert($presentedError)
        }
        .navigationViewStyle(.stack)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        if originalSession == nil && store.currentCount > 0 {
            showingCreationOptions = true
            return
        }
        do {
            if var session = originalSession {
                session.name = trimmedName
                session.gameVersion = gameVersion.trimmingCharacters(in: .whitespacesAndNewlines)
                session.dungeon = dungeon.nilIfBlank
                session.mapAreaDescription = mapAreaDescription.nilIfBlank
                session.testingConditionNotes = testingConditionNotes.nilIfBlank
                session.notes = notes.nilIfBlank
                try store.updateSession(session)
            } else { createNewSession(makeActive: true, resolution: nil); return }
            dismiss()
        } catch {
            presentedError = PresentedError(title: "Unable to Save Session", error: error)
        }
    }

    private func createNewSession(makeActive: Bool, resolution: SessionSwitchResolution?) {
        do {
            _ = try store.createSession(
                name: trimmedName,
                gameVersion: gameVersion.trimmingCharacters(in: .whitespacesAndNewlines),
                dungeon: dungeon.nilIfBlank,
                mapAreaDescription: mapAreaDescription.nilIfBlank,
                testingConditionNotes: testingConditionNotes.nilIfBlank,
                notes: notes.nilIfBlank,
                makeActive: makeActive,
                activationResolution: resolution
            )
            dismiss()
        } catch {
            presentedError = PresentedError(title: "Unable to Create Session", error: error)
        }
    }
}
