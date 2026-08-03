import Combine
import Foundation

public enum AppStoreError: LocalizedError, Equatable {
    case counterOverflow
    case zeroSubmissionRequiresConfirmation
    case modeChangeRequiresConfirmation
    case sessionChangeRequiresConfirmation
    case activeSessionHasUnfinishedCount
    case undoRequiresCurrentCountConfirmation
    case noUndoAvailable
    case noRedoAvailable
    case sessionNotFound(UUID)
    case observationNotFound(UUID)
    case deletedObservationNotFound(UUID)
    case sessionNameRequired
    case archivedSessionCannotBeActive
    case cannotArchiveOnlyActiveSession
    case invalidStepCount
    case invalidMeasurementUncertainty
    case duplicateEncounterNumber
    case duplicateObservationUUID(UUID)
    case invalidImportedState(String)

    public var errorDescription: String? {
        switch self {
        case .counterOverflow: return "The counter cannot be increased further."
        case .zeroSubmissionRequiresConfirmation: return "The current count is zero. Confirm before recording a zero-value observation."
        case .modeChangeRequiresConfirmation: return "Choose whether to reset or preserve the current count before switching movement mode."
        case .sessionChangeRequiresConfirmation: return "Choose whether to reset or preserve the unfinished count before changing the active session."
        case .activeSessionHasUnfinishedCount: return "Resolve the unfinished count before archiving or deleting the active session."
        case .undoRequiresCurrentCountConfirmation: return "Choose whether Undo should replace or add the current unfinished count."
        case .noUndoAvailable: return "There is no submitted observation available to undo in the active session."
        case .noRedoAvailable: return "There is no undo operation available to reverse."
        case .sessionNotFound(let id): return "Session \(id.uuidString) was not found."
        case .observationNotFound(let id): return "Observation \(id.uuidString) was not found."
        case .deletedObservationNotFound(let id): return "Deleted observation \(id.uuidString) is no longer available."
        case .sessionNameRequired: return "A session name is required."
        case .archivedSessionCannotBeActive: return "An archived session cannot be the active logging session."
        case .cannotArchiveOnlyActiveSession: return "Create or restore another session before archiving the only active session."
        case .invalidStepCount: return "Step count cannot be negative."
        case .invalidMeasurementUncertainty: return "Measurement uncertainty cannot be negative."
        case .duplicateEncounterNumber: return "That encounter sequence number is already in use."
        case .duplicateObservationUUID(let id): return "Observation UUID \(id.uuidString) already exists."
        case .invalidImportedState(let message): return "Imported data cannot be applied: \(message)"
        }
    }
}

public struct PCTransferStatus: Equatable, Sendable {
    public var message: String
    public var succeeded: Bool
    public var automatic: Bool
    public var timestamp: Date

    public init(message: String, succeeded: Bool, automatic: Bool, timestamp: Date) {
        self.message = message
        self.succeeded = succeeded
        self.automatic = automatic
        self.timestamp = timestamp
    }
}

@MainActor
public final class AppStore: ObservableObject {
    @Published public private(set) var state: PersistentAppState
    @Published public private(set) var feedbackMessage: String?
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var lastPCTransferStatus: PCTransferStatus?

    public let persistenceService: PersistenceService
    public let exportService: ExportService
    public let importService: ImportService
    public let snapshotService: ExportSnapshotService
    public let localTransferService: LocalNetworkTransferService

    private let now: () -> Date
    private let makeUUID: () -> UUID
    private let snapshotFileWriter: SnapshotFileWriter
    private var automaticPCSyncTask: Task<Void, Never>?
    private var snapshotRefreshTask: Task<Void, Never>?
    private var snapshotRefreshGeneration: UInt64 = 0

    public convenience init() throws {
        try self.init(persistenceService: PersistenceService.live())
    }

    public init(
        persistenceService: PersistenceService,
        exportService: ExportService = ExportService(),
        importService: ImportService = ImportService(),
        localTransferService: LocalNetworkTransferService = LocalNetworkTransferService(),
        now: @escaping () -> Date = Date.init,
        makeUUID: @escaping () -> UUID = UUID.init
    ) throws {
        self.persistenceService = persistenceService
        self.exportService = exportService
        self.importService = importService
        self.localTransferService = localTransferService
        let snapshotService = ExportSnapshotService(directoryURL: persistenceService.documentsDirectoryURL, exportService: exportService)
        self.snapshotService = snapshotService
        self.snapshotFileWriter = SnapshotFileWriter(service: snapshotService)
        self.now = now
        self.makeUUID = makeUUID
        self.state = try persistenceService.loadOrCreate(now: now())
    }

