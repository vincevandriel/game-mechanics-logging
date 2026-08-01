import Foundation

public enum ImportDetectedFormat: String, Equatable {
    case csv
    case jsonBackup
    case jsonObservations
    case unknown
}

public enum ImportIssueSeverity: String, Equatable {
    case warning
    case error
}

public struct ImportIssue: Identifiable, Equatable {
    public var id: UUID
    public var severity: ImportIssueSeverity
    public var rowNumber: Int?
    public var message: String

    public init(
        id: UUID = UUID(),
        severity: ImportIssueSeverity,
        rowNumber: Int? = nil,
        message: String
    ) {
        self.id = id
        self.severity = severity
        self.rowNumber = rowNumber
        self.message = message
    }
}

public struct ImportPreview: Identifiable, Equatable {
    public var id: UUID
    public var sourceFilename: String
    public var detectedFormat: ImportDetectedFormat
    public var sessions: [EncounterSession]
    public var observations: [EncounterObservation]
    public var preferredActiveSessionID: UUID?
    public var importedSettings: AppSettings?
    public var completeState: PersistentAppState?
    public var issues: [ImportIssue]
    public var duplicateObservationIDs: Set<UUID>

    public init(
        id: UUID = UUID(),
        sourceFilename: String,
        detectedFormat: ImportDetectedFormat,
        sessions: [EncounterSession] = [],
        observations: [EncounterObservation] = [],
        preferredActiveSessionID: UUID? = nil,
        importedSettings: AppSettings? = nil,
        completeState: PersistentAppState? = nil,
        issues: [ImportIssue] = [],
        duplicateObservationIDs: Set<UUID> = []
    ) {
        self.id = id
        self.sourceFilename = sourceFilename
        self.detectedFormat = detectedFormat
        self.sessions = sessions
        self.observations = observations
        self.preferredActiveSessionID = preferredActiveSessionID
        self.importedSettings = importedSettings
        self.completeState = completeState
        self.issues = issues
        self.duplicateObservationIDs = duplicateObservationIDs
    }

    public var sessionCount: Int { sessions.count }
    public var observationCount: Int { observations.count }
    public var rejectedRowCount: Int { issues.filter { $0.severity == .error }.count }
    public var hasErrors: Bool { issues.contains { $0.severity == .error } }
    public var isCompleteBackup: Bool { completeState != nil }
    public var canImport: Bool { completeState != nil || !sessions.isEmpty || !observations.isEmpty }

    public var errorReportText: String {
        guard !issues.isEmpty else { return "No import warnings or errors.\n" }
        return issues.map { issue in
            let location = issue.rowNumber.map { " row \($0)" } ?? ""
            return "[\(issue.severity.rawValue.uppercased())]\(location): \(issue.message)"
        }.joined(separator: "\n") + "\n"
    }

    public var errorReportData: Data { Data(errorReportText.utf8) }
}

public struct ImportResult: Equatable {
    public var state: PersistentAppState
    public var importedSessionCount: Int
    public var importedObservationCount: Int
    public var duplicateObservationCount: Int
    public var issues: [ImportIssue]
    public var restoredCompleteBackup: Bool

    public init(
        state: PersistentAppState,
        importedSessionCount: Int,
        importedObservationCount: Int,
        duplicateObservationCount: Int,
        issues: [ImportIssue],
        restoredCompleteBackup: Bool
    ) {
        self.state = state
        self.importedSessionCount = importedSessionCount
        self.importedObservationCount = importedObservationCount
        self.duplicateObservationCount = duplicateObservationCount
        self.issues = issues
        self.restoredCompleteBackup = restoredCompleteBackup
    }
}

public enum ImportServiceError: LocalizedError, Equatable {
    case unsupportedFileType
    case noImportableData
    case replacementContainsRejectedRows(Int)
    case invalidCompleteBackup(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFileType: return "Choose a UTF-8 CSV file or a JSON file created by Adventure Bar Encounter Logger."
        case .noImportableData: return "No valid sessions or observations were found in the selected file."
        case .replacementContainsRejectedRows(let count): return "Replacement was stopped because the import contains \(count) rejected row(s). Review the error report first."
        case .invalidCompleteBackup(let reason): return "The complete backup is invalid: \(reason)"
        }
    }
}

