import XCTest
@testable import AdventureBarEncounterLogger

final class PersistenceServiceTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_720_000_000)

    func testCounterAndModeAreEncodedInPrimaryStoreImmediately() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        var state = InitialSeed.makeInitialState(now: fixedNow)
        state.counter = CounterState(
            currentCount: 47,
            selectedBaseMode: .running,
            currentIntervalIsMixed: true,
            lastChangedAt: fixedNow
        )

        try environment.persistence.save(state)
        let decoded = try environment.persistence.decodeValidatedState(
            from: Data(contentsOf: environment.persistence.primaryStoreURL)
        )

        XCTAssertEqual(decoded.counter.currentCount, 47)
        XCTAssertEqual(decoded.counter.selectedBaseMode, .running)
        XCTAssertEqual(decoded.counter.currentIntervalMode, .mixedUncertain)
    }

    func testCorruptPrimaryRecoversPreviousValidBackup() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        var first = InitialSeed.makeInitialState(now: fixedNow)
        first.counter.currentCount = 11
        try environment.persistence.save(first)

        var second = first
        second.counter.currentCount = 12
        second.lastModifiedAt = fixedNow.addingTimeInterval(1)
        try environment.persistence.save(second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: environment.persistence.backupStoreURL.path))

        try Data("not valid JSON".utf8).write(
            to: environment.persistence.primaryStoreURL,
            options: [.atomic]
        )

        let recovered = try environment.persistence.loadOrCreate(now: fixedNow.addingTimeInterval(2))
        XCTAssertEqual(recovered.counter.currentCount, 11)

        let repairedPrimary = try environment.persistence.decodeValidatedState(
            from: Data(contentsOf: environment.persistence.primaryStoreURL)
        )
        XCTAssertEqual(repairedPrimary, recovered)
    }

    func testCorruptCounterCheckpointRecoversPreviousValidCheckpoint() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let base = InitialSeed.makeInitialState(now: fixedNow)
        try environment.persistence.save(base)

        var firstCounter = base.counter
        firstCounter.currentCount = 11
        firstCounter.lastChangedAt = fixedNow.addingTimeInterval(1)
        try environment.persistence.saveCounterCheckpoint(
            counter: firstCounter,
            activeSessionID: base.activeSessionID,
            baseStoreRevision: base.fullStoreRevision,
            baseStoreLastModifiedAt: base.lastModifiedAt,
            now: fixedNow.addingTimeInterval(1)
        )

        var secondCounter = firstCounter
        secondCounter.currentCount = 12
        secondCounter.lastChangedAt = fixedNow.addingTimeInterval(2)
        try environment.persistence.saveCounterCheckpoint(
            counter: secondCounter,
            activeSessionID: base.activeSessionID,
            baseStoreRevision: base.fullStoreRevision,
            baseStoreLastModifiedAt: base.lastModifiedAt,
            now: fixedNow.addingTimeInterval(2)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: environment.persistence.counterCheckpointBackupURL.path))

        try Data("not valid JSON".utf8).write(
            to: environment.persistence.counterCheckpointURL,
            options: [.atomic]
        )
        let recovered = try environment.persistence.loadOrCreate(now: fixedNow.addingTimeInterval(3))
        XCTAssertEqual(recovered.counter.currentCount, 11)
        XCTAssertEqual(recovered.counter.selectedBaseMode, .walking)
    }

    func testCorruptPrimaryRecoveryPreservesCheckpointFromNewerFullRevision() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let backupState = InitialSeed.makeInitialState(now: fixedNow)
        try environment.persistence.save(backupState)

        var newerPrimary = backupState
        newerPrimary.fullStoreRevision = UUID()
        newerPrimary.lastModifiedAt = fixedNow.addingTimeInterval(1)
        newerPrimary.settings.hapticsEnabled = false
        try environment.persistence.save(newerPrimary)

        var unfinished = newerPrimary.counter
        unfinished.currentCount = 7
        unfinished.selectedBaseMode = .running
        unfinished.lastChangedAt = fixedNow.addingTimeInterval(2)
        try environment.persistence.saveCounterCheckpoint(
            counter: unfinished,
            activeSessionID: newerPrimary.activeSessionID,
            baseStoreRevision: newerPrimary.fullStoreRevision,
            baseStoreLastModifiedAt: newerPrimary.lastModifiedAt,
            now: fixedNow.addingTimeInterval(2)
        )
        try Data("corrupt full store".utf8).write(
            to: environment.persistence.primaryStoreURL,
            options: [.atomic]
        )

        let recovered = try environment.persistence.loadOrCreate(now: fixedNow.addingTimeInterval(3))

        XCTAssertEqual(recovered.fullStoreRevision, backupState.fullStoreRevision)
        XCTAssertEqual(recovered.counter.currentCount, 7)
        XCTAssertEqual(recovered.counter.selectedBaseMode, .running)
        XCTAssertEqual(recovered.activeSessionID, newerPrimary.activeSessionID)

        let repairedPrimary = try environment.persistence.decodeValidatedState(
            from: Data(contentsOf: environment.persistence.primaryStoreURL)
        )
        XCTAssertEqual(repairedPrimary.counter.currentCount, 7)
        XCTAssertEqual(repairedPrimary.counter.selectedBaseMode, .running)

        let relaunched = try environment.persistence.loadOrCreate(
            now: fixedNow.addingTimeInterval(4)
        )
        XCTAssertEqual(relaunched.counter.currentCount, 7)
        XCTAssertEqual(relaunched.counter.selectedBaseMode, .running)
    }

    func testInvalidStateIsRejectedWithoutReplacingValidPrimary() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let valid = InitialSeed.makeInitialState(now: fixedNow)
        try environment.persistence.save(valid)
        let originalBytes = try Data(contentsOf: environment.persistence.primaryStoreURL)

        var invalid = valid
        invalid.counter.currentCount = -1
        XCTAssertThrowsError(try environment.persistence.save(invalid))

        XCTAssertEqual(try Data(contentsOf: environment.persistence.primaryStoreURL), originalBytes)
    }

    func testPreImportBackupUsesUniqueFilenameAndPreservesAuditHistory() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        var state = InitialSeed.makeInitialState(now: fixedNow)
        let audit = ObservationAuditEntry(
            previousStepCount: 68,
            newStepCount: 69,
            previousMovementMode: .walking,
            newMovementMode: .walking,
            editedAt: fixedNow,
            reason: "test"
        )
        state.observations[0].stepCount = 69
        state.observations[0].lastEditedAt = fixedNow
        state.observations[0].auditHistory = [audit]

        let firstURL = try environment.persistence.createPreImportBackup(of: state, now: fixedNow)
        let secondURL = try environment.persistence.createPreImportBackup(of: state, now: fixedNow)

        XCTAssertNotEqual(firstURL, secondURL)
        let decoded = try environment.persistence.decodeValidatedState(from: Data(contentsOf: firstURL))
        XCTAssertEqual(decoded.observations[0].auditHistory, [audit])
    }
}