    deinit {
        automaticPCSyncTask?.cancel()
        snapshotRefreshTask?.cancel()
    }

    public var currentCount: Int { state.counter.currentCount }
    public var selectedBaseMode: MovementMode { state.counter.selectedBaseMode }
    public var currentIntervalMode: MovementMode { state.counter.currentIntervalMode }
    public var activeSession: EncounterSession? { state.activeSession }

    public var canUndo: Bool {
        guard let pending = state.pendingUndo, pending.phase == .canUndoSubmission else { return false }
        return pending.observation.sessionID == state.activeSessionID
            && state.observations.contains { $0.id == pending.observation.id }
    }

    public var canRedoUndo: Bool {
        guard let pending = state.pendingUndo, pending.phase == .canRedoUndo else { return false }
        return pending.observation.sessionID == state.activeSessionID
            && !state.observations.contains { $0.id == pending.observation.id }
    }

    public var undoRequiresCurrentCountConfirmation: Bool {
        canUndo && currentCount > 0 && state.settings.confirmUndoReplaceNonzero
    }

    @discardableResult
    public func increment() throws -> Int {
        guard state.counter.currentCount < Int.max else { throw AppStoreError.counterOverflow }
        var next = state
        let requiresFullSave = next.pendingUndo?.phase == .canRedoUndo
        clearRedoIfNeeded(in: &next)
        next.counter.currentCount += 1
        next.counter.lastChangedAt = now()
        if requiresFullSave {
            try commit(next)
        } else {
            try commitCounterCheckpoint(next)
        }
        return next.counter.currentCount
    }

    @discardableResult
    public func decrement() throws -> Int {
        guard state.counter.currentCount > 0 else { return 0 }
        var next = state
        let requiresFullSave = next.pendingUndo?.phase == .canRedoUndo
        clearRedoIfNeeded(in: &next)
        next.counter.currentCount -= 1
        next.counter.lastChangedAt = now()
        if requiresFullSave {
            try commit(next)
        } else {
            try commitCounterCheckpoint(next)
        }
        return next.counter.currentCount
    }

    public func changeMode(to mode: MovementMode, resolution: ModeChangeResolution? = nil) throws {
        guard mode == .walking || mode == .running else { throw StateValidationError.invalidCounterMode }
        guard mode != state.counter.selectedBaseMode else { return }
        if state.counter.currentCount > 0 && resolution == nil {
            throw AppStoreError.modeChangeRequiresConfirmation
        }

        var next = state
        let requiresFullSave = next.pendingUndo?.phase == .canRedoUndo
        clearRedoIfNeeded(in: &next)
        if next.counter.currentCount == 0 {
            next.counter.selectedBaseMode = mode
            next.counter.currentIntervalIsMixed = false
        } else {
            switch resolution {
            case .resetAndSwitch:
                next.counter.currentCount = 0
                next.counter.selectedBaseMode = mode
                next.counter.currentIntervalIsMixed = false
            case .preserveAndMarkMixed:
                next.counter.selectedBaseMode = mode
                next.counter.currentIntervalIsMixed = true
            case .none:
                throw AppStoreError.modeChangeRequiresConfirmation
            }
        }
        next.counter.lastChangedAt = now()
        if requiresFullSave {
            try commit(next, feedback: "Mode: \(mode.displayName)")
        } else {
            try commitCounterCheckpoint(next, feedback: "Mode: \(mode.displayName)")
        }
    }