public final class ImportService {
    public init() {}

    public func preview(
        data: Data,
        filename: String,
        existingState: PersistentAppState? = nil
    ) -> ImportPreview {
        let ext = (filename as NSString).pathExtension.lowercased()
        var preview: ImportPreview
        if ext == "csv" {
            preview = previewCSV(data: data, filename: filename)
        } else if ext == "json" {
            preview = previewJSON(data: data, filename: filename)
        } else {
            let first = data.first { byte in byte != 9 && byte != 10 && byte != 13 && byte != 32 }
            if first == 123 || first == 91 {
                preview = previewJSON(data: data, filename: filename)
            } else {
                preview = ImportPreview(
                    sourceFilename: filename,
                    detectedFormat: .unknown,
                    issues: [ImportIssue(severity: .error, message: ImportServiceError.unsupportedFileType.localizedDescription)]
                )
            }
        }
        guard let existingState else { return preview }
        let existingIDs = Set(existingState.observations.map(\.id))
        let duplicates = Set(preview.observations.map(\.id)).intersection(existingIDs)
        preview.duplicateObservationIDs = duplicates
        if !duplicates.isEmpty {
            preview.issues.append(ImportIssue(
                severity: .warning,
                message: "\(duplicates.count) observation UUID(s) already exist and will be skipped during merge."
            ))
        }
        return preview
    }

    public func preview(fileURL: URL, existingState: PersistentAppState? = nil) throws -> ImportPreview {
        preview(data: try Data(contentsOf: fileURL), filename: fileURL.lastPathComponent, existingState: existingState)
    }

    public func applying(
        _ preview: ImportPreview,
        to existingState: PersistentAppState,
        mode: ImportMode,
        now: Date = Date()
    ) throws -> ImportResult {
        guard preview.canImport else { throw ImportServiceError.noImportableData }
        if mode == .replace && preview.hasErrors {
            throw ImportServiceError.replacementContainsRejectedRows(preview.rejectedRowCount)
        }

        if mode == .replace, let complete = preview.completeState {
            do {
                try StateValidator.validate(complete)
                return ImportResult(
                    state: complete,
                    importedSessionCount: complete.sessions.count,
                    importedObservationCount: complete.observations.count,
                    duplicateObservationCount: 0,
                    issues: preview.issues,
                    restoredCompleteBackup: true
                )
            } catch {
                throw ImportServiceError.invalidCompleteBackup(error.localizedDescription)
            }
        }

        switch mode {
        case .replace:
            var sessions = preview.sessions
            if sessions.isEmpty {
                sessions = synthesizeSessions(for: preview.observations, now: now)
            }
            guard !sessions.isEmpty else { throw ImportServiceError.noImportableData }
            var activeID = preview.preferredActiveSessionID.flatMap { preferred in
                sessions.first(where: { $0.id == preferred && !$0.isArchived })?.id
            } ?? sessions.first(where: { !$0.isArchived })?.id
            if activeID == nil {
                sessions[0].isArchived = false
                activeID = sessions[0].id
            }
            let replacement = PersistentAppState(
                seedDataVersion: InitialSeed.version,
                sessions: sessions,
                observations: preview.observations,
                activeSessionID: activeID!,
                counter: CounterState(currentCount: 0, selectedBaseMode: .walking, lastChangedAt: now),
                settings: preview.importedSettings ?? existingState.settings,
                pendingUndo: nil,
                deletedObservations: [],
                lastModifiedAt: now
            )
            do {
                try StateValidator.validate(replacement)
            } catch {
                throw ImportServiceError.invalidCompleteBackup(error.localizedDescription)
            }
            return ImportResult(
                state: replacement,
                importedSessionCount: sessions.count,
                importedObservationCount: preview.observations.count,
                duplicateObservationCount: 0,
                issues: preview.issues,
                restoredCompleteBackup: false
            )

        case .merge:
            var merged = existingState
            merged.pendingUndo = nil
            let existingSessionIDs = Set(merged.sessions.map(\.id))
            let sessionsToAdd = preview.sessions.filter { !existingSessionIDs.contains($0.id) }
            merged.sessions.append(contentsOf: sessionsToAdd)

            let referencedMissingIDs = Set(preview.observations.map(\.sessionID)).subtracting(Set(merged.sessions.map(\.id)))
            let synthesized = synthesizeSessions(for: preview.observations.filter { referencedMissingIDs.contains($0.sessionID) }, now: now)
            merged.sessions.append(contentsOf: synthesized)

            var observationIDs = Set(merged.observations.map(\.id))
            var encounterKeys = Set(merged.observations.map { "\($0.sessionID.uuidString):\($0.encounterNumber)" })
            var auditIDs = Set(merged.observations.flatMap(\.auditHistory).map(\.id))
            var importedCount = 0
            var duplicateCount = 0
            var issues = preview.issues

            for observation in preview.observations {
                if observationIDs.contains(observation.id) {
                    duplicateCount += 1
                    continue
                }
                let encounterKey = "\(observation.sessionID.uuidString):\(observation.encounterNumber)"
                if encounterKeys.contains(encounterKey) {
                    issues.append(ImportIssue(
                        severity: .error,
                        message: "Observation \(observation.id.uuidString) was not merged because encounter number \(observation.encounterNumber) already exists in its session."
                    ))
                    continue
                }
                let importedAuditIDs = Set(observation.auditHistory.map(\.id))
                if !auditIDs.isDisjoint(with: importedAuditIDs) {
                    issues.append(ImportIssue(
                        severity: .error,
                        message: "Observation \(observation.id.uuidString) was not merged because an audit-entry UUID conflicts with existing data."
                    ))
                    continue
                }
                merged.observations.append(observation)
                observationIDs.insert(observation.id)
                encounterKeys.insert(encounterKey)
                auditIDs.formUnion(importedAuditIDs)
                importedCount += 1
            }
            merged.lastModifiedAt = now
            try StateValidator.validate(merged)
            return ImportResult(
                state: merged,
                importedSessionCount: sessionsToAdd.count + synthesized.count,
                importedObservationCount: importedCount,
                duplicateObservationCount: duplicateCount,
                issues: issues,
                restoredCompleteBackup: false
            )
        }
    }

