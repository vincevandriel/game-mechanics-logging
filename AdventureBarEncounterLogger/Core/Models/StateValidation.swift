import Foundation

public enum StateValidationError: LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)
    case noSessions
    case duplicateSessionID(UUID)
    case emptySessionName(UUID)
    case invalidActiveSession(UUID)
    case archivedActiveSession(UUID)
    case duplicateObservationID(UUID)
    case orphanedObservation(UUID)
    case duplicateEncounterNumber(sessionID: UUID, number: Int)
    case invalidEncounterNumber(UUID)
    case invalidStepCount(UUID)
    case invalidMeasurementUncertainty(UUID)
    case invalidAuditEntry(UUID)
    case duplicateAuditEntryID(UUID)
    case invalidCounter
    case invalidCounterMode
    case invalidDefaultUncertainty
    case invalidReceiverPort
    case invalidReceiverUploadSecret
    case automaticPCSyncRequiresSignedReceiver
    case invalidSourceOrderingMetadata
    case invalidPendingUndo
    case invalidDeletedObservation(UUID)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version): return "Unsupported data schema version \(version)."
        case .noSessions: return "The data store contains no sessions."
        case .duplicateSessionID(let id): return "Duplicate session UUID: \(id.uuidString)."
        case .emptySessionName(let id): return "Session \(id.uuidString) has an empty name."
        case .invalidActiveSession(let id): return "The active session \(id.uuidString) does not exist."
        case .archivedActiveSession(let id): return "The active session \(id.uuidString) is archived."
        case .duplicateObservationID(let id): return "Duplicate observation UUID: \(id.uuidString)."
        case .orphanedObservation(let id): return "Observation \(id.uuidString) refers to a missing session."
        case .duplicateEncounterNumber(let sessionID, let number): return "Session \(sessionID.uuidString) contains duplicate encounter number \(number)."
        case .invalidEncounterNumber(let id): return "Observation \(id.uuidString) has an invalid encounter number."
        case .invalidStepCount(let id): return "Observation \(id.uuidString) has a negative step count."
        case .invalidMeasurementUncertainty(let id): return "Observation \(id.uuidString) has a negative uncertainty."
        case .invalidAuditEntry(let id): return "Audit entry \(id.uuidString) contains an invalid step count."
        case .duplicateAuditEntryID(let id): return "Duplicate audit-entry UUID: \(id.uuidString)."
        case .invalidCounter: return "The unfinished counter is negative."
        case .invalidCounterMode: return "The counter selector must be Walking or Running."
        case .invalidDefaultUncertainty: return "Default measurement uncertainty cannot be negative."
        case .invalidReceiverPort: return "The PC receiver port must be between 1 and 65535."
        case .invalidReceiverUploadSecret: return "The PC receiver upload secret must be empty or exactly 64 hexadecimal characters."
        case .automaticPCSyncRequiresSignedReceiver: return "Automatic PC synchronization requires a receiver address and a 64-character upload secret."
        case .invalidSourceOrderingMetadata: return "Source-store UUID and mutation sequence must either both be present or both be absent."
        case .invalidPendingUndo: return "The persisted undo state is inconsistent."
        case .invalidDeletedObservation(let id): return "Deleted observation \(id.uuidString) conflicts with active data."
        }
    }
}