    @discardableResult
    public func submitCurrentCount(allowZero: Bool = false) throws -> EncounterObservation {
        if state.counter.currentCount == 0 && state.settings.confirmZeroSubmission && !allowZero {
            throw AppStoreError.zeroSubmissionRequiresConfirmation
        }
        guard let sessionIndex = state.sessions.firstIndex(where: { $0.id == state.activeSessionID }) else {
            throw AppStoreError.sessionNotFound(state.activeSessionID)
        }
        guard !state.sessions[sessionIndex].isArchived else { throw AppStoreError.archivedSessionCannotBeActive }

        let timestamp = now()
        let activeNumbers = state.observations
            .filter { $0.sessionID == state.activeSessionID }
            .map(\.encounterNumber)
        let temporarilyDeletedNumbers = state.deletedObservations
            .map(\.observation)
            .filter { $0.sessionID == state.activeSessionID }
            .map(\.encounterNumber)
        let highestEncounterNumber = max(
            activeNumbers.max() ?? 0,
            temporarilyDeletedNumbers.max() ?? 0
        )
        guard highestEncounterNumber < Int.max else { throw AppStoreError.counterOverflow }
        let nextNumber = highestEncounterNumber + 1
        let observation = EncounterObservation(
            id: makeUUID(),
            sessionID: state.activeSessionID,
            encounterNumber: nextNumber,
            stepCount: state.counter.currentCount,
            movementMode: state.counter.currentIntervalMode,
            submittedAt: timestamp,
            measurementUncertainty: state.settings.defaultMeasurementUncertainty,
            source: "iPhone logger"
        )

        var next = state
        next.observations.append(observation)
        next.sessions[sessionIndex].lastModifiedAt = timestamp
        next.pendingUndo = PendingUndo(
            id: makeUUID(),
            observation: observation,
            selectorModeAtSubmission: state.counter.selectedBaseMode,
            createdAt: timestamp
        )
        next.counter.currentCount = 0
        next.counter.currentIntervalIsMixed = false
        next.counter.lastChangedAt = timestamp
        try commit(next, feedback: "Recorded: \(observation.stepCount) \(observation.movementMode.displayName)")
        refreshDerivedCopiesAfterMutation()
        return observation
    }

    public func undoLastSubmission(strategy: UndoStrategy? = nil) throws -> EncounterObservation {
        guard let pending = state.pendingUndo,
              pending.phase == .canUndoSubmission,
              pending.observation.sessionID == state.activeSessionID,
              let observationIndex = state.observations.firstIndex(where: { $0.id == pending.observation.id }) else {
            throw AppStoreError.noUndoAvailable
        }
        if state.counter.currentCount > 0 && state.settings.confirmUndoReplaceNonzero && strategy == nil {
            throw AppStoreError.undoRequiresCurrentCountConfirmation
        }

        let currentBeforeUndo = state.counter
        let unfinishedMode = currentBeforeUndo.currentIntervalMode
        let restoredCount: Int
        switch strategy ?? .replace {
        case .replace:
            restoredCount = pending.observation.stepCount
        case .addCurrentCount:
            let (sum, overflow) = pending.observation.stepCount.addingReportingOverflow(state.counter.currentCount)
            guard !overflow else { throw AppStoreError.counterOverflow }
            restoredCount = sum
        }

        let timestamp = now()
        var next = state
        next.observations.remove(at: observationIndex)
        next.counter.currentCount = restoredCount
        let combinesNonzeroUnfinishedCount = (strategy == .addCurrentCount) && currentBeforeUndo.currentCount > 0
        let combinedModeIsMixed = combinesNonzeroUnfinishedCount
            && (pending.observation.movementMode == .mixedUncertain
                || unfinishedMode == .mixedUncertain
                || pending.observation.movementMode != unfinishedMode)
        if combinedModeIsMixed {
            next.counter.selectedBaseMode = currentBeforeUndo.selectedBaseMode
            next.counter.currentIntervalIsMixed = true
        } else if pending.observation.movementMode == .mixedUncertain {
            next.counter.selectedBaseMode = pending.selectorModeAtSubmission
            next.counter.currentIntervalIsMixed = true
        } else {
            next.counter.selectedBaseMode = pending.observation.movementMode
            next.counter.currentIntervalIsMixed = false
        }
        next.counter.lastChangedAt = timestamp
        next.pendingUndo?.phase = .canRedoUndo
        next.pendingUndo?.counterBeforeUndo = currentBeforeUndo
        next.pendingUndo?.undoneAt = timestamp
        touchSession(pending.observation.sessionID, in: &next, at: timestamp)
        try commit(next, feedback: "Restored: \(restoredCount) \(pending.observation.movementMode.displayName)")
        refreshDerivedCopiesAfterMutation()
        return pending.observation
    }

