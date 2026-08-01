import Foundation

public enum ReceiverScheme: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case http
    case https

    public var id: String { rawValue }
    public var displayName: String { rawValue.uppercased() }
}

public struct ReceiverConfiguration: Equatable, Hashable, Sendable {
    public var scheme: ReceiverScheme
    public var host: String
    public var port: Int
    public var uploadSecret: String

    public init(
        scheme: ReceiverScheme = .http,
        host: String,
        port: Int = 8765,
        uploadSecret: String = ""
    ) {
        self.scheme = scheme
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.uploadSecret = AppSettings.normalizedReceiverUploadSecret(uploadSecret)
    }

    public var usesSignedUploads: Bool { !uploadSecret.isEmpty }
}

public struct AppSettings: Codable, Equatable, Hashable, Sendable {
    public var hapticsEnabled: Bool
    public var keepScreenAwake: Bool
    public var defaultMeasurementUncertainty: Int
    public var confirmZeroSubmission: Bool
    public var confirmUndoReplaceNonzero: Bool
    public var createExportSnapshotsAfterEverySubmission: Bool
    public var lastExportFormat: ExportFormat
    public var pcReceiverHost: String
    public var pcReceiverPort: Int
    public var pcReceiverScheme: ReceiverScheme
    public var pcReceiverUploadSecret: String
    public var automaticallySendSnapshotToPC: Bool
    public var appearance: AppAppearance
    public var soundFeedbackEnabled: Bool

    public init(
        hapticsEnabled: Bool = true,
        keepScreenAwake: Bool = false,
        defaultMeasurementUncertainty: Int = 1,
        confirmZeroSubmission: Bool = true,
        confirmUndoReplaceNonzero: Bool = true,
        createExportSnapshotsAfterEverySubmission: Bool = false,
        lastExportFormat: ExportFormat = .csv,
        pcReceiverHost: String = "",
        pcReceiverPort: Int = 8765,
        pcReceiverScheme: ReceiverScheme = .http,
        pcReceiverUploadSecret: String = "",
        automaticallySendSnapshotToPC: Bool = false,
        appearance: AppAppearance = .system,
        soundFeedbackEnabled: Bool = false
    ) {
        self.hapticsEnabled = hapticsEnabled
        self.keepScreenAwake = keepScreenAwake
        self.defaultMeasurementUncertainty = defaultMeasurementUncertainty
        self.confirmZeroSubmission = confirmZeroSubmission
        self.confirmUndoReplaceNonzero = confirmUndoReplaceNonzero
        self.createExportSnapshotsAfterEverySubmission = createExportSnapshotsAfterEverySubmission
        self.lastExportFormat = lastExportFormat
        self.pcReceiverHost = pcReceiverHost.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pcReceiverPort = pcReceiverPort
        self.pcReceiverScheme = pcReceiverScheme
        self.pcReceiverUploadSecret = Self.normalizedReceiverUploadSecret(pcReceiverUploadSecret)
        self.automaticallySendSnapshotToPC = automaticallySendSnapshotToPC
        self.appearance = appearance
        self.soundFeedbackEnabled = soundFeedbackEnabled
    }

    public var receiverConfiguration: ReceiverConfiguration {
        ReceiverConfiguration(
            scheme: pcReceiverScheme,
            host: pcReceiverHost,
            port: pcReceiverPort,
            uploadSecret: pcReceiverUploadSecret
        )
    }

