import XCTest
@testable import AdventureBarEncounterLogger

final class ExportServiceTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_730_000_000)

    func testRFC4180EscapingCoversCommaQuoteAndNewline() {
        XCTAssertEqual(RFC4180.escapedField("plain"), "plain")
        XCTAssertEqual(RFC4180.escapedField("alpha,beta"), "\"alpha,beta\"")
        XCTAssertEqual(RFC4180.escapedField("say \"hello\""), "\"say \"\"hello\"\"\"")
        XCTAssertEqual(RFC4180.escapedField("line 1\r\nline 2"), "\"line 1\r\nline 2\"")
        XCTAssertEqual(RFC4180.row(["a,b", "c", "d\"e"]), "\"a,b\",c,\"d\"\"e\"")
    }

    func testCSVExportUsesRequiredColumnsOneObservationPerRecordAndCRLF() throws {
        var state = InitialSeed.makeInitialState(now: fixedNow)
        let sessionIndex = try XCTUnwrap(state.sessions.firstIndex { $0.id == InitialSeed.loggerSessionID })
        state.sessions[sessionIndex].name = "Session, \"A\""
        state.observations.append(
            EncounterObservation(
                id: UUID(uuidString: "D0000000-0000-4000-8000-000000000001")!,
                sessionID: InitialSeed.loggerSessionID,
                encounterNumber: 1,
                stepCount: 47,
                movementMode: .mixedUncertain,
                submittedAt: fixedNow,
                measurementUncertainty: 1,
                source: "iPhone logger",
                note: "line 1\nline 2"
            )
        )

        let exported = try ExportService().export(
            state: state,
            selection: .activeSession,
            format: .csv,
            content: .observationsOnly,
            now: fixedNow
        )
        let csv = try XCTUnwrap(String(data: exported.data, encoding: .utf8))

        XCTAssertEqual(exported.format, .csv)
        XCTAssertEqual(exported.sessionCount, 1)
        XCTAssertEqual(exported.observationCount, 1)
        XCTAssertEqual(csv.components(separatedBy: "\r\n").count, 3)
        XCTAssertTrue(csv.hasSuffix("\r\n"))
        XCTAssertTrue(csv.hasPrefix(ExportService.requiredCSVColumns.joined(separator: ",") + "\r\n"))
        XCTAssertTrue(csv.contains("\"Session, \"\"A\"\"\""))
        XCTAssertTrue(csv.contains(",47,Mixed/Uncertain,"))
        XCTAssertTrue(csv.contains("\"line 1\nline 2\""))
    }

    func testCompleteJSONExportPreservesSettingsCounterUndoDeletedRecordsAndAuditHistory() throws {
        var state = InitialSeed.makeInitialState(now: fixedNow)
        let sessionID = InitialSeed.loggerSessionID
        var observation = EncounterObservation(
            id: UUID(uuidString: "D0000000-0000-4000-8000-000000000002")!,
            sessionID: sessionID,
            encounterNumber: 1,
            stepCount: 12,
            movementMode: .walking,
            submittedAt: fixedNow,
            lastEditedAt: fixedNow,
            measurementUncertainty: 2,
            source: "iPhone logger"
        )
        observation.auditHistory = [
            ObservationAuditEntry(
                id: UUID(uuidString: "D0000000-0000-4000-8000-000000000003")!,
                previousStepCount: 11,
                newStepCount: 12,
                previousMovementMode: .running,
                newMovementMode: .walking,
                editedAt: fixedNow,
                reason: "corrected"
            )
        ]
        state.observations.append(observation)
        state.counter.currentCount = 4
        state.counter.selectedBaseMode = .running
        state.settings.hapticsEnabled = false
        state.settings.pcReceiverHost = "192.168.1.10"
        state.pendingUndo = PendingUndo(
            observation: observation,
            selectorModeAtSubmission: .walking,
            createdAt: fixedNow
        )

        let exported = try ExportService().export(
            state: state,
            selection: .activeSession,
            format: .json,
            content: .completeBackup,
            now: fixedNow
        )
        let envelope = try JSONCoding.makeDecoder().decode(JSONExportEnvelope.self, from: exported.data)

        XCTAssertEqual(envelope.schemaVersion, PersistentAppState.currentSchemaVersion)
        XCTAssertEqual(envelope.fullStoreRevision, state.fullStoreRevision)
        XCTAssertEqual(envelope.sourceStoreID, state.sourceStoreID)
        XCTAssertEqual(envelope.sourceMutationSequence, state.sourceMutationSequence)
        XCTAssertEqual(envelope.exportFormatVersion, JSONExportEnvelope.currentExportFormatVersion)
        XCTAssertEqual(envelope.exportedAt, fixedNow)
        XCTAssertEqual(envelope.content, .completeBackup)
        XCTAssertEqual(envelope.sessions, state.sessions)
        XCTAssertEqual(envelope.observations, state.observations)
        XCTAssertEqual(envelope.settings, state.settings)
        XCTAssertEqual(envelope.counter, state.counter)
        XCTAssertEqual(envelope.pendingUndo, state.pendingUndo)
        XCTAssertEqual(envelope.deletedObservations, state.deletedObservations)
        XCTAssertEqual(envelope.seedDataVersion, state.seedDataVersion)
        XCTAssertEqual(envelope.storeLastModifiedAt, state.lastModifiedAt)
        XCTAssertEqual(envelope.observations.last?.auditHistory, observation.auditHistory)
    }

    func testJSONExportNeverContainsPCReceiverUploadSecret() throws {
        var state = InitialSeed.makeInitialState(now: fixedNow)
        let secret = String(repeating: "ab", count: 32)
        state.settings.pcReceiverHost = "203.0.113.10"
        state.settings.pcReceiverUploadSecret = secret
        state.settings.automaticallySendSnapshotToPC = true

        let exported = try ExportService().export(
            state: state,
            selection: .allSessions,
            format: .json,
            content: .completeBackup,
            now: fixedNow
        )
        let envelope = try JSONCoding.makeDecoder().decode(JSONExportEnvelope.self, from: exported.data)
        let rawJSON = try XCTUnwrap(String(data: exported.data, encoding: .utf8))

        XCTAssertEqual(envelope.settings.pcReceiverUploadSecret, "")
        XCTAssertFalse(envelope.settings.automaticallySendSnapshotToPC)
        XCTAssertFalse(rawJSON.contains(secret))
        XCTAssertEqual(envelope.settings.pcReceiverHost, state.settings.pcReceiverHost)
    }

    func testCompleteBackupRejectsCSV() throws {
        let state = InitialSeed.makeInitialState(now: fixedNow)
        XCTAssertThrowsError(
            try ExportService().export(
                state: state,
                selection: .allSessions,
                format: .csv,
                content: .completeBackup,
                now: fixedNow
            )
        ) { error in
            XCTAssertEqual(error as? ExportServiceError, .completeBackupRequiresJSON)
        }
    }

    func testManualExportWriteNeverOverwritesAnExistingFilename() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let state = InitialSeed.makeInitialState(now: fixedNow)
        let service = ExportService()
        let exported = try service.export(
            state: state,
            selection: .activeSession,
            format: .json,
            content: .observationsAndSessionMetadata,
            now: fixedNow
        )

        let first = try service.write(exported, to: environment.documentsURL)
        let second = try service.write(exported, to: environment.documentsURL)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), exported.data)
        XCTAssertEqual(try Data(contentsOf: second), exported.data)
    }

    func testSnapshotServiceWritesPredictableCurrentFilenames() throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let state = InitialSeed.makeInitialState(now: fixedNow)

        let urls = try ExportSnapshotService(directoryURL: environment.documentsURL)
            .writeCurrentSnapshots(for: state, now: fixedNow)

        XCTAssertEqual(urls.csv.lastPathComponent, "AdventureBar_CurrentData.csv")
        XCTAssertEqual(urls.json.lastPathComponent, "AdventureBar_CurrentData.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls.csv.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls.json.path))
        let envelope = try JSONCoding.makeDecoder().decode(
            JSONExportEnvelope.self,
            from: Data(contentsOf: urls.json)
        )
        XCTAssertEqual(envelope.observations.count, 40)
        XCTAssertEqual(envelope.sessions.count, 2)
    }

    func testSnapshotWriterRejectsAnOlderGenerationAfterNewerDataWasWritten() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let service = ExportSnapshotService(directoryURL: environment.documentsURL)
        let writer = SnapshotFileWriter(service: service)
        let oldState = InitialSeed.makeInitialState(now: fixedNow)
        var newState = oldState
        newState.observations[0].stepCount = 999
        let oldPayloads = try service.makeCurrentSnapshotPayloads(for: oldState, now: fixedNow)
        let newPayloads = try service.makeCurrentSnapshotPayloads(
            for: newState,
            now: fixedNow.addingTimeInterval(1)
        )

        _ = try await writer.write(newPayloads, generation: 2)
        let ignored = try await writer.write(oldPayloads, generation: 1)

        XCTAssertNil(ignored)
        let jsonURL = environment.documentsURL.appendingPathComponent(ExportSnapshotService.jsonFilename)
        let envelope = try JSONCoding.makeDecoder().decode(
            JSONExportEnvelope.self,
            from: Data(contentsOf: jsonURL)
        )
        XCTAssertEqual(envelope.observations.first?.stepCount, 999)
    }
}

@MainActor
final class AppStoreSnapshotTests: XCTestCase {
    func testEnabledSnapshotsAreUpdatedAfterSubmission() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let fixedNow = Date(timeIntervalSince1970: 1_730_000_100)
        let store = try AppStore(
            persistenceService: environment.persistence,
            now: { fixedNow }
        )
        var settings = store.state.settings
        settings.createExportSnapshotsAfterEverySubmission = true
        try store.updateSettings(settings)
        _ = try store.increment()
        let submitted = try store.submitCurrentCount()
        await store.waitForPendingSnapshotRefreshForTesting()

        let jsonURL = environment.documentsURL.appendingPathComponent(ExportSnapshotService.jsonFilename)
        let csvURL = environment.documentsURL.appendingPathComponent(ExportSnapshotService.csvFilename)
        let envelope = try JSONCoding.makeDecoder().decode(
            JSONExportEnvelope.self,
            from: Data(contentsOf: jsonURL)
        )

        XCTAssertTrue(envelope.observations.contains { $0.id == submitted.id && $0.stepCount == 1 })
        let csv = try XCTUnwrap(String(data: Data(contentsOf: csvURL), encoding: .utf8))
        XCTAssertTrue(csv.contains(submitted.id.uuidString))
    }
}
