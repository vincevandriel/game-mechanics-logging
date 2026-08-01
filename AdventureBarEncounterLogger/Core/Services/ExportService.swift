import Foundation

public enum ExportSelection: Equatable, Hashable, Sendable {
    case activeSession
    case session(UUID)
    case allSessions
}

public struct ExportedFile: Equatable, Sendable {
    public var filename: String
    public var data: Data
    public var format: ExportFormat
    public var contentType: String
    public var sessionCount: Int
    public var observationCount: Int

    public init(
        filename: String,
        data: Data,
        format: ExportFormat,
        contentType: String,
        sessionCount: Int,
        observationCount: Int
    ) {
        self.filename = filename
        self.data = data
        self.format = format
        self.contentType = contentType
        self.sessionCount = sessionCount
        self.observationCount = observationCount
    }
}

public struct JSONExportEnvelope: Codable, Equatable {
    public static let currentExportFormatVersion = 1

    public var schemaVersion: Int
    public var fullStoreRevision: UUID?
    public var sourceStoreID: UUID?
    public var sourceMutationSequence: UInt64?
    public var exportFormatVersion: Int
    public var exportedAt: Date
    public var content: ExportContent
    public var sessions: [EncounterSession]
    public var observations: [EncounterObservation]
    public var activeSessionID: UUID
    public var settings: AppSettings
    public var counter: CounterState?
    public var pendingUndo: PendingUndo?
    public var deletedObservations: [DeletedObservation]?
    public var seedDataVersion: Int?
    public var storeLastModifiedAt: Date?

    public init(
        schemaVersion: Int,
        fullStoreRevision: UUID? = nil,
        sourceStoreID: UUID? = nil,
        sourceMutationSequence: UInt64? = nil,
        exportFormatVersion: Int = currentExportFormatVersion,
        exportedAt: Date,
        content: ExportContent,
        sessions: [EncounterSession],
        observations: [EncounterObservation],
        activeSessionID: UUID,
        settings: AppSettings,
        counter: CounterState? = nil,
        pendingUndo: PendingUndo? = nil,
        deletedObservations: [DeletedObservation]? = nil,
        seedDataVersion: Int? = nil,
        storeLastModifiedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.fullStoreRevision = fullStoreRevision
        self.sourceStoreID = sourceStoreID
        self.sourceMutationSequence = sourceMutationSequence
        self.exportFormatVersion = exportFormatVersion
        self.exportedAt = exportedAt
        self.content = content
        self.sessions = sessions
        self.observations = observations
        self.activeSessionID = activeSessionID
        self.settings = settings
        self.counter = counter
        self.pendingUndo = pendingUndo
        self.deletedObservations = deletedObservations
        self.seedDataVersion = seedDataVersion
        self.storeLastModifiedAt = storeLastModifiedAt
    }
}

public enum ExportServiceError: LocalizedError, Equatable {
    case sessionNotFound(UUID)
    case completeBackupRequiresJSON
    case cannotEncodeUTF8
    case unsafeFilename

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id): return "Session \(id.uuidString) was not found for export."
        case .completeBackupRequiresJSON: return "Complete backups require JSON because CSV cannot preserve settings and audit history."
        case .cannotEncodeUTF8: return "The CSV export could not be encoded as UTF-8."
        case .unsafeFilename: return "The export filename is not safe."
        }
    }
}

public final class ExportService: @unchecked Sendable {
    public static let requiredCSVColumns = [
        "session_id", "session_name", "observation_id", "encounter_number", "step_count",
        "movement_mode", "submitted_at", "last_edited_at", "measurement_uncertainty", "source",
        "questionable", "questionable_reason", "note"
    ]

    public init() {}

    public func export(
        state: PersistentAppState,
        selection: ExportSelection,
        format: ExportFormat,
        content: ExportContent,
        now: Date = Date()
    ) throws -> ExportedFile {
        try StateValidator.validate(state)
        if content == .completeBackup && format != .json {
            throw ExportServiceError.completeBackupRequiresJSON
        }

        let selected = try selectedData(from: state, selection: selection, content: content)
        let filename = makeFilename(selection: selection, sessions: selected.sessions, format: format, date: now)
        let data: Data
        switch format {
        case .csv:
            data = try csvData(sessions: selected.sessions, observations: selected.observations, includeSessionMetadata: content != .observationsOnly)
        case .json:
            data = try jsonData(
                state: state,
                sessions: content == .observationsOnly ? [] : selected.sessions,
                observations: selected.observations,
                content: content,
                exportedAt: now
            )
        }
        return ExportedFile(
            filename: filename,
            data: data,
            format: format,
            contentType: format.contentType,
            sessionCount: selected.sessions.count,
            observationCount: selected.observations.count
        )
    }