    public static func normalizedReceiverUploadSecret(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private enum CodingKeys: String, CodingKey {
        case hapticsEnabled
        case keepScreenAwake
        case defaultMeasurementUncertainty
        case confirmZeroSubmission
        case confirmUndoReplaceNonzero
        case createExportSnapshotsAfterEverySubmission
        case lastExportFormat
        case pcReceiverHost
        case pcReceiverPort
        case pcReceiverScheme
        case pcReceiverUploadSecret
        case automaticallySendSnapshotToPC
        case appearance
        case soundFeedbackEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hapticsEnabled: try container.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true,
            keepScreenAwake: try container.decodeIfPresent(Bool.self, forKey: .keepScreenAwake) ?? false,
            defaultMeasurementUncertainty: try container.decodeIfPresent(Int.self, forKey: .defaultMeasurementUncertainty) ?? 1,
            confirmZeroSubmission: try container.decodeIfPresent(Bool.self, forKey: .confirmZeroSubmission) ?? true,
            confirmUndoReplaceNonzero: try container.decodeIfPresent(Bool.self, forKey: .confirmUndoReplaceNonzero) ?? true,
            createExportSnapshotsAfterEverySubmission: try container.decodeIfPresent(Bool.self, forKey: .createExportSnapshotsAfterEverySubmission) ?? false,
            lastExportFormat: try container.decodeIfPresent(ExportFormat.self, forKey: .lastExportFormat) ?? .csv,
            pcReceiverHost: try container.decodeIfPresent(String.self, forKey: .pcReceiverHost) ?? "",
            pcReceiverPort: try container.decodeIfPresent(Int.self, forKey: .pcReceiverPort) ?? 8765,
            pcReceiverScheme: try container.decodeIfPresent(ReceiverScheme.self, forKey: .pcReceiverScheme) ?? .http,
            pcReceiverUploadSecret: try container.decodeIfPresent(String.self, forKey: .pcReceiverUploadSecret) ?? "",
            automaticallySendSnapshotToPC: try container.decodeIfPresent(Bool.self, forKey: .automaticallySendSnapshotToPC) ?? false,
            appearance: try container.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system,
            soundFeedbackEnabled: try container.decodeIfPresent(Bool.self, forKey: .soundFeedbackEnabled) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hapticsEnabled, forKey: .hapticsEnabled)
        try container.encode(keepScreenAwake, forKey: .keepScreenAwake)
        try container.encode(defaultMeasurementUncertainty, forKey: .defaultMeasurementUncertainty)
        try container.encode(confirmZeroSubmission, forKey: .confirmZeroSubmission)
        try container.encode(confirmUndoReplaceNonzero, forKey: .confirmUndoReplaceNonzero)
        try container.encode(createExportSnapshotsAfterEverySubmission, forKey: .createExportSnapshotsAfterEverySubmission)
        try container.encode(lastExportFormat, forKey: .lastExportFormat)
        try container.encode(pcReceiverHost, forKey: .pcReceiverHost)
        try container.encode(pcReceiverPort, forKey: .pcReceiverPort)
        try container.encode(pcReceiverScheme, forKey: .pcReceiverScheme)
        try container.encode(pcReceiverUploadSecret, forKey: .pcReceiverUploadSecret)
        try container.encode(automaticallySendSnapshotToPC, forKey: .automaticallySendSnapshotToPC)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(soundFeedbackEnabled, forKey: .soundFeedbackEnabled)
    }
}

public struct CounterState: Codable, Equatable, Hashable, Sendable {
    public var currentCount: Int
    public var selectedBaseMode: MovementMode
    public var currentIntervalIsMixed: Bool
    public var lastChangedAt: Date

    public var currentIntervalMode: MovementMode {
        currentIntervalIsMixed ? .mixedUncertain : selectedBaseMode
    }

    public init(
        currentCount: Int = 0,
        selectedBaseMode: MovementMode = .walking,
        currentIntervalIsMixed: Bool = false,
        lastChangedAt: Date = Date()
    ) {
        self.currentCount = currentCount
        self.selectedBaseMode = selectedBaseMode
        self.currentIntervalIsMixed = currentIntervalIsMixed
        self.lastChangedAt = lastChangedAt
    }
}