    public func redoUndo() throws {
        guard let pending = state.pendingUndo,
              pending.phase == .canRedoUndo,
              let counterBeforeUndo = pending.counterBeforeUndo,
              pending.observation.sessionID == state.activeSessionID else {
            throw AppStoreError.noRedoAvailable
        }
        guard !state.observations.contains(where: { $0.id == pending.observation.id }) else {
            throw AppStoreError.duplicateObservationUUID(pending.observation.id)
        }
        guard !state.observations.contains(where: {
            $0.sessionID == pending.observation.sessionID && $0.encounterNumber == pending.observation.encounterNumber
        }) else { throw AppStoreError.duplicateEncounterNumber }

        var next = state
        next.observations.append(pending.observation)
        next.counter = counterBeforeUndo
        next.pendingUndo?.phase = .canUndoSubmission
        next.pendingUndo?.counterBeforeUndo = nil
        next.pendingUndo?.undoneAt = nil
        touchSession(pending.observation.sessionID, in: &next, at: now())
        try commit(next, feedback: "Undo reversed")
        refreshDerivedCopiesAfterMutation()
    }

    @discardableResult
    public func createSession(
        name: String,
        gameVersion: String = "Nintendo Switch",
        dungeon: String? = nil,
        mapAreaDescription: String? = nil,
        testingConditionNotes: String? = nil,
        notes: String? = nil,
        makeActive: Bool = true,
        activationResolution: SessionSwitchResolution? = nil
    ) throws -> EncounterSession {
        guard name.nilIfBlank != nil else { throw AppStoreError.sessionNameRequired }
        if makeActive && state.counter.currentCount > 0 && activationResolution == nil {
            throw AppStoreError.sessionChangeRequiresConfirmation
        }
        let timestamp = now()
        let session = EncounterSession(
            id: makeUUID(),
            name: name,
            createdAt: timestamp,
            lastModifiedAt: timestamp,
            gameVersion: gameVersion,
            dungeon: dungeon,
            mapAreaDescription: mapAreaDescription,
            testingConditionNotes: testingConditionNotes,
            notes: notes
        )
        var next = state
        next.sessions.append(session)
        if makeActive {
            next.activeSessionID = session.id
            next.pendingUndo = nil
            applySessionSwitchResolution(activationResolution, to: &next)
        }
        try commit(next, feedback: "Session created")
        refreshDerivedCopiesAfterMutation()
        return session
    }

    public func updateSession(_ session: EncounterSession) throws {
        guard let index = state.sessions.firstIndex(where: { $0.id == session.id }) else {
            throw AppStoreError.sessionNotFound(session.id)
        }
        guard session.name.nilIfBlank != nil else { throw AppStoreError.sessionNameRequired }
        if session.id == state.activeSessionID && session.isArchived { throw AppStoreError.archivedSessionCannotBeActive }
        var updated = session
        updated.name = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.lastModifiedAt = now()
        var next = state
        next.sessions[index] = updated
        try commit(next, feedback: "Session updated")
        refreshDerivedCopiesAfterMutation()
    }

    public func renameSession(id: UUID, name: String) throws {
        guard var session = state.sessions.first(where: { $0.id == id }) else { throw AppStoreError.sessionNotFound(id) }
        session.name = name
        try updateSession(session)
    }

    public func setActiveSession(id: UUID, resolution: SessionSwitchResolution? = nil) throws {
        guard let session = state.sessions.first(where: { $0.id == id }) else { throw AppStoreError.sessionNotFound(id) }
        guard !session.isArchived else { throw AppStoreError.archivedSessionCannotBeActive }
        guard id != state.activeSessionID else { return }
        if state.counter.currentCount > 0 && resolution == nil {
            throw AppStoreError.sessionChangeRequiresConfirmation
        }
        var next = state
        next.activeSessionID = id
        next.pendingUndo = nil
        applySessionSwitchResolution(resolution, to: &next)
        try commit(next, feedback: "Active session: \(session.name)")
        refreshDerivedCopiesAfterMutation()
    }

