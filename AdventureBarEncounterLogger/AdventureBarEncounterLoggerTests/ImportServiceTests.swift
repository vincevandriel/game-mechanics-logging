import XCTest
@testable import AdventureBarEncounterLogger

private final class ImportSyncURLProtocol: URLProtocol {
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

final class ImportServiceTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_740_000_000)

    private func stateWithOneLoggerObservation() -> PersistentAppState {
        var state = InitialSeed.makeInitialState(now: fixedNow)
        state.observations.append(
            EncounterObservation(
                id: UUID(uuidString: "E0000000-0000-4000-8000-000000000001")!,
                sessionID: InitialSeed.loggerSessionID,
                encounterNumber: 1,
                stepCount: 47,
                movementMode: .running,
                submittedAt: fixedNow,
                measurementUncertainty: 1,
                source: "iPhone logger",
                note: "raw note"
            )
        )
        return state
    }

    func testCompleteJSONBackupRoundTripsWithoutLosingAuditHistoryOrSettings() throws {
        var source = stateWithOneLoggerObservation()
        let index = try XCTUnwrap(source.observations.firstIndex { $0.sessionID == InitialSeed.loggerSessionID })
        source.observations[index].lastEditedAt = fixedNow
        source.observations[index].auditHistory = [
            ObservationAuditEntry(
                id: UUID(uuidString: "E0000000-0000-4000-8000-000000000002")!,
                previousStepCount: 46,
                newStepCount: 47,
                previousMovementMode: .walking,
                newMovementMode: .running,
                editedAt: fixedNow,
                reason: "checked source notes"
            )
        ]
        source.settings.hapticsEnabled = false
        source.settings.defaultMeasurementUncertainty = 2
        source.counter.currentCount = 9
        source.counter.selectedBaseMode = .running

        let data = try ExportService().export(
            state: source,
            selection: .allSessions,
            format: .json,
            content: .completeBackup,
            now: fixedNow
        ).data
        let service = ImportService()
        let preview = service.preview(data: data, filename: "backup.json")

        XCTAssertEqual(preview.detectedFormat, .jsonBackup)
        XCTAssertTrue(preview.isCompleteBackup)
        XCTAssertEqual(preview.sessionCount, source.sessions.count)
        XCTAssertEqual(preview.observationCount, source.observations.count)
        XCTAssertFalse(preview.hasErrors)

        let existing = InitialSeed.makeInitialState(now: fixedNow.addingTimeInterval(-1))
        let result = try service.applying(preview, to: existing, mode: .replace, now: fixedNow)
        XCTAssertTrue(result.restoredCompleteBackup)
        XCTAssertEqual(result.state, source)
        XCTAssertEqual(result.state.observations[index].auditHistory, source.observations[index].auditHistory)
        XCTAssertEqual(result.state.settings, source.settings)
    }

    func testJSONObservationExportCanBePreviewedAndReplaced() throws {
        let source = stateWithOneLoggerObservation()
        let data = try ExportService().export(
            state: source,
            selection: .activeSession,
            format: .json,
            content: .observationsAndSessionMetadata,
            now: fixedNow
        ).data
        let service = ImportService()
        let preview = service.preview(data: data, filename: "observations.json")

        XCTAssertEqual(preview.detectedFormat, .jsonObservations)
        XCTAssertEqual(preview.sessionCount, 1)
        XCTAssertEqual(preview.observationCount, 1)
        XCTAssertEqual(preview.observations[0].stepCount, 47)

        let result = try service.applying(
            preview,
            to: InitialSeed.makeInitialState(now: fixedNow),
            mode: .replace,
            now: fixedNow
        )
        XCTAssertFalse(result.restoredCompleteBackup)
        XCTAssertEqual(result.importedObservationCount, 1)
        XCTAssertEqual(result.state.observations.map(\.stepCount), [47])
        XCTAssertEqual(result.state.sessions.map(\.id), [InitialSeed.loggerSessionID])
    }

    func testDuplicateObservationUUIDIsDetectedAndSkippedDuringMerge() throws {
        let state = stateWithOneLoggerObservation()
        let data = try ExportService().export(
            state: state,
            selection: .activeSession,
            format: .json,
            content: .observationsAndSessionMetadata,
            now: fixedNow
        ).data
        let service = ImportService()
        let preview = service.preview(data: data, filename: "same.json", existingState: state)
        let duplicateID = try XCTUnwrap(
            state.observations.first { $0.sessionID == InitialSeed.loggerSessionID }?.id
        )

        XCTAssertEqual(preview.duplicateObservationIDs, [duplicateID])
        XCTAssertTrue(preview.issues.contains { $0.severity == .warning && $0.message.contains("already exist") })

        let result = try service.applying(preview, to: state, mode: .merge, now: fixedNow)
        XCTAssertEqual(result.duplicateObservationCount, 1)
        XCTAssertEqual(result.importedObservationCount, 0)
        XCTAssertEqual(result.state.observations, state.observations)
    }

    func testCompatibleCSVImportsQuotedFieldsAndExactRawValue() throws {
        let source = stateWithOneLoggerObservation()
        var session = try XCTUnwrap(source.sessions.first { $0.id == InitialSeed.loggerSessionID })
        session.name = "Dungeon, East"
        var observation = try XCTUnwrap(source.observations.first { $0.sessionID == session.id })
        observation.note = "line 1\nline \"2\""
        let data = try ExportService().csvData(
            sessions: [session],
            observations: [observation],
            includeSessionMetadata: true
        )

        let preview = ImportService().preview(data: data, filename: "raw.csv")

        XCTAssertEqual(preview.detectedFormat, .csv)
        XCTAssertEqual(preview.sessionCount, 1)
        XCTAssertEqual(preview.observationCount, 1)
        XCTAssertFalse(preview.hasErrors)
        XCTAssertEqual(preview.sessions[0].name, "Dungeon, East")
        XCTAssertEqual(preview.observations[0].stepCount, 47)
        XCTAssertEqual(preview.observations[0].movementMode, .running)
        XCTAssertEqual(preview.observations[0].note, "line 1\nline \"2\"")
    }

    func testMalformedCSVRowsAreReportedAndNeverSilentlyImported() throws {
        let source = stateWithOneLoggerObservation()
        let session = try XCTUnwrap(source.sessions.first { $0.id == InitialSeed.loggerSessionID })
        let observation = try XCTUnwrap(source.observations.first { $0.sessionID == session.id })
        let valid = try ExportService().csvData(sessions: [session], observations: [observation])
        var text = try XCTUnwrap(String(data: valid, encoding: .utf8))
        text += RFC4180.row([
            session.id.uuidString,
            session.name,
            "not-a-uuid",
            "2",
            "99",
            "Walking",
            ISO8601Coding.string(from: fixedNow),
            "",
            "1",
            "iPhone logger",
            "false",
            "",
            "bad row"
        ]) + "\r\n"

        let preview = ImportService().preview(data: Data(text.utf8), filename: "partly-bad.csv")

        XCTAssertEqual(preview.observationCount, 1)
        XCTAssertEqual(preview.rejectedRowCount, 1)
        XCTAssertTrue(preview.hasErrors)
        XCTAssertTrue(preview.errorReportText.contains("row 3"))
        XCTAssertTrue(preview.errorReportText.contains("Invalid observation_id UUID"))
        XCTAssertThrowsError(
            try ImportService().applying(preview, to: source, mode: .replace, now: fixedNow)
        ) { error in
            XCTAssertEqual(error as? ImportServiceError, .replacementContainsRejectedRows(1))
        }
    }

    func testImportErrorReportIsExportableUTF8() throws {
        let preview = ImportService().preview(
            data: Data("not-json".utf8),
            filename: "bad.json"
        )
        let report = try XCTUnwrap(String(data: preview.errorReportData, encoding: .utf8))
        XCTAssertTrue(report.contains("ERROR"))
        XCTAssertTrue(report.hasSuffix("\n"))
        XCTAssertFalse(preview.canImport)
    }
}

