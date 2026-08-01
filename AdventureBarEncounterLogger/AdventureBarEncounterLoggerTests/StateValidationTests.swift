import XCTest
@testable import AdventureBarEncounterLogger

final class StateValidationTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_760_000_000)

    func testPendingUndoMustExactlyMatchItsActiveObservation() throws {
        var state = InitialSeed.makeInitialState(now: fixedNow)
        let activeObservation = try XCTUnwrap(state.observations.first)
        var mismatched = activeObservation
        mismatched.stepCount += 1
        state.activeSessionID = activeObservation.sessionID
        state.pendingUndo = PendingUndo(
            observation: mismatched,
            selectorModeAtSubmission: .walking,
            createdAt: fixedNow
        )

        XCTAssertThrowsError(try StateValidator.validate(state)) { error in
            XCTAssertEqual(error as? StateValidationError, .invalidPendingUndo)
        }
    }

    func testMalformedDeletedObservationIsRejected() throws {
        var state = InitialSeed.makeInitialState(now: fixedNow)
        var malformed = state.observations.removeFirst()
        malformed.stepCount = -1
        state.deletedObservations = [DeletedObservation(observation: malformed, deletedAt: fixedNow)]

        XCTAssertThrowsError(try StateValidator.validate(state)) { error in
            XCTAssertEqual(
                error as? StateValidationError,
                .invalidDeletedObservation(malformed.id)
            )
        }
    }

    func testDeletedEncounterNumberCannotConflictWithActiveObservation() throws {
        var state = InitialSeed.makeInitialState(now: fixedNow)
        var conflicting = try XCTUnwrap(state.observations.first)
        conflicting.id = UUID()
        conflicting.auditHistory = []
        state.deletedObservations = [
            DeletedObservation(observation: conflicting, deletedAt: fixedNow)
        ]

        XCTAssertThrowsError(try StateValidator.validate(state)) { error in
            XCTAssertEqual(
                error as? StateValidationError,
                .invalidDeletedObservation(conflicting.id)
            )
        }
    }

    func testDeletedEncounterNumbersMustBeUniqueWithinSession() throws {
        var state = InitialSeed.makeInitialState(now: fixedNow)
        let removed = state.observations.removeFirst()
        var duplicate = removed
        duplicate.id = UUID()
        duplicate.auditHistory = []
        state.deletedObservations = [
            DeletedObservation(observation: removed, deletedAt: fixedNow),
            DeletedObservation(observation: duplicate, deletedAt: fixedNow.addingTimeInterval(1))
        ]

        XCTAssertThrowsError(try StateValidator.validate(state)) { error in
            XCTAssertEqual(
                error as? StateValidationError,
                .invalidDeletedObservation(duplicate.id)
            )
        }
    }
}