    public func setSessionArchived(id: UUID, isArchived: Bool) throws {
        guard let index = state.sessions.firstIndex(where: { $0.id == id }) else { throw AppStoreError.sessionNotFound(id) }
        var next = state
        if isArchived && id == next.activeSessionID {
            guard next.counter.currentCount == 0 else { throw AppStoreError.activeSessionHasUnfinishedCount }
            guard let replacement = next.sessions.first(where: { $0.id != id && !$0.isArchived }) else {
                throw AppStoreError.cannotArchiveOnlyActiveSession
            }
            next.activeSessionID = replacement.id
            next.pendingUndo = nil
        }
        next.sessions[index].isArchived = isArchived
        next.sessions[index].lastModifiedAt = now()
        try commit(next, feedback: isArchived ? "Session archived" : "Session restored")
        refreshDerivedCopiesAfterMutation()
    }

    public func deleteSession(id: UUID) throws {
        guard state.sessions.contains(where: { $0.id == id }) else { throw AppStoreError.sessionNotFound(id) }
        if id == state.activeSessionID && state.counter.currentCount > 0 {
            throw AppStoreError.activeSessionHasUnfinishedCount
        }
        var next = state
        next.sessions.removeAll { $0.id == id }
        next.observations.removeAll { $0.sessionID == id }
        next.deletedObservations.removeAll { $0.observation.sessionID == id }
        if next.pendingUndo?.observation.sessionID == id { next.pendingUndo = nil }

        if next.sessions.isEmpty {
            let timestamp = now()
            let replacement = EncounterSession(
                id: makeUUID(),
                name: InitialSeed.loggerSessionName,
                createdAt: timestamp,
                lastModifiedAt: timestamp,
                gameVersion: InitialSeed.gameVersion
            )
            next.sessions = [replacement]
            next.activeSessionID = replacement.id
        } else if id == state.activeSessionID {
            if let replacement = next.sessions.first(where: { !$0.isArchived }) {
                next.activeSessionID = replacement.id
            } else {
                next.sessions[0].isArchived = false
                next.activeSessionID = next.sessions[0].id
            }
        }
        try commit(next, feedback: "Session deleted")
        refreshDerivedCopiesAfterMutation()
    }

    public func observations(for sessionID: UUID) -> [EncounterObservation] {
        state.observations(for: sessionID)
    }

    @discardableResult
    public func markObservationQuestionable(
        id: UUID,
        reason: String,
        noteToAppend: String? = nil
    ) throws -> EncounterObservation {
        guard let observation = state.observations.first(where: { $0.id == id }) else {
            throw AppStoreError.observationNotFound(id)
        }
        let appendedNote: String?
        if let addition = noteToAppend?.nilIfBlank {
            if let existing = observation.note?.nilIfBlank, !existing.contains(addition) {
                appendedNote = "\(existing)\n\(addition)"
            } else {
                appendedNote = observation.note ?? addition
            }
        } else {
            appendedNote = observation.note
        }
        return try updateObservation(
            id: observation.id,
            stepCount: observation.stepCount,
            movementMode: observation.movementMode,
            measurementUncertainty: observation.measurementUncertainty,
            note: appendedNote,
            isQuestionable: true,
            questionableReason: reason,
            editReason: "Marked questionable: \(reason)"
        )
    }

    public func deletedObservations(for sessionID: UUID? = nil) -> [DeletedObservation] {
        state.deletedObservations
            .filter { sessionID == nil || $0.observation.sessionID == sessionID }
            .sorted { $0.deletedAt > $1.deletedAt }
    }

