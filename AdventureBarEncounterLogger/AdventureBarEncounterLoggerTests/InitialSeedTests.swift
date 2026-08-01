import XCTest
@testable import AdventureBarEncounterLogger

final class InitialSeedTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    func testFirstRunInsertsExactlyFortyInitialWalkingObservations() throws {
        let state = InitialSeed.makeInitialState(now: fixedNow)
        let initial = state.observations(for: InitialSeed.initialSessionID)

        XCTAssertEqual(state.seedDataVersion, InitialSeed.version)
        XCTAssertEqual(state.sessions.count, 2)
        XCTAssertEqual(initial.count, 40)
        XCTAssertEqual(initial.map(\.stepCount).reduce(0, +), 2_283)
        XCTAssertEqual(initial.first?.stepCount, 68)
        XCTAssertEqual(initial.last?.stepCount, 12)
        XCTAssertEqual(initial.map(\.encounterNumber), Array(1...40))
        XCTAssertTrue(initial.allSatisfy { $0.movementMode == .walking })
        XCTAssertTrue(initial.allSatisfy { $0.measurementUncertainty == 1 })
        XCTAssertTrue(initial.allSatisfy { $0.source == "Manually counted before app creation" })
        XCTAssertNoThrow(try StateValidator.validate(state))
    }

    func testInitialObservationOrderExactlyMatchesSuppliedValues() {
        let state = InitialSeed.makeInitialState(now: fixedNow)
        XCTAssertEqual(
            state.observations(for: InitialSeed.initialSessionID).map(\.stepCount),
            [
                68, 40, 34, 87, 33, 47, 12, 27, 201, 54,
                22, 138, 41, 32, 32, 42, 33, 20, 187, 112,
                12, 64, 56, 38, 48, 16, 172, 28, 16, 105,
                71, 38, 18, 21, 47, 150, 24, 47, 38, 12
            ]
        )
    }

    func testFirstRunCreatesSeparateActiveLoggerSession() {
        let state = InitialSeed.makeInitialState(now: fixedNow)

        XCTAssertEqual(state.activeSessionID, InitialSeed.loggerSessionID)
        XCTAssertEqual(state.activeSession?.name, "Adventure Bar Encounter Test 1")
        XCTAssertTrue(state.observations(for: InitialSeed.loggerSessionID).isEmpty)
        XCTAssertEqual(state.counter.currentCount, 0)
        XCTAssertEqual(state.counter.selectedBaseMode, .walking)
    }

    func testSeedApplicationDoesNotDuplicateACompletedInitialization() {
        var state = InitialSeed.makeInitialState(now: fixedNow)
        let originalSessions = state.sessions
        let originalObservations = state.observations

        XCTAssertFalse(InitialSeed.applyIfNeeded(to: &state, now: fixedNow.addingTimeInterval(1)))
        XCTAssertEqual(state.sessions, originalSessions)
        XCTAssertEqual(state.observations, originalObservations)
    }

    func testStableIDsPreventDuplicateSeedWhenVersionMarkerWasLost() throws {
        var state = InitialSeed.makeInitialState(now: fixedNow)
        state.seedDataVersion = 0

        XCTAssertTrue(InitialSeed.applyIfNeeded(to: &state, now: fixedNow.addingTimeInterval(1)))
        XCTAssertEqual(state.sessions.filter { $0.id == InitialSeed.initialSessionID }.count, 1)
        XCTAssertEqual(state.observations(for: InitialSeed.initialSessionID).count, 40)
        XCTAssertEqual(Set(state.observations.map(\.id)).count, state.observations.count)
        XCTAssertNoThrow(try StateValidator.validate(state))
    }
}
