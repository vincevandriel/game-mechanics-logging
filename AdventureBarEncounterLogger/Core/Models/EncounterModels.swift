import Foundation

public struct ObservationAuditEntry: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var previousStepCount: Int
    public var newStepCount: Int
    public var previousMovementMode: MovementMode
    public var newMovementMode: MovementMode
    public var editedAt: Date
    public var reason: String?

    public init(
        id: UUID = UUID(),
        previousStepCount: Int,
        newStepCount: Int,
        previousMovementMode: MovementMode,
        newMovementMode: MovementMode,
        editedAt: Date = Date(),
        reason: String? = nil
    ) {
        self.id = id
        self.previousStepCount = previousStepCount
        self.newStepCount = newStepCount
        self.previousMovementMode = previousMovementMode
        self.newMovementMode = newMovementMode
        self.editedAt = editedAt
        self.reason = reason?.nilIfBlank
    }
}

public struct EncounterObservation: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var encounterNumber: Int
    public var stepCount: Int
    public var movementMode: MovementMode
    public var submittedAt: Date
    public var lastEditedAt: Date?
    public var measurementUncertainty: Int
    public var source: String
    public var note: String?
    public var isQuestionable: Bool
    public var questionableReason: String?
    public var auditHistory: [ObservationAuditEntry]

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        encounterNumber: Int,
        stepCount: Int,
        movementMode: MovementMode,
        submittedAt: Date = Date(),
        lastEditedAt: Date? = nil,
        measurementUncertainty: Int = 1,
        source: String,
        note: String? = nil,
        isQuestionable: Bool = false,
        questionableReason: String? = nil,
        auditHistory: [ObservationAuditEntry] = []
    ) {
        self.id = id
        self.sessionID = sessionID
        self.encounterNumber = encounterNumber
        self.stepCount = stepCount
        self.movementMode = movementMode
        self.submittedAt = submittedAt
        self.lastEditedAt = lastEditedAt
        self.measurementUncertainty = measurementUncertainty
        self.source = source
        self.note = note?.nilIfBlank
        self.isQuestionable = isQuestionable
        self.questionableReason = questionableReason?.nilIfBlank
        self.auditHistory = auditHistory
    }
}

public struct EncounterSession: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var lastModifiedAt: Date
    public var gameVersion: String
    public var dungeon: String?
    public var mapAreaDescription: String?
    public var testingConditionNotes: String?
    public var notes: String?
    public var isArchived: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        lastModifiedAt: Date = Date(),
        gameVersion: String = "Nintendo Switch",
        dungeon: String? = nil,
        mapAreaDescription: String? = nil,
        testingConditionNotes: String? = nil,
        notes: String? = nil,
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.lastModifiedAt = lastModifiedAt
        self.gameVersion = gameVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dungeon = dungeon?.nilIfBlank
        self.mapAreaDescription = mapAreaDescription?.nilIfBlank
        self.testingConditionNotes = testingConditionNotes?.nilIfBlank
        self.notes = notes?.nilIfBlank
        self.isArchived = isArchived
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