    private func previewJSON(data: Data, filename: String) -> ImportPreview {
        let decoder = JSONCoding.makeDecoder()
        if let envelope = try? decoder.decode(JSONExportEnvelope.self, from: data) {
            if envelope.content == .completeBackup,
               let counter = envelope.counter,
               let deleted = envelope.deletedObservations,
               let seedVersion = envelope.seedDataVersion,
               let storeLastModified = envelope.storeLastModifiedAt {
                let complete = PersistentAppState(
                    schemaVersion: envelope.schemaVersion,
                    fullStoreRevision: envelope.fullStoreRevision,
                    sourceStoreID: envelope.sourceStoreID,
                    sourceMutationSequence: envelope.sourceMutationSequence,
                    seedDataVersion: seedVersion,
                    sessions: envelope.sessions,
                    observations: envelope.observations,
                    activeSessionID: envelope.activeSessionID,
                    counter: counter,
                    settings: envelope.settings,
                    pendingUndo: envelope.pendingUndo,
                    deletedObservations: deleted,
                    lastModifiedAt: storeLastModified
                )
                do {
                    try StateValidator.validate(complete)
                    return ImportPreview(
                        sourceFilename: filename,
                        detectedFormat: .jsonBackup,
                        sessions: complete.sessions,
                        observations: complete.observations,
                        preferredActiveSessionID: complete.activeSessionID,
                        importedSettings: complete.settings,
                        completeState: complete
                    )
                } catch {
                    return ImportPreview(
                        sourceFilename: filename,
                        detectedFormat: .jsonBackup,
                        issues: [ImportIssue(severity: .error, message: error.localizedDescription)]
                    )
                }
            }
            return normalizedJSONPreview(
                filename: filename,
                format: .jsonObservations,
                sessions: envelope.sessions,
                observations: envelope.observations,
                activeSessionID: envelope.activeSessionID,
                settings: envelope.settings
            )
        }

        if let state = try? decoder.decode(PersistentAppState.self, from: data) {
            do {
                try StateValidator.validate(state)
                return ImportPreview(
                    sourceFilename: filename,
                    detectedFormat: .jsonBackup,
                    sessions: state.sessions,
                    observations: state.observations,
                    preferredActiveSessionID: state.activeSessionID,
                    importedSettings: state.settings,
                    completeState: state
                )
            } catch {
                return ImportPreview(sourceFilename: filename, detectedFormat: .jsonBackup, issues: [
                    ImportIssue(severity: .error, message: error.localizedDescription)
                ])
            }
        }

        if let document = try? decoder.decode(CompatibleJSONDocument.self, from: data) {
            return normalizedJSONPreview(
                filename: filename,
                format: .jsonObservations,
                sessions: document.sessions ?? [],
                observations: document.observations,
                activeSessionID: document.activeSessionID,
                settings: document.settings
            )
        }
        if let observations = try? decoder.decode([EncounterObservation].self, from: data) {
            return normalizedJSONPreview(
                filename: filename,
                format: .jsonObservations,
                sessions: [],
                observations: observations,
                activeSessionID: nil,
                settings: nil
            )
        }
        return ImportPreview(
            sourceFilename: filename,
            detectedFormat: .unknown,
            issues: [ImportIssue(severity: .error, message: "The JSON structure or one of its values is invalid or unsupported.")]
        )
    }