    @discardableResult
    public func updateObservation(
        id: UUID,
        stepCount: Int,
        movementMode: MovementMode,
        measurementUncertainty: Int,
        note: String?,
        isQuestionable: Bool,
        questionableReason: String?,
        editReason: String? = nil
    ) throws -> EncounterObservation {
        guard stepCount >= 0 else { throw AppStoreError.invalidStepCount }
        guard measurementUncertainty >= 0 else { throw AppStoreError.invalidMeasurementUncertainty }
        guard let index = state.observations.firstIndex(where: { $0.id == id }) else {
            throw AppStoreError.observationNotFound(id)
        }
        let previous = state.observations[index]
        let timestamp = now()
        let audit = ObservationAuditEntry(
            id: makeUUID(),
            previousStepCount: previous.stepCount,
            newStepCount: stepCount,
            previousMovementMode: previous.movementMode,
            newMovementMode: movementMode,
            editedAt: timestamp,
            reason: editReason
        )
        var updated = previous
        updated.stepCount = stepCount
        updated.movementMode = movementMode
        updated.measurementUncertainty = measurementUncertainty
        updated.note = note?.nilIfBlank
        updated.isQuestionable = isQuestionable
        updated.questionableReason = isQuestionable ? questionableReason?.nilIfBlank : nil
        updated.lastEditedAt = timestamp
        updated.auditHistory.append(audit)

        var next = state
        next.observations[index] = updated
        if next.pendingUndo?.observation.id == id { next.pendingUndo = nil }
        touchSession(updated.sessionID, in: &next, at: timestamp)
        try commit(next, feedback: "Observation updated")
        refreshDerivedCopiesAfterMutation()
        return updated
    }

    @discardableResult
    public func deleteObservation(id: UUID) throws -> DeletedObservation {
        guard let index = state.observations.firstIndex(where: { $0.id == id }) else {
            throw AppStoreError.observationNotFound(id)
        }
        let deleted = DeletedObservation(observation: state.observations[index], deletedAt: now())
        var next = state
        next.observations.remove(at: index)
        next.deletedObservations.removeAll { $0.id == id }
        next.deletedObservations.append(deleted)
        if next.pendingUndo?.observation.id == id { next.pendingUndo = nil }
        touchSession(deleted.observation.sessionID, in: &next, at: deleted.deletedAt)
        try commit(next, feedback: "Observation deleted - Restore is available")
        refreshDerivedCopiesAfterMutation()
        return deleted
    }

    @discardableResult
    public func restoreDeletedObservation(id: UUID) throws -> EncounterObservation {
        guard let deletedIndex = state.deletedObservations.firstIndex(where: { $0.id == id }) else {
            throw AppStoreError.deletedObservationNotFound(id)
        }
        let observation = state.deletedObservations[deletedIndex].observation
        guard state.sessions.contains(where: { $0.id == observation.sessionID }) else {
            throw AppStoreError.sessionNotFound(observation.sessionID)
        }
        guard !state.observations.contains(where: { $0.id == id }) else { throw AppStoreError.duplicateObservationUUID(id) }
        guard !state.observations.contains(where: {
            $0.sessionID == observation.sessionID && $0.encounterNumber == observation.encounterNumber
        }) else { throw AppStoreError.duplicateEncounterNumber }

        var next = state
        next.deletedObservations.remove(at: deletedIndex)
        next.observations.append(observation)
        touchSession(observation.sessionID, in: &next, at: now())
        try commit(next, feedback: "Observation restored")
        refreshDerivedCopiesAfterMutation()
        return observation
    }

    public func updateSettings(_ settings: AppSettings) throws {
        let receiverConfigurationChanged = state.settings.receiverConfiguration != settings.receiverConfiguration
        let automaticTransferWasDisabled = state.settings.automaticallySendSnapshotToPC
            && !settings.automaticallySendSnapshotToPC
        if receiverConfigurationChanged || automaticTransferWasDisabled {
            // A queued transfer captures its receiver configuration.  Never let
            // an upload continue after the user disables it or changes that
            // endpoint/credential tuple.
            automaticPCSyncTask?.cancel()
            automaticPCSyncTask = nil
        }
        var next = state
        next.settings = settings
        try commit(next, feedback: "Settings saved")
        if settings.createExportSnapshotsAfterEverySubmission {
            refreshSnapshotsIfEnabled()
        }
    }

    public func clearFeedback() {
        feedbackMessage = nil
        lastErrorMessage = nil
    }

    public func makeExport(
        selection: ExportSelection,
        format: ExportFormat,
        content: ExportContent
    ) throws -> ExportedFile {
        let exported = try exportService.export(
            state: state,
            selection: selection,
            format: format,
            content: content,
            now: now()
        )
        if state.settings.lastExportFormat != format {
            var next = state
            next.settings.lastExportFormat = format
            try commit(next)
        }
        return exported
    }