public struct CounterCheckpoint: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var baseStoreRevision: UUID?
    public var baseStoreLastModifiedAt: Date
    public var activeSessionID: UUID
    public var counter: CounterState
    public var persistedAt: Date

    public init(
        schemaVersion: Int = CounterCheckpoint.currentSchemaVersion,
        baseStoreRevision: UUID?,
        baseStoreLastModifiedAt: Date,
        activeSessionID: UUID,
        counter: CounterState,
        persistedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.baseStoreRevision = baseStoreRevision
        self.baseStoreLastModifiedAt = baseStoreLastModifiedAt
        self.activeSessionID = activeSessionID
        self.counter = counter
        self.persistedAt = persistedAt
    }
}

public enum PendingUndoPhase: String, Codable, Equatable, Hashable, Sendable {
    case canUndoSubmission
    case canRedoUndo
}

public struct PendingUndo: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var observation: EncounterObservation
    public var selectorModeAtSubmission: MovementMode
    public var phase: PendingUndoPhase
    public var counterBeforeUndo: CounterState?
    public var createdAt: Date
    public var undoneAt: Date?

    public init(
        id: UUID = UUID(),
        observation: EncounterObservation,
        selectorModeAtSubmission: MovementMode,
        phase: PendingUndoPhase = .canUndoSubmission,
        counterBeforeUndo: CounterState? = nil,
        createdAt: Date = Date(),
        undoneAt: Date? = nil
    ) {
        self.id = id
        self.observation = observation
        self.selectorModeAtSubmission = selectorModeAtSubmission
        self.phase = phase
        self.counterBeforeUndo = counterBeforeUndo
        self.createdAt = createdAt
        self.undoneAt = undoneAt
    }
}

public struct DeletedObservation: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID { observation.id }
    public var observation: EncounterObservation
    public var deletedAt: Date

    public init(observation: EncounterObservation, deletedAt: Date = Date()) {
        self.observation = observation
        self.deletedAt = deletedAt
    }
}

public struct PersistentAppState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var fullStoreRevision: UUID?
    public var sourceStoreID: UUID?
    public var sourceMutationSequence: UInt64?
    public var seedDataVersion: Int
    public var sessions: [EncounterSession]
    public var observations: [EncounterObservation]
    public var activeSessionID: UUID
    public var counter: CounterState
    public var settings: AppSettings
    public var pendingUndo: PendingUndo?
    public var deletedObservations: [DeletedObservation]
    public var lastModifiedAt: Date

    public init(
        schemaVersion: Int = PersistentAppState.currentSchemaVersion,
        fullStoreRevision: UUID? = UUID(),
        sourceStoreID: UUID? = UUID(),
        sourceMutationSequence: UInt64? = 0,
        seedDataVersion: Int = 0,
        sessions: [EncounterSession],
        observations: [EncounterObservation] = [],
        activeSessionID: UUID,
        counter: CounterState = CounterState(),
        settings: AppSettings = AppSettings(),
        pendingUndo: PendingUndo? = nil,
        deletedObservations: [DeletedObservation] = [],
        lastModifiedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.fullStoreRevision = fullStoreRevision
        self.sourceStoreID = sourceStoreID
        self.sourceMutationSequence = sourceMutationSequence
        self.seedDataVersion = seedDataVersion
        self.sessions = sessions
        self.observations = observations
        self.activeSessionID = activeSessionID
        self.counter = counter
        self.settings = settings
        self.pendingUndo = pendingUndo
        self.deletedObservations = deletedObservations
        self.lastModifiedAt = lastModifiedAt
    }

    public var activeSession: EncounterSession? {
        sessions.first { $0.id == activeSessionID }
    }

    public func observations(for sessionID: UUID) -> [EncounterObservation] {
        observations
            .filter { $0.sessionID == sessionID }
            .sorted {
                if $0.encounterNumber == $1.encounterNumber { return $0.submittedAt < $1.submittedAt }
                return $0.encounterNumber < $1.encounterNumber
            }
    }
}