public enum StateValidator {
    public static func validate(_ state: PersistentAppState) throws {
        guard state.schemaVersion == PersistentAppState.currentSchemaVersion else {
            throw StateValidationError.unsupportedSchemaVersion(state.schemaVersion)
        }
        guard !state.sessions.isEmpty else { throw StateValidationError.noSessions }

        var sessionIDs = Set<UUID>()
        for session in state.sessions {
            guard sessionIDs.insert(session.id).inserted else { throw StateValidationError.duplicateSessionID(session.id) }
            guard session.name.nilIfBlank != nil else { throw StateValidationError.emptySessionName(session.id) }
        }
        guard let active = state.sessions.first(where: { $0.id == state.activeSessionID }) else {
            throw StateValidationError.invalidActiveSession(state.activeSessionID)
        }
        guard !active.isArchived else { throw StateValidationError.archivedActiveSession(active.id) }

        var observationIDs = Set<UUID>()
        var encounterKeys = Set<String>()
        var auditIDs = Set<UUID>()
        for observation in state.observations {
            guard observationIDs.insert(observation.id).inserted else { throw StateValidationError.duplicateObservationID(observation.id) }
            guard sessionIDs.contains(observation.sessionID) else { throw StateValidationError.orphanedObservation(observation.id) }
            guard observation.encounterNumber > 0 else { throw StateValidationError.invalidEncounterNumber(observation.id) }
            guard observation.stepCount >= 0 else { throw StateValidationError.invalidStepCount(observation.id) }
            guard observation.measurementUncertainty >= 0 else { throw StateValidationError.invalidMeasurementUncertainty(observation.id) }
            let encounterKey = "\(observation.sessionID.uuidString):\(observation.encounterNumber)"
            guard encounterKeys.insert(encounterKey).inserted else {
                throw StateValidationError.duplicateEncounterNumber(sessionID: observation.sessionID, number: observation.encounterNumber)
            }
            for audit in observation.auditHistory {
                guard audit.previousStepCount >= 0, audit.newStepCount >= 0 else { throw StateValidationError.invalidAuditEntry(audit.id) }
                guard auditIDs.insert(audit.id).inserted else { throw StateValidationError.duplicateAuditEntryID(audit.id) }
            }
        }

        guard state.counter.currentCount >= 0 else { throw StateValidationError.invalidCounter }
        guard state.counter.selectedBaseMode == .walking || state.counter.selectedBaseMode == .running else {
            throw StateValidationError.invalidCounterMode
        }
        guard state.settings.defaultMeasurementUncertainty >= 0 else { throw StateValidationError.invalidDefaultUncertainty }
        guard (1...65535).contains(state.settings.pcReceiverPort) else { throw StateValidationError.invalidReceiverPort }
        guard isValidReceiverUploadSecret(state.settings.pcReceiverUploadSecret) else {
            throw StateValidationError.invalidReceiverUploadSecret
        }
        if state.settings.automaticallySendSnapshotToPC {
            guard state.settings.pcReceiverHost.nilIfBlank != nil,
                  isValidReceiverUploadSecret(
                      state.settings.pcReceiverUploadSecret,
                      allowingEmpty: false
                  ) else {
                throw StateValidationError.automaticPCSyncRequiresSignedReceiver
            }
        }
        guard (state.sourceStoreID == nil) == (state.sourceMutationSequence == nil) else {
            throw StateValidationError.invalidSourceOrderingMetadata
        }

        if let pending = state.pendingUndo {
            let isPresent = observationIDs.contains(pending.observation.id)
            let validSelector = pending.selectorModeAtSubmission == .walking || pending.selectorModeAtSubmission == .running
            let validPendingObservation = pending.observation.sessionID == state.activeSessionID
                && pending.observation.encounterNumber > 0
                && pending.observation.stepCount >= 0
                && pending.observation.measurementUncertainty >= 0
            guard validPendingObservation else { throw StateValidationError.invalidPendingUndo }
            switch pending.phase {
            case .canUndoSubmission:
                guard isPresent,
                      state.observations.first(where: { $0.id == pending.observation.id }) == pending.observation,
                      pending.counterBeforeUndo == nil,
                      validSelector else {
                    throw StateValidationError.invalidPendingUndo
                }
            case .canRedoUndo:
                let pendingEncounterKey = "\(pending.observation.sessionID.uuidString):\(pending.observation.encounterNumber)"
                guard !isPresent,
                      let previousCounter = pending.counterBeforeUndo,
                      previousCounter.currentCount >= 0,
                      previousCounter.selectedBaseMode == .walking || previousCounter.selectedBaseMode == .running,
                      validSelector,
                      encounterKeys.insert(pendingEncounterKey).inserted else {
                    throw StateValidationError.invalidPendingUndo
                }
                for audit in pending.observation.auditHistory {
                    guard audit.previousStepCount >= 0,
                          audit.newStepCount >= 0,
                          auditIDs.insert(audit.id).inserted else {
                        throw StateValidationError.invalidPendingUndo
                    }
                }
            }
        }

        var deletedIDs = Set<UUID>()
        for deleted in state.deletedObservations {
            let observation = deleted.observation
            let encounterKey = "\(observation.sessionID.uuidString):\(observation.encounterNumber)"
            guard !observationIDs.contains(deleted.id),
                  state.pendingUndo?.observation.id != deleted.id,
                  deletedIDs.insert(deleted.id).inserted,
                  sessionIDs.contains(observation.sessionID),
                  observation.encounterNumber > 0,
                  observation.stepCount >= 0,
                  observation.measurementUncertainty >= 0,
                  encounterKeys.insert(encounterKey).inserted else {
                throw StateValidationError.invalidDeletedObservation(deleted.id)
            }
            for audit in observation.auditHistory {
                guard audit.previousStepCount >= 0,
                      audit.newStepCount >= 0,
                      auditIDs.insert(audit.id).inserted else {
                    throw StateValidationError.invalidDeletedObservation(deleted.id)
                }
            }
        }
    }

    private static func isValidReceiverUploadSecret(_ value: String, allowingEmpty: Bool = true) -> Bool {
        let normalized = AppSettings.normalizedReceiverUploadSecret(value)
        if normalized.isEmpty { return allowingEmpty }
        return normalized.count == 64 && normalized.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }
}