    @discardableResult
    public func writeExportToDocuments(
        selection: ExportSelection,
        format: ExportFormat,
        content: ExportContent
    ) throws -> URL {
        let exported = try makeExport(selection: selection, format: format, content: content)
        return try exportService.write(exported, to: persistenceService.documentsDirectoryURL)
    }

    public func previewImport(data: Data, filename: String) -> ImportPreview {
        importService.preview(data: data, filename: filename, existingState: state)
    }

    public func previewImport(fileURL: URL) throws -> ImportPreview {
        try importService.preview(fileURL: fileURL, existingState: state)
    }

    public func testPCConnection() async throws -> String {
        let message = try await localTransferService.testConnection(configuration: state.settings.receiverConfiguration)
        feedbackMessage = message
        return message
    }

    @discardableResult
    public func transferExport(
        selection: ExportSelection,
        format: ExportFormat,
        content: ExportContent
    ) async throws -> TransferReceipt {
        do {
            let exported = try makeExport(selection: selection, format: format, content: content)
            let receipt = try await localTransferService.upload(exported, configuration: state.settings.receiverConfiguration)
            feedbackMessage = receipt.message
            lastPCTransferStatus = PCTransferStatus(
                message: receipt.message,
                succeeded: true,
                automatic: false,
                timestamp: now()
            )
            return receipt
        } catch {
            lastPCTransferStatus = PCTransferStatus(
                message: error.localizedDescription,
                succeeded: false,
                automatic: false,
                timestamp: now()
            )
            throw error
        }
    }

    /// Applies a previously validated import. Replacement always creates a
    /// durable pre-import backup before the active store is changed.
    @discardableResult
    public func applyImport(_ preview: ImportPreview, mode: ImportMode) throws -> ImportResult {
        let result = try importService.applying(preview, to: state, mode: mode, now: now())
        if mode == .replace {
            _ = try persistenceService.createPreImportBackup(of: state, now: now())
        }
        var imported = result.state
        if imported.settings.pcReceiverUploadSecret.isEmpty {
            // Receiver credentials are deliberately redacted from portable exports.
            // Keep the locally provisioned endpoint and credential as one tuple so
            // an imported endpoint can never be paired with this device's secret.
            imported.settings.pcReceiverScheme = state.settings.pcReceiverScheme
            imported.settings.pcReceiverHost = state.settings.pcReceiverHost
            imported.settings.pcReceiverPort = state.settings.pcReceiverPort
            imported.settings.pcReceiverUploadSecret = state.settings.pcReceiverUploadSecret
            if !state.settings.pcReceiverUploadSecret.isEmpty {
                imported.settings.automaticallySendSnapshotToPC = state.settings.automaticallySendSnapshotToPC
            }
        }
        if !result.restoredCompleteBackup {
            imported.pendingUndo = nil
            if mode == .replace { imported.deletedObservations = [] }
        }
        try commit(
            imported,
            feedback: "Imported \(result.importedObservationCount) observations",
            rotateSourceStream: true
        )
        refreshDerivedCopiesAfterMutation()
        return result
    }

    private func commit(
        _ nextState: PersistentAppState,
        feedback: String? = nil,
        rotateSourceStream: Bool = false
    ) throws {
        var next = nextState
        next.fullStoreRevision = UUID()
        if rotateSourceStream {
            next.sourceStoreID = UUID()
            next.sourceMutationSequence = 1
        } else {
            next.sourceStoreID = state.sourceStoreID ?? next.sourceStoreID ?? UUID()
            let currentSequence = state.sourceMutationSequence ?? 0
            let proposedSequence = next.sourceMutationSequence ?? 0
            let baseline = max(currentSequence, proposedSequence)
            next.sourceMutationSequence = baseline == UInt64.max ? UInt64.max : baseline + 1
        }
        next.lastModifiedAt = now()
        try persistenceService.save(next)
        state = next
        feedbackMessage = feedback
        lastErrorMessage = nil
    }

    private func commitCounterCheckpoint(_ nextState: PersistentAppState, feedback: String? = nil) throws {
        try persistenceService.saveCounterCheckpoint(
            counter: nextState.counter,
            activeSessionID: nextState.activeSessionID,
            baseStoreRevision: state.fullStoreRevision,
            baseStoreLastModifiedAt: state.lastModifiedAt,
            now: now()
        )
        state = nextState
        feedbackMessage = feedback
        lastErrorMessage = nil
    }

