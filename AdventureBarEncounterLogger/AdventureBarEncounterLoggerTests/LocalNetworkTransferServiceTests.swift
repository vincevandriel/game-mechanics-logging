import XCTest
@testable import AdventureBarEncounterLogger

private final class StubURLProtocol: URLProtocol {
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

final class LocalNetworkTransferServiceTests: XCTestCase {
    private var urlSession: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        urlSession = URLSession(configuration: configuration)
    }

    override func tearDown() {
        urlSession.invalidateAndCancel()
        urlSession = nil
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testConnectionUsesHealthEndpointAndParsesReceiverStatus() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://192.168.1.20:8765/health")
            XCTAssertEqual(request.httpMethod, "GET")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"status":"ok"}"#.utf8))
        }

        let result = try await LocalNetworkTransferService(session: urlSession)
            .testConnection(host: "192.168.1.20", port: 8765)

        XCTAssertEqual(result, "ok")
    }

    func testHTTPSConnectionConfigurationUsesHTTPSAndLeavesHealthUnsigned() async throws {
        let secret = String(repeating: "a", count: 64)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://logger.example.test:443/health")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: ReceiverRequestSigner.signatureHeader))
            XCTAssertNil(request.value(forHTTPHeaderField: ReceiverRequestSigner.timestampHeader))
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"message":"reachable"}"#.utf8))
        }

        let result = try await LocalNetworkTransferService(session: urlSession).testConnection(
            configuration: ReceiverConfiguration(
                scheme: .https,
                host: "logger.example.test",
                port: 443,
                uploadSecret: secret
            )
        )

        XCTAssertEqual(result, "reachable")
    }

    func testUploadUsesRawBodyContentTypeAndSafeFilenameHeader() async throws {
        let body = Data(#"{"sessions":[],"observations":[]}"#.utf8)
        let exported = ExportedFile(
            filename: "AdventureBar_Test.json",
            data: body,
            format: .json,
            contentType: "application/json",
            sessionCount: 0,
            observationCount: 0
        )
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://pc.local:9000/upload")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Filename"), exported.filename)
            XCTAssertNil(request.value(forHTTPHeaderField: ReceiverRequestSigner.signatureHeader))
            XCTAssertEqual(requestBodyData(request), body)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 201,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"status":"saved"}"#.utf8))
        }

        let receipt = try await LocalNetworkTransferService(session: urlSession)
            .upload(exported, host: "pc.local", port: 9000)

        XCTAssertEqual(receipt.statusCode, 201)
        XCTAssertEqual(receipt.message, "saved")
    }

    func testSignedUploadUsesDeterministicCanonicalHMACHeaders() async throws {
        let body = Data(#"{"sessions":[],"observations":[]}"#.utf8)
        let exported = ExportedFile(
            filename: "AdventureBar_Test.json",
            data: body,
            format: .json,
            contentType: "application/json; charset=utf-8",
            sessionCount: 0,
            observationCount: 0
        )
        let secret = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        let nonce = "123e4567-e89b-12d3-a456-426614174000"
        let expectedBodyHash = "872b471c1c219036676622e2aaa862b5065f3054104774175987950307851cfd"
        let expectedSignature = "v1=30337b005da1b96e8570a187340c8e05361f9fabdfe8899fe49e354e838ba92c"

        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://logger.example.test:8443/upload")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Filename"), "AdventureBar_Test.json")
            XCTAssertEqual(request.value(forHTTPHeaderField: ReceiverRequestSigner.timestampHeader), "1750000000")
            XCTAssertEqual(request.value(forHTTPHeaderField: ReceiverRequestSigner.nonceHeader), nonce)
            XCTAssertEqual(request.value(forHTTPHeaderField: ReceiverRequestSigner.contentSHA256Header), expectedBodyHash)
            XCTAssertEqual(request.value(forHTTPHeaderField: ReceiverRequestSigner.signatureHeader), expectedSignature)
            XCTAssertEqual(requestBodyData(request), body)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 201,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"status":"saved"}"#.utf8))
        }

        let service = LocalNetworkTransferService(
            session: urlSession,
            now: { Date(timeIntervalSince1970: 1_750_000_000.75) },
            nonce: { nonce.uppercased() }
        )
        let receipt = try await service.upload(
            exported,
            configuration: ReceiverConfiguration(
                scheme: .https,
                host: "logger.example.test",
                port: 8443,
                uploadSecret: secret.uppercased()
            )
        )

        XCTAssertEqual(receipt.statusCode, 201)
    }

    func testCanonicalRequestMatchesDocumentedProtocolExactly() throws {
        let body = Data(#"{"sessions":[],"observations":[]}"#.utf8)
        let result = try ReceiverRequestSigner.sign(
            method: "post",
            path: "/upload",
            timestamp: 1_750_000_000,
            nonce: "123E4567-E89B-12D3-A456-426614174000",
            contentType: "Application/JSON; charset=utf-8",
            filename: " AdventureBar_Test.json ",
            body: body,
            secret: " 000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F "
        )
        let expected = [
            "ABES1",
            "POST",
            "/upload",
            "1750000000",
            "123e4567-e89b-12d3-a456-426614174000",
            "application/json",
            "AdventureBar_Test.json",
            "872b471c1c219036676622e2aaa862b5065f3054104774175987950307851cfd"
        ].joined(separator: "\n")

        XCTAssertEqual(result.canonicalRequest, expected)
        XCTAssertFalse(result.canonicalRequest.hasSuffix("\n"))
        XCTAssertEqual(result.authorizationValue, "v1=30337b005da1b96e8570a187340c8e05361f9fabdfe8899fe49e354e838ba92c")
    }

    func testInvalidUploadSecretFailsBeforeNetworkRequest() async throws {
        StubURLProtocol.handler = { _ in
            XCTFail("An invalid secret must be rejected before URLSession is used")
            throw URLError(.badServerResponse)
        }
        let exported = ExportedFile(
            filename: "AdventureBar_Test.json",
            data: Data("{}".utf8),
            format: .json,
            contentType: "application/json",
            sessionCount: 0,
            observationCount: 0
        )

        do {
            _ = try await LocalNetworkTransferService(session: urlSession).upload(
                exported,
                configuration: ReceiverConfiguration(
                    scheme: .https,
                    host: "logger.example.test",
                    port: 443,
                    uploadSecret: "not-a-64-character-hex-secret"
                )
            )
            XCTFail("An invalid secret must be rejected")
        } catch let error as LocalTransferError {
            XCTAssertEqual(error, .invalidUploadSecret)
        }
    }

    func testGeneratedUploadSecretIsAValid256BitHexKey() {
        let secret = ReceiverRequestSigner.generateSecret()
        XCTAssertEqual(secret.count, 64)
        XCTAssertTrue(ReceiverRequestSigner.isValidSecret(secret, allowingEmpty: false))
        XCTAssertEqual(secret, secret.lowercased())
    }

    @MainActor
    func testRejectedTransferDoesNotChangeMemoryOrPersistentData() async throws {
        let environment = try TestEnvironment()
        defer { environment.remove() }
        let fixedNow = Date(timeIntervalSince1970: 1_750_000_000)
        let transfer = LocalNetworkTransferService(session: urlSession)
        let store = try AppStore(
            persistenceService: environment.persistence,
            localTransferService: transfer,
            now: { fixedNow }
        )
        var settings = store.state.settings
        settings.pcReceiverHost = "192.168.1.20"
        try store.updateSettings(settings)
        for _ in 0..<3 { _ = try store.increment() }
        let submitted = try store.submitCurrentCount()
        let observationsBeforeTransfer = store.state.observations
        let sessionsBeforeTransfer = store.state.sessions
        let counterBeforeTransfer = store.state.counter
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 503,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error":"receiver unavailable"}"#.utf8))
        }

        do {
            _ = try await store.transferExport(
                selection: .activeSession,
                format: .json,
                content: .observationsAndSessionMetadata
            )
            XCTFail("A 503 response must not be reported as success")
        } catch let error as LocalTransferError {
            guard case .receiverRejected(let code, _) = error else {
                return XCTFail("Unexpected local-transfer error: \(error)")
            }
            XCTAssertEqual(code, 503)
        }

        XCTAssertEqual(store.state.observations, observationsBeforeTransfer)
        XCTAssertEqual(store.state.sessions, sessionsBeforeTransfer)
        XCTAssertEqual(store.state.counter, counterBeforeTransfer)
        XCTAssertEqual(store.lastPCTransferStatus?.succeeded, false)
        XCTAssertEqual(store.lastPCTransferStatus?.automatic, false)
        XCTAssertTrue(store.state.observations.contains { $0.id == submitted.id })
        let persisted = try environment.persistence.decodeValidatedState(
            from: Data(contentsOf: environment.persistence.primaryStoreURL)
        )
        XCTAssertEqual(persisted.observations, observationsBeforeTransfer)
        XCTAssertEqual(persisted.sessions, sessionsBeforeTransfer)
        XCTAssertEqual(persisted.counter, counterBeforeTransfer)
    }

    func testInvalidReceiverAddressIsRejectedBeforeNetworkUse() throws {
        let service = LocalNetworkTransferService(session: urlSession)
        XCTAssertThrowsError(try service.makeBaseURL(host: "", port: 8765)) { error in
            XCTAssertEqual(error as? LocalTransferError, .invalidHost)
        }
        XCTAssertThrowsError(try service.makeBaseURL(host: "192.168.1.20", port: 70_000)) { error in
            XCTAssertEqual(error as? LocalTransferError, .invalidPort)
        }
        XCTAssertEqual(
            try service.makeBaseURL(
                configuration: ReceiverConfiguration(scheme: .https, host: "example.test", port: 443)
            ).absoluteString,
            "https://example.test:443"
        )
    }

    func testLegacySettingsDecodeWithSecureReceiverDefaults() throws {
        let legacyJSON = Data(#"""
        {
          "hapticsEnabled": false,
          "keepScreenAwake": true,
          "defaultMeasurementUncertainty": 2,
          "confirmZeroSubmission": true,
          "confirmUndoReplaceNonzero": true,
          "createExportSnapshotsAfterEverySubmission": false,
          "lastExportFormat": "json",
          "pcReceiverHost": "192.168.1.20",
          "pcReceiverPort": 8765,
          "appearance": "system",
          "soundFeedbackEnabled": false
        }
        """#.utf8)

        let settings = try JSONCoding.makeDecoder().decode(AppSettings.self, from: legacyJSON)

        XCTAssertEqual(settings.pcReceiverScheme, .http)
        XCTAssertEqual(settings.pcReceiverUploadSecret, "")
        XCTAssertFalse(settings.automaticallySendSnapshotToPC)
        XCTAssertEqual(settings.receiverConfiguration.host, "192.168.1.20")
    }

    func testNewReceiverSettingsRoundTripAndNormalizeSecret() throws {
        let uppercaseSecret = String(repeating: "A1", count: 32)
        let original = AppSettings(
            pcReceiverHost: " logger.example.test ",
            pcReceiverPort: 443,
            pcReceiverScheme: .https,
            pcReceiverUploadSecret: " \(uppercaseSecret) ",
            automaticallySendSnapshotToPC: true
        )

        let data = try JSONCoding.makeEncoder(prettyPrinted: false).encode(original)
        let decoded = try JSONCoding.makeDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.pcReceiverUploadSecret, uppercaseSecret.lowercased())
        XCTAssertEqual(decoded.receiverConfiguration.scheme, .https)
        XCTAssertTrue(decoded.receiverConfiguration.usesSignedUploads)
    }
}