@MainActor
final class AppStoreImportTests: XCTestCase {
    @MainActor
    func testReplaceImportCreatesPreImportBackupBeforeCommitting() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let fixedNow = Date(timeIntervalSince1970: 1_740_000_100)
        let store = try AppStore(persistenceService: environment.persistence, now: { fixedNow })
        _ = try store.increment()
        let previousState = store.state

        var importedState = InitialSeed.makeInitialState(now: fixedNow)
        importedState.counter.currentCount = 77
        let exported = try ExportService().export(
            state: importedState,
            selection: .allSessions,
            format: .json,
            content: .completeBackup,
            now: fixedNow
        )
        let preview = ImportService().preview(data: exported.data, filename: exported.filename)

        let result = try store.applyImport(preview, mode: .replace)

        XCTAssertEqual(result.state.counter.currentCount, 77)
        XCTAssertEqual(store.currentCount, 77)
        let backups = try FileManager.default.contentsOfDirectory(
            at: environment.storeURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("AdventureBar_PreImport_") }
        XCTAssertEqual(backups.count, 1)
        let backedUpState = try environment.persistence.decodeValidatedState(
            from: Data(contentsOf: backups[0])
        )
        XCTAssertEqual(backedUpState, previousState)
    }

    @MainActor
    func testReplacingFromPortableBackupPreservesDeviceReceiverCredential() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let fixedNow = Date(timeIntervalSince1970: 1_740_000_200)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImportSyncURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            ImportSyncURLProtocol.handler = nil
        }
        let uploadReceived = expectation(description: "Imported current state uploaded")
        ImportSyncURLProtocol.handler = { request in
            uploadReceived.fulfill()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 201,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"status":"saved"}"#.utf8))
        }
        let store = try AppStore(
            persistenceService: environment.persistence,
            localTransferService: LocalNetworkTransferService(session: session),
            now: { fixedNow }
        )
        let localSecret = String(repeating: "cd", count: 32)
        var localSettings = store.state.settings
        localSettings.pcReceiverScheme = .http
        localSettings.pcReceiverHost = "203.0.113.10"
        localSettings.pcReceiverPort = 48_765
        localSettings.pcReceiverUploadSecret = localSecret
        localSettings.automaticallySendSnapshotToPC = true
        try store.updateSettings(localSettings)

        var importedState = InitialSeed.makeInitialState(now: fixedNow)
        importedState.settings.pcReceiverScheme = .https
        importedState.settings.pcReceiverHost = "other-device.example"
        importedState.settings.pcReceiverPort = 9_443
        importedState.settings.pcReceiverUploadSecret = ""
        let importedSourceID = importedState.sourceStoreID
        let exported = try ExportService().export(
            state: importedState,
            selection: .allSessions,
            format: .json,
            content: .completeBackup,
            now: fixedNow
        )
        let preview = ImportService().preview(data: exported.data, filename: exported.filename)

        _ = try store.applyImport(preview, mode: .replace)
        await fulfillment(of: [uploadReceived], timeout: 3)
        await store.waitForPendingAutomaticPCSyncForTesting()

        XCTAssertEqual(store.state.settings.pcReceiverScheme, .http)
        XCTAssertEqual(store.state.settings.pcReceiverHost, "203.0.113.10")
        XCTAssertEqual(store.state.settings.pcReceiverPort, 48_765)
        XCTAssertEqual(store.state.settings.pcReceiverUploadSecret, localSecret)
        XCTAssertTrue(store.state.settings.automaticallySendSnapshotToPC)
        XCTAssertNotEqual(store.state.sourceStoreID, importedSourceID)
        XCTAssertEqual(store.state.sourceMutationSequence, 1)
    }
}