    private func clearRedoIfNeeded(in state: inout PersistentAppState) {
        if state.pendingUndo?.phase == .canRedoUndo { state.pendingUndo = nil }
    }

    private func touchSession(_ id: UUID, in state: inout PersistentAppState, at date: Date) {
        if let index = state.sessions.firstIndex(where: { $0.id == id }) {
            state.sessions[index].lastModifiedAt = date
        }
    }

    private func applySessionSwitchResolution(
        _ resolution: SessionSwitchResolution?,
        to state: inout PersistentAppState
    ) {
        guard resolution == .resetCurrentCount else { return }
        state.counter.currentCount = 0
        state.counter.currentIntervalIsMixed = false
        state.counter.lastChangedAt = now()
    }

    private func refreshDerivedCopiesAfterMutation() {
        refreshSnapshotsIfEnabled()
        scheduleAutomaticPCSyncIfEnabled()
    }

    private func refreshSnapshotsIfEnabled() {
        guard state.settings.createExportSnapshotsAfterEverySubmission else { return }
        let service = snapshotService
        let writer = snapshotFileWriter
        let stateSnapshot = state
        let timestamp = now()
        snapshotRefreshGeneration &+= 1
        let generation = snapshotRefreshGeneration
        snapshotRefreshTask?.cancel()
        snapshotRefreshTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let payloads = try service.makeCurrentSnapshotPayloads(for: stateSnapshot, now: timestamp)
                try Task.checkCancellation()
                _ = try await writer.write(payloads, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                let message = "Data was saved, but export snapshots could not be updated: \(error.localizedDescription)"
                await self?.reportSnapshotFailure(message)
            }
        }
    }

    private func reportSnapshotFailure(_ message: String) {
        lastErrorMessage = message
    }

    func waitForPendingSnapshotRefreshForTesting() async {
        await snapshotRefreshTask?.value
    }

    func waitForPendingAutomaticPCSyncForTesting() async {
        await automaticPCSyncTask?.value
    }

    /// Sends a full raw JSON snapshot after the local commit has completed.
    /// The task is best-effort and deliberately cannot roll back or delay logging.
    /// A newer submission supersedes an older in-flight full snapshot.
    private func scheduleAutomaticPCSyncIfEnabled() {
        // Cancel first so a later mutation while synchronization is disabled (or
        // no longer configured correctly) cannot leave an older upload running.
        automaticPCSyncTask?.cancel()
        automaticPCSyncTask = nil

        let settings = state.settings
        let configuration = settings.receiverConfiguration
        guard settings.automaticallySendSnapshotToPC,
              configuration.host.nilIfBlank != nil,
              (1...65_535).contains(configuration.port),
              ReceiverRequestSigner.isValidSecret(configuration.uploadSecret, allowingEmpty: false) else {
            return
        }

        let stateSnapshot = state
        let exportTimestamp = now()
        let exporter = exportService
        let transfer = localTransferService
        automaticPCSyncTask = Task { [weak self] in
            do {
                let exportTask = Task.detached(priority: .utility) {
                    try exporter.export(
                        state: stateSnapshot,
                        selection: .allSessions,
                        format: .json,
                        content: .observationsAndSessionMetadata,
                        now: exportTimestamp
                    )
                }
                let exported = try await exportTask.value
                try Task.checkCancellation()
                let receipt = try await transfer.upload(exported, configuration: configuration)
                guard !Task.isCancelled else { return }
                self?.feedbackMessage = "Automatic PC snapshot sent: \(receipt.message)"
                self?.lastErrorMessage = nil
                self?.lastPCTransferStatus = PCTransferStatus(
                    message: receipt.message,
                    succeeded: true,
                    automatic: true,
                    timestamp: self?.now() ?? exportTimestamp
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.lastErrorMessage = "Data was saved locally, but automatic PC synchronization failed: \(error.localizedDescription)"
                self?.lastPCTransferStatus = PCTransferStatus(
                    message: error.localizedDescription,
                    succeeded: false,
                    automatic: true,
                    timestamp: self?.now() ?? exportTimestamp
                )
            }
        }
    }
}