    public func csvData(
        sessions: [EncounterSession],
        observations: [EncounterObservation],
        includeSessionMetadata: Bool = false
    ) throws -> Data {
        let metadataColumns = [
            "session_created_at", "session_last_modified_at", "game_version", "dungeon",
            "map_area_description", "testing_condition_notes", "session_notes", "session_archived"
        ]
        let header = Self.requiredCSVColumns + (includeSessionMetadata ? metadataColumns : [])
        var lines = [RFC4180.row(header)]
        let sessionByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let sessionOrder = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($0.element.id, $0.offset) })
        let sortedObservations = observations.sorted {
            let leftOrder = sessionOrder[$0.sessionID] ?? Int.max
            let rightOrder = sessionOrder[$1.sessionID] ?? Int.max
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            if $0.encounterNumber != $1.encounterNumber { return $0.encounterNumber < $1.encounterNumber }
            return $0.submittedAt < $1.submittedAt
        }

        for observation in sortedObservations {
            guard let session = sessionByID[observation.sessionID] else { continue }
            var fields = [
                session.id.uuidString,
                session.name,
                observation.id.uuidString,
                String(observation.encounterNumber),
                String(observation.stepCount),
                observation.movementMode.displayName,
                ISO8601Coding.string(from: observation.submittedAt),
                observation.lastEditedAt.map { ISO8601Coding.string(from: $0) } ?? "",
                String(observation.measurementUncertainty),
                observation.source,
                observation.isQuestionable ? "true" : "false",
                observation.questionableReason ?? "",
                observation.note ?? ""
            ]
            if includeSessionMetadata {
                fields.append(contentsOf: [
                    ISO8601Coding.string(from: session.createdAt),
                    ISO8601Coding.string(from: session.lastModifiedAt),
                    session.gameVersion,
                    session.dungeon ?? "",
                    session.mapAreaDescription ?? "",
                    session.testingConditionNotes ?? "",
                    session.notes ?? "",
                    session.isArchived ? "true" : "false"
                ])
            }
            lines.append(RFC4180.row(fields))
        }
        guard let data = (lines.joined(separator: "\r\n") + "\r\n").data(using: .utf8) else {
            throw ExportServiceError.cannotEncodeUTF8
        }
        return data
    }

    public func jsonData(
        state: PersistentAppState,
        sessions: [EncounterSession],
        observations: [EncounterObservation],
        content: ExportContent,
        exportedAt: Date = Date()
    ) throws -> Data {
        let isComplete = content == .completeBackup
        var portableSettings = state.settings
        // The shared upload credential is device-local authentication material,
        // not encounter data. Never place it inside a file that may be shared or
        // sent to the receiver it authenticates against.
        portableSettings.pcReceiverUploadSecret = ""
        portableSettings.automaticallySendSnapshotToPC = false
        let envelope = JSONExportEnvelope(
            schemaVersion: state.schemaVersion,
            fullStoreRevision: isComplete ? state.fullStoreRevision : nil,
            sourceStoreID: state.sourceStoreID,
            sourceMutationSequence: state.sourceMutationSequence,
            exportedAt: exportedAt,
            content: content,
            sessions: isComplete ? state.sessions : sessions,
            observations: isComplete ? state.observations : observations,
            activeSessionID: state.activeSessionID,
            settings: portableSettings,
            counter: isComplete ? state.counter : nil,
            pendingUndo: isComplete ? state.pendingUndo : nil,
            deletedObservations: isComplete ? state.deletedObservations : nil,
            seedDataVersion: isComplete ? state.seedDataVersion : nil,
            storeLastModifiedAt: isComplete ? state.lastModifiedAt : nil
        )
        return try JSONCoding.makeEncoder().encode(envelope)
    }

    public func write(_ exportedFile: ExportedFile, to directoryURL: URL, fileManager: FileManager = .default) throws -> URL {
        guard exportedFile.filename == (exportedFile.filename as NSString).lastPathComponent,
              !exportedFile.filename.contains("..") else { throw ExportServiceError.unsafeFilename }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let destination = uniqueDestination(for: exportedFile.filename, in: directoryURL, fileManager: fileManager)
        try exportedFile.data.write(to: destination, options: [.atomic])
        return destination
    }

    private func selectedData(
        from state: PersistentAppState,
        selection: ExportSelection,
        content: ExportContent
    ) throws -> (sessions: [EncounterSession], observations: [EncounterObservation]) {
        if content == .completeBackup { return (state.sessions, state.observations) }
        switch selection {
        case .activeSession:
            guard let session = state.sessions.first(where: { $0.id == state.activeSessionID }) else {
                throw ExportServiceError.sessionNotFound(state.activeSessionID)
            }
            return ([session], state.observations.filter { $0.sessionID == session.id })
        case .session(let id):
            guard let session = state.sessions.first(where: { $0.id == id }) else {
                throw ExportServiceError.sessionNotFound(id)
            }
            return ([session], state.observations.filter { $0.sessionID == id })
        case .allSessions:
            return (state.sessions, state.observations)
        }
    }

    private func makeFilename(
        selection: ExportSelection,
        sessions: [EncounterSession],
        format: ExportFormat,
        date: Date
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let scope: String
        switch selection {
        case .allSessions: scope = "AllSessions"
        case .activeSession, .session:
            scope = safeFilenameComponent(sessions.first?.name ?? "Session")
        }
        return "AdventureBar_\(scope)_\(formatter.string(from: date)).\(format.fileExtension)"
    }

    private func safeFilenameComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let collapsed = String(mapped).replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        return String(collapsed.prefix(60)).nilIfBlank ?? "Session"
    }

    private func uniqueDestination(for filename: String, in directory: URL, fileManager: FileManager) -> URL {
        let original = directory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: original.path) else { return original }
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var suffix = 2
        while true {
            let candidate = directory.appendingPathComponent("\(base)_\(suffix).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }
}

public enum RFC4180 {
    public static func escapedField(_ value: String) -> String {
        let requiresQuotes = value.contains(",")
            || value.contains("\"")
            || value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" })
        guard requiresQuotes else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    public static func row(_ fields: [String]) -> String {
        fields.map(escapedField).joined(separator: ",")
    }
}
