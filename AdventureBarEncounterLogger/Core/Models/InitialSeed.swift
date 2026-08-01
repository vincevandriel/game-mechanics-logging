import Foundation

public enum InitialSeed {
    public static let version = 1
    public static let initialSessionID = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
    public static let loggerSessionID = UUID(uuidString: "A0000000-0000-4000-8000-000000000002")!
    public static let initialSessionName = "Initial Manual Walking Sample"
    public static let loggerSessionName = "Adventure Bar Encounter Test 1"
    public static let source = "Manually counted before app creation"
    public static let gameVersion = "Nintendo Switch"
    public static let values = [
        68, 40, 34, 87, 33, 47, 12, 27, 201, 54,
        22, 138, 41, 32, 32, 42, 33, 20, 187, 112,
        12, 64, 56, 38, 48, 16, 172, 28, 16, 105,
        71, 38, 18, 21, 47, 150, 24, 47, 38, 12
    ]

    public static func makeInitialState(now: Date = Date()) -> PersistentAppState {
        let initialSession = EncounterSession(
            id: initialSessionID,
            name: initialSessionName,
            createdAt: now,
            lastModifiedAt: now,
            gameVersion: gameVersion,
            testingConditionNotes: "Measurement uncertainty: \u{00B1}1",
            notes: source
        )
        let loggerSession = EncounterSession(
            id: loggerSessionID,
            name: loggerSessionName,
            createdAt: now,
            lastModifiedAt: now,
            gameVersion: gameVersion
        )
        let observations = values.enumerated().map { index, count in
            EncounterObservation(
                id: initialObservationID(sequence: index + 1),
                sessionID: initialSessionID,
                encounterNumber: index + 1,
                stepCount: count,
                movementMode: .walking,
                submittedAt: now.addingTimeInterval(Double(index) / 1000.0),
                measurementUncertainty: 1,
                source: source
            )
        }
        return PersistentAppState(
            seedDataVersion: version,
            sessions: [initialSession, loggerSession],
            observations: observations,
            activeSessionID: loggerSessionID,
            counter: CounterState(currentCount: 0, selectedBaseMode: .walking, lastChangedAt: now),
            lastModifiedAt: now
        )
    }

    /// Adds the bundled sample only to a pre-seed store. Stable UUIDs make this
    /// operation idempotent even if an old store lost its seed-version marker.
    @discardableResult
    public static func applyIfNeeded(to state: inout PersistentAppState, now: Date = Date()) -> Bool {
        guard state.seedDataVersion < version else { return false }

        let initialAlreadyExists = state.sessions.contains { $0.id == initialSessionID }
            || values.indices.allSatisfy { index in
                state.observations.contains { $0.id == initialObservationID(sequence: index + 1) }
            }

        if !initialAlreadyExists {
            let seeded = makeInitialState(now: now)
            state.sessions.append(seeded.sessions[0])
            state.observations.append(contentsOf: seeded.observations)
        }
        state.seedDataVersion = version
        state.lastModifiedAt = now
        return true
    }

    public static func initialObservationID(sequence: Int) -> UUID {
        precondition((1...values.count).contains(sequence))
        let suffix = String(format: "%012d", sequence)
        return UUID(uuidString: "B0000000-0000-4000-8000-\(suffix)")!
    }
}