    private func normalizedJSONPreview(
        filename: String,
        format: ImportDetectedFormat,
        sessions inputSessions: [EncounterSession],
        observations inputObservations: [EncounterObservation],
        activeSessionID: UUID?,
        settings: AppSettings?
    ) -> ImportPreview {
        var issues: [ImportIssue] = []
        var sessions: [EncounterSession] = []
        var sessionIDs = Set<UUID>()
        for (index, session) in inputSessions.enumerated() {
            if session.name.nilIfBlank == nil {
                issues.append(ImportIssue(severity: .error, rowNumber: index + 1, message: "Session \(session.id.uuidString) has an empty name."))
            } else if !sessionIDs.insert(session.id).inserted {
                issues.append(ImportIssue(severity: .error, rowNumber: index + 1, message: "Duplicate session UUID \(session.id.uuidString)."))
            } else {
                sessions.append(session)
            }
        }

        var observations: [EncounterObservation] = []
        var observationIDs = Set<UUID>()
        var encounterKeys = Set<String>()
        var auditIDs = Set<UUID>()
        for (index, observation) in inputObservations.enumerated() {
            let row = index + 1
            if observation.encounterNumber <= 0 {
                issues.append(ImportIssue(severity: .error, rowNumber: row, message: "Encounter number must be greater than zero."))
                continue
            }
            if observation.stepCount < 0 {
                issues.append(ImportIssue(severity: .error, rowNumber: row, message: "Step count cannot be negative."))
                continue
            }
            if observation.measurementUncertainty < 0 {
                issues.append(ImportIssue(severity: .error, rowNumber: row, message: "Measurement uncertainty cannot be negative."))
                continue
            }
            if !observationIDs.insert(observation.id).inserted {
                issues.append(ImportIssue(severity: .error, rowNumber: row, message: "Duplicate observation UUID \(observation.id.uuidString)."))
                continue
            }
            let encounterKey = "\(observation.sessionID.uuidString):\(observation.encounterNumber)"
            if !encounterKeys.insert(encounterKey).inserted {
                issues.append(ImportIssue(severity: .error, rowNumber: row, message: "Duplicate encounter number \(observation.encounterNumber) in one session."))
                continue
            }
            let invalidAudit = observation.auditHistory.first { $0.previousStepCount < 0 || $0.newStepCount < 0 || auditIDs.contains($0.id) }
            if let invalidAudit {
                issues.append(ImportIssue(severity: .error, rowNumber: row, message: "Invalid or duplicate audit entry \(invalidAudit.id.uuidString)."))
                continue
            }
            auditIDs.formUnion(observation.auditHistory.map(\.id))
            observations.append(observation)
        }

        let missingSessionObservations = observations.filter { !sessionIDs.contains($0.sessionID) }
        let generated = synthesizeSessions(for: missingSessionObservations, now: observations.map(\.submittedAt).min() ?? Date())
        if !generated.isEmpty {
            issues.append(ImportIssue(
                severity: .warning,
                message: "Generated \(generated.count) session record(s) because the observations file did not include their metadata."
            ))
            sessions.append(contentsOf: generated)
        }
        return ImportPreview(
            sourceFilename: filename,
            detectedFormat: format,
            sessions: sessions,
            observations: observations,
            preferredActiveSessionID: activeSessionID,
            importedSettings: settings,
            issues: issues
        )
    }

