import XCTest
@testable import AdventureBarEncounterLogger

private final class AutomaticSyncURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class AppStoreTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_710_000_000)

    private func makeStore(in environment: TestEnvironment) throws -> AppStore {
        let ids = DeterministicUUIDFactory()
        return try AppStore(
            persistenceService: environment.persistence,
            now: { self.fixedNow },
            makeUUID: { ids.next() }
        )
    }

    func testCounterIncrementDecrementAndNegativePrevention() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let store = try makeStore(in: environment)

        XCTAssertEqual(try store.increment(), 1)
        XCTAssertEqual(try store.increment(), 2)
        XCTAssertEqual(try store.decrement(), 1)
        XCTAssertEqual(try store.decrement(), 0)
        XCTAssertEqual(try store.decrement(), 0)
        XCTAssertEqual(store.currentCount, 0)
    }

    func testCounterAndModePersistAcrossStoreRecreation() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let first = try makeStore(in: environment)

        try first.changeMode(to: .running)
        _ = try first.increment()
        _ = try first.increment()

        let restored = try makeStore(in: environment)
        XCTAssertEqual(restored.currentCount, 2)
        XCTAssertEqual(restored.selectedBaseMode, .running)
        XCTAssertEqual(restored.currentIntervalMode, .running)
    }

    func testSubmissionStoresRawObservationResetsCounterAndPreservesSelector() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let store = try makeStore(in: environment)
        let initialRevision = store.state.fullStoreRevision
        let initialSourceID = store.state.sourceStoreID
        try store.changeMode(to: .running)
        for _ in 0..<7 { _ = try store.increment() }

        let observation = try store.submitCurrentCount()

        XCTAssertEqual(observation.sessionID, InitialSeed.loggerSessionID)
        XCTAssertEqual(observation.encounterNumber, 1)
        XCTAssertEqual(observation.stepCount, 7)
        XCTAssertEqual(observation.movementMode, .running)
        XCTAssertEqual(observation.measurementUncertainty, 1)
        XCTAssertEqual(observation.source, "iPhone logger")
        XCTAssertEqual(observation.submittedAt, fixedNow)
        XCTAssertEqual(store.currentCount, 0)
        XCTAssertEqual(store.selectedBaseMode, .running)
        XCTAssertEqual(store.currentIntervalMode, .running)
        XCTAssertEqual(store.observations(for: InitialSeed.loggerSessionID), [observation])
        XCTAssertNotEqual(store.state.fullStoreRevision, initialRevision)
        XCTAssertEqual(store.state.sourceStoreID, initialSourceID)
        XCTAssertEqual(store.state.sourceMutationSequence, 1)

        let relaunched = try AppStore(persistenceService: environment.persistence, now: { self.fixedNow })
        XCTAssertEqual(relaunched.currentCount, 0)
        XCTAssertEqual(relaunched.observations(for: InitialSeed.loggerSessionID), [observation])
    }

    func testEnabledAutomaticPCSyncRunsOnlyAfterLocalSubmissionCommit() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AutomaticSyncURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            AutomaticSyncURLProtocol.handler = nil
        }
        let uploadReceived = expectation(description: "Signed current snapshot uploaded")
        let secret = String(repeating: "12", count: 32)
        AutomaticSyncURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://203.0.113.10:8765/upload")
            XCTAssertNotNil(request.value(forHTTPHeaderField: ReceiverRequestSigner.signatureHeader))
            XCTAssertNotNil(requestBodyData(request))
            // The synchronous submit must have committed the store before the
            // independent network task is able to report an upload.
            XCTAssertTrue(FileManager.default.fileExists(atPath: environment.persistence.primaryStoreURL.path))
            uploadReceived.fulfill()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 201,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"status":"saved"}"#.utf8))
        }
        let transfer = LocalNetworkTransferService(
            session: session,
            now: { self.fixedNow },
            nonce: { "123e4567-e89b-12d3-a456-426614174000" }
        )
        let store = try AppStore(
            persistenceService: environment.persistence,
            localTransferService: transfer,
            now: { self.fixedNow }
        )
        var settings = store.state.settings
        settings.pcReceiverHost = "203.0.113.10"
        settings.pcReceiverUploadSecret = secret
        settings.automaticallySendSnapshotToPC = true
        try store.updateSettings(settings)
        _ = try store.increment()

        let submitted = try store.submitCurrentCount()
        await fulfillment(of: [uploadReceived], timeout: 3)
        await store.waitForPendingAutomaticPCSyncForTesting()

        XCTAssertTrue(store.state.observations.contains { $0.id == submitted.id })
        XCTAssertEqual(store.lastPCTransferStatus?.succeeded, true)
        XCTAssertEqual(store.lastPCTransferStatus?.automatic, true)
        _ = try store.increment()
        XCTAssertEqual(store.lastPCTransferStatus?.succeeded, true)
        let persisted = try environment.persistence.decodeValidatedState(
            from: Data(contentsOf: environment.persistence.primaryStoreURL)
        )
        XCTAssertTrue(persisted.observations.contains { $0.id == submitted.id })
    }

    func testDisablingAutomaticPCSyncCancelsQueuedUpload() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AutomaticSyncURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            AutomaticSyncURLProtocol.handler = nil
        }

        let uploadReceived = expectation(description: "No upload after automatic synchronization is disabled")
        uploadReceived.isInverted = true
        AutomaticSyncURLProtocol.handler = { request in
            uploadReceived.fulfill()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 201,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"status":"saved"}"#.utf8))
        }

        let transfer = LocalNetworkTransferService(session: session, now: { self.fixedNow })
        let store = try AppStore(
            persistenceService: environment.persistence,
            localTransferService: transfer,
            now: { self.fixedNow }
        )
        var settings = store.state.settings
        settings.pcReceiverHost = "203.0.113.10"
        settings.pcReceiverUploadSecret = String(repeating: "12", count: 32)
        settings.automaticallySendSnapshotToPC = true
        try store.updateSettings(settings)

        _ = try store.increment()
        _ = try store.submitCurrentCount()
        settings = store.state.settings
        settings.automaticallySendSnapshotToPC = false
        try store.updateSettings(settings)

        await fulfillment(of: [uploadReceived], timeout: 0.25)
        XCTAssertFalse(store.state.settings.automaticallySendSnapshotToPC)
        XCTAssertNil(store.lastPCTransferStatus)
    }

    func testZeroValueRequiresExplicitConfirmation() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let store = try makeStore(in: environment)

        XCTAssertThrowsError(try store.submitCurrentCount()) { error in
            XCTAssertEqual(error as? AppStoreError, .zeroSubmissionRequiresConfirmation)
        }
        XCTAssertTrue(store.observations(for: InitialSeed.loggerSessionID).isEmpty)

        let zero = try store.submitCurrentCount(allowZero: true)
        XCTAssertEqual(zero.stepCount, 0)
        XCTAssertEqual(store.observations(for: InitialSeed.loggerSessionID).count, 1)
    }

    func testModeChangeWithNonzeroCounterRequiresResolution() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let store = try makeStore(in: environment)
        _ = try store.increment()

        XCTAssertThrowsError(try store.changeMode(to: .running)) { error in
            XCTAssertEqual(error as? AppStoreError, .modeChangeRequiresConfirmation)
        }
        XCTAssertEqual(store.currentCount, 1)
        XCTAssertEqual(store.selectedBaseMode, .walking)
    }

    func testPreservedModeChangeSubmitsMixedThenKeepsNewBaseMode() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let store = try makeStore(in: environment)
        for _ in 0..<5 { _ = try store.increment() }

        try store.changeMode(to: .running, resolution: .preserveAndMarkMixed)
        XCTAssertEqual(store.currentCount, 5)
        XCTAssertEqual(store.selectedBaseMode, .running)
        XCTAssertEqual(store.currentIntervalMode, .mixedUncertain)

        let observation = try store.submitCurrentCount()
        XCTAssertEqual(observation.stepCount, 5)
        XCTAssertEqual(observation.movementMode, .mixedUncertain)
        XCTAssertEqual(store.currentCount, 0)
        XCTAssertEqual(store.selectedBaseMode, .running)
        XCTAssertEqual(store.currentIntervalMode, .running)
    }

    func testResetModeChangeClearsCounterAndSwitchesMode() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let store = try makeStore(in: environment)
        for _ in 0..<3 { _ = try store.increment() }

        try store.changeMode(to: .running, resolution: .resetAndSwitch)

        XCTAssertEqual(store.currentCount, 0)
        XCTAssertEqual(store.selectedBaseMode, .running)
        XCTAssertEqual(store.currentIntervalMode, .running)
    }

    func testUndoRemovesObservationAndRestoresExactCountAndMode() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let store = try makeStore(in: environment)
        try store.changeMode(to: .running)
        for _ in 0..<38 { _ = try store.increment() }
        let submitted = try store.submitCurrentCount()

        let undone = try store.undoLastSubmission()

        XCTAssertEqual(undone, submitted)
        XCTAssertTrue(store.observations(for: InitialSeed.loggerSessionID).isEmpty)
        XCTAssertEqual(store.currentCount, 38)
        XCTAssertEqual(store.selectedBaseMode, .running)
        XCTAssertEqual(store.currentIntervalMode, .running)
        XCTAssertTrue(store.canRedoUndo)
        XCTAssertFalse(store.canUndo)
    }

    func testUndoRequiresChoiceBeforeReplacingNonzeroCounter() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let store = try makeStore(in: environment)
        for _ in 0..<38 { _ = try store.increment() }
        _ = try store.submitCurrentCount()
        for _ in 0..<4 { _ = try store.increment() }

        XCTAssertTrue(store.undoRequiresCurrentCountConfirmation)
        XCTAssertThrowsError(try store.undoLastSubmission()) { error in
            XCTAssertEqual(error as? AppStoreError, .undoRequiresCurrentCountConfirmation)
        }
        XCTAssertEqual(store.currentCount, 4)
        XCTAssertEqual(store.observations(for: InitialSeed.loggerSessionID).count, 1)
    }

    func testUndoReplacementDiscardsUnfinishedCounterOnlyAfterChoice() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let store = try makeStore(in: environment)
        for _ in 0..<38 { _ = try store.increment() }
        _ = try store.submitCurrentCount()
        for _ in 0..<4 { _ = try store.increment() }

        _ = try store.undoLastSubmission(strategy: .replace)

        XCTAssertEqual(store.currentCount, 38)
        XCTAssertTrue(store.observations(for: InitialSeed.loggerSessionID).isEmpty)
    }

    func testUndoCanAddUnfinishedCounterToRestoredCount() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let store = try makeStore(in: environment)
        for _ in 0..<38 { _ = try store.increment() }
        _ = try store.submitCurrentCount()
        for _ in 0..<4 { _ = try store.increment() }

        _ = try store.undoLastSubmission(strategy: .addCurrentCount)

        XCTAssertEqual(store.currentCount, 42)
        XCTAssertTrue(store.observations(for: InitialSeed.loggerSessionID).isEmpty)
    }

    func testUndoRestoresMixedUncertainStateAndSurvivesRelaunch() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        var store = try makeStore(in: environment)
        for _ in 0..<9 { _ = try store.increment() }
        try store.changeMode(to: .running, resolution: .preserveAndMarkMixed)
        _ = try store.submitCurrentCount()

        store = try makeStore(in: environment)
        XCTAssertTrue(store.canUndo)
        _ = try store.undoLastSubmission()

        XCTAssertEqual(store.currentCount, 9)
        XCTAssertEqual(store.selectedBaseMode, .running)
        XCTAssertEqual(store.currentIntervalMode, .mixedUncertain)

        store = try makeStore(in: environment)
        XCTAssertEqual(store.currentCount, 9)
        XCTAssertEqual(store.currentIntervalMode, .mixedUncertain)
        XCTAssertTrue(store.canRedoUndo)
    }

    func testRedoUndoReinsertsExactObservationAndRestoresPriorCounter() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let store = try makeStore(in: environment)
        for _ in 0..<6 { _ = try store.increment() }
        let submitted = try store.submitCurrentCount()
        for _ in 0..<2 { _ = try store.increment() }
        _ = try store.undoLastSubmission(strategy: .addCurrentCount)

        try store.redoUndo()

        XCTAssertEqual(store.observations(for: InitialSeed.loggerSessionID), [submitted])
        XCTAssertEqual(store.currentCount, 2)
        XCTAssertTrue(store.canUndo)
    }

    func testSessionCreationAndActiveSessionSwitchPersist() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        var store = try makeStore(in: environment)

        let session = try store.createSession(name: "  Dungeon A  ", notes: "first run")
        XCTAssertEqual(session.name, "Dungeon A")
        XCTAssertEqual(store.state.activeSessionID, session.id)

        try store.setActiveSession(id: InitialSeed.loggerSessionID)
        XCTAssertEqual(store.state.activeSessionID, InitialSeed.loggerSessionID)

        store = try makeStore(in: environment)
        XCTAssertTrue(store.state.sessions.contains { $0.id == session.id && $0.name == "Dungeon A" })
        XCTAssertEqual(store.state.activeSessionID, InitialSeed.loggerSessionID)
    }

    func testObservationEditAppendsRecoverableAuditHistoryAndPersistsIt() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        var store = try makeStore(in: environment)
        for _ in 0..<12 { _ = try store.increment() }
        let original = try store.submitCurrentCount()

        let edited = try store.updateObservation(
            id: original.id,
            stepCount: 13,
            movementMode: .running,
            measurementUncertainty: 2,
            note: "manual correction",
            isQuestionable: true,
            questionableReason: "possibly one tap late",
            editReason: "reviewed notes"
        )

        XCTAssertEqual(edited.auditHistory.count, 1)
        XCTAssertEqual(edited.auditHistory[0].previousStepCount, 12)
        XCTAssertEqual(edited.auditHistory[0].newStepCount, 13)
        XCTAssertEqual(edited.auditHistory[0].previousMovementMode, .walking)
        XCTAssertEqual(edited.auditHistory[0].newMovementMode, .running)
        XCTAssertEqual(edited.auditHistory[0].reason, "reviewed notes")

        store = try makeStore(in: environment)
        let restored = try XCTUnwrap(store.state.observations.first { $0.id == original.id })
        XCTAssertEqual(restored.auditHistory, edited.auditHistory)
        XCTAssertEqual(restored.stepCount, 13)
        XCTAssertTrue(restored.isQuestionable)
    }

    func testDeletedObservationCanBeRestoredWithoutChangingRawFields() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let store = try makeStore(in: environment)
        _ = try store.increment()
        let original = try store.submitCurrentCount()

        let deleted = try store.deleteObservation(id: original.id)
        XCTAssertEqual(deleted.observation, original)
        XCTAssertFalse(store.state.observations.contains { $0.id == original.id })

        let restored = try store.restoreDeletedObservation(id: original.id)
        XCTAssertEqual(restored, original)
        XCTAssertTrue(store.state.deletedObservations.isEmpty)
    }

    func testDeletedEncounterNumberRemainsReservedUntilRestoration() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let store = try makeStore(in: environment)
        _ = try store.increment()
        let first = try store.submitCurrentCount()
        _ = try store.deleteObservation(id: first.id)

        _ = try store.increment()
        let second = try store.submitCurrentCount()
        let restored = try store.restoreDeletedObservation(id: first.id)

        XCTAssertEqual(first.encounterNumber, 1)
        XCTAssertEqual(second.encounterNumber, 2)
        XCTAssertEqual(restored, first)
    }
}