    private func previewCSV(data: Data, filename: String) -> ImportPreview {
        let records: [ParsedCSVRecord]
        do {
            records = try RFC4180Parser.parse(data: data)
        } catch {
            return ImportPreview(sourceFilename: filename, detectedFormat: .csv, issues: [
                ImportIssue(severity: .error, message: error.localizedDescription)
            ])
        }
        guard let headerRecord = records.first else {
            return ImportPreview(sourceFilename: filename, detectedFormat: .csv, issues: [
                ImportIssue(severity: .error, message: "The CSV file is empty.")
            ])
        }
        if let structuralError = headerRecord.structuralError {
            return ImportPreview(sourceFilename: filename, detectedFormat: .csv, issues: [
                ImportIssue(severity: .error, rowNumber: headerRecord.rowNumber, message: structuralError)
            ])
        }

        var columns: [String: Int] = [:]
        var headerIssues: [ImportIssue] = []
        for (index, field) in headerRecord.fields.enumerated() {
            let name = field.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if columns[name] != nil {
                headerIssues.append(ImportIssue(severity: .error, rowNumber: headerRecord.rowNumber, message: "Duplicate CSV column \(name)."))
            } else {
                columns[name] = index
            }
        }
        for required in ExportService.requiredCSVColumns where columns[required] == nil {
            headerIssues.append(ImportIssue(severity: .error, rowNumber: headerRecord.rowNumber, message: "Missing required CSV column \(required)."))
        }
        guard headerIssues.isEmpty else {
            return ImportPreview(sourceFilename: filename, detectedFormat: .csv, issues: headerIssues)
        }

        var sessionsByID: [UUID: EncounterSession] = [:]
        var observations: [EncounterObservation] = []
        var issues: [ImportIssue] = []
        var observationIDs = Set<UUID>()
        var encounterKeys = Set<String>()

        func value(_ name: String, in record: ParsedCSVRecord) -> String {
            guard let index = columns[name], index < record.fields.count else { return "" }
            return record.fields[index]
        }

        for record in records.dropFirst() {
            if let structuralError = record.structuralError {
                issues.append(ImportIssue(severity: .error, rowNumber: record.rowNumber, message: structuralError))
                continue
            }
            if record.fields.count != headerRecord.fields.count {
                issues.append(ImportIssue(
                    severity: .error,
                    rowNumber: record.rowNumber,
                    message: "Expected \(headerRecord.fields.count) fields but found \(record.fields.count)."
                ))
                continue
            }
            do {
                guard let sessionID = UUID(uuidString: value("session_id", in: record)) else { throw CSVValueError("Invalid session_id UUID.") }
                let sessionName = value("session_name", in: record)
                guard sessionName.nilIfBlank != nil else { throw CSVValueError("session_name is empty.") }
                guard let observationID = UUID(uuidString: value("observation_id", in: record)) else { throw CSVValueError("Invalid observation_id UUID.") }
                guard let encounterNumber = Int(value("encounter_number", in: record)), encounterNumber > 0 else {
                    throw CSVValueError("encounter_number must be a positive integer.")
                }
                guard let stepCount = Int(value("step_count", in: record)), stepCount >= 0 else {
                    throw CSVValueError("step_count must be a nonnegative integer.")
                }
                guard let movementMode = MovementMode(importValue: value("movement_mode", in: record)) else {
                    throw CSVValueError("movement_mode must be Walking, Running, or Mixed/Uncertain.")
                }
                guard let submittedAt = ISO8601Coding.date(from: value("submitted_at", in: record)) else {
                    throw CSVValueError("submitted_at must be an ISO 8601 timestamp.")
                }
                let lastEditedString = value("last_edited_at", in: record)
                let lastEditedAt: Date?
                if lastEditedString.nilIfBlank == nil {
                    lastEditedAt = nil
                } else if let parsed = ISO8601Coding.date(from: lastEditedString) {
                    lastEditedAt = parsed
                } else {
                    throw CSVValueError("last_edited_at must be blank or an ISO 8601 timestamp.")
                }
                guard let uncertainty = Int(value("measurement_uncertainty", in: record)), uncertainty >= 0 else {
                    throw CSVValueError("measurement_uncertainty must be a nonnegative integer.")
                }
                guard let questionable = parseBoolean(value("questionable", in: record)) else {
                    throw CSVValueError("questionable must be true or false.")
                }
                guard !observationIDs.contains(observationID) else { throw CSVValueError("Duplicate observation UUID in this file.") }
                let encounterKey = "\(sessionID.uuidString):\(encounterNumber)"
                guard !encounterKeys.contains(encounterKey) else { throw CSVValueError("Duplicate encounter number in this session.") }

                if let existingSession = sessionsByID[sessionID], existingSession.name != sessionName {
                    throw CSVValueError("Conflicting session_name values for session UUID \(sessionID.uuidString).")
                }
                if sessionsByID[sessionID] == nil {
                    let createdString = value("session_created_at", in: record)
                    let modifiedString = value("session_last_modified_at", in: record)
                    guard createdString.nilIfBlank == nil || ISO8601Coding.date(from: createdString) != nil else {
                        throw CSVValueError("session_created_at must be blank or an ISO 8601 timestamp.")
                    }
                    guard modifiedString.nilIfBlank == nil || ISO8601Coding.date(from: modifiedString) != nil else {
                        throw CSVValueError("session_last_modified_at must be blank or an ISO 8601 timestamp.")
                    }
                    let createdAt = optionalDate(createdString) ?? submittedAt
                    let lastModifiedAt = optionalDate(modifiedString) ?? submittedAt
                    sessionsByID[sessionID] = EncounterSession(
                        id: sessionID,
                        name: sessionName,
                        createdAt: createdAt,
                        lastModifiedAt: lastModifiedAt,
                        gameVersion: value("game_version", in: record).nilIfBlank ?? "Nintendo Switch",
                        dungeon: value("dungeon", in: record),
                        mapAreaDescription: value("map_area_description", in: record),
                        testingConditionNotes: value("testing_condition_notes", in: record),
                        notes: value("session_notes", in: record),
                        isArchived: parseBoolean(value("session_archived", in: record)) ?? false
                    )
                }
                observationIDs.insert(observationID)
                encounterKeys.insert(encounterKey)
                observations.append(EncounterObservation(
                    id: observationID,
                    sessionID: sessionID,
                    encounterNumber: encounterNumber,
                    stepCount: stepCount,
                    movementMode: movementMode,
                    submittedAt: submittedAt,
                    lastEditedAt: lastEditedAt,
                    measurementUncertainty: uncertainty,
                    source: value("source", in: record),
                    note: value("note", in: record),
                    isQuestionable: questionable,
                    questionableReason: value("questionable_reason", in: record)
                ))
            } catch let error as CSVValueError {
                issues.append(ImportIssue(severity: .error, rowNumber: record.rowNumber, message: error.message))
            } catch {
                issues.append(ImportIssue(severity: .error, rowNumber: record.rowNumber, message: error.localizedDescription))
            }
        }

        return ImportPreview(
            sourceFilename: filename,
            detectedFormat: .csv,
            sessions: sessionsByID.values.sorted { $0.createdAt < $1.createdAt },
            observations: observations,
            issues: issues
        )
    }

    private func synthesizeSessions(for observations: [EncounterObservation], now: Date) -> [EncounterSession] {
        let grouped = Dictionary(grouping: observations, by: \.sessionID)
        return grouped.map { id, records in
            let createdAt = records.map(\.submittedAt).min() ?? now
            return EncounterSession(
                id: id,
                name: "Imported Session \(id.uuidString.prefix(8))",
                createdAt: createdAt,
                lastModifiedAt: records.compactMap(\.lastEditedAt).max() ?? records.map(\.submittedAt).max() ?? now,
                gameVersion: "Nintendo Switch",
                notes: "Session metadata was not present in the imported observations file."
            )
        }.sorted { $0.createdAt < $1.createdAt }
    }

    private func parseBoolean(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }

    private func optionalDate(_ value: String) -> Date? {
        guard value.nilIfBlank != nil else { return nil }
        return ISO8601Coding.date(from: value)
    }
}

private struct CompatibleJSONDocument: Decodable {
    var sessions: [EncounterSession]?
    var observations: [EncounterObservation]
    var activeSessionID: UUID?
    var settings: AppSettings?
}

private struct CSVValueError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}
