import CryptoKit
import Foundation

public struct TransferHealthResult: Equatable {
    public var statusCode: Int
    public var message: String

    public init(statusCode: Int, message: String) {
        self.statusCode = statusCode
        self.message = message
    }
}

public struct TransferReceipt: Equatable {
    public var statusCode: Int
    public var message: String
    public var responseData: Data

    public init(statusCode: Int, message: String, responseData: Data) {
        self.statusCode = statusCode
        self.message = message
        self.responseData = responseData
    }
}

public struct ReceiverRequestSignature: Equatable {
    public let timestamp: String
    public let nonce: String
    public let bodySHA256: String
    public let canonicalRequest: String
    public let authorizationValue: String
}

public enum LocalTransferError: LocalizedError, Equatable {
    case invalidHost
    case invalidPort
    case invalidUploadSecret
    case invalidFilename
    case invalidContentType
    case invalidNonce
    case invalidResponse
    case receiverRejected(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidHost: return "Enter the PC receiver's IP address or host name."
        case .invalidPort: return "The PC receiver port must be between 1 and 65535."
        case .invalidUploadSecret: return "The upload secret must be empty or exactly 64 hexadecimal characters."
        case .invalidFilename: return "The exported filename is not safe to send."
        case .invalidContentType: return "Only JSON and CSV exports can be sent to the PC receiver."
        case .invalidNonce: return "The upload request nonce is invalid."
        case .invalidResponse: return "The PC receiver returned a response that was not HTTP."
        case .receiverRejected(let statusCode, let message): return "The PC receiver returned HTTP \(statusCode): \(message)"
        }
    }
}

public enum ReceiverRequestSigner {
    public static let protocolMarker = "ABES1"
    public static let timestampHeader = "X-Adventure-Timestamp"
    public static let nonceHeader = "X-Adventure-Nonce"
    public static let contentSHA256Header = "X-Adventure-Content-SHA256"
    public static let signatureHeader = "X-Adventure-Signature"

    public static func normalizedSecret(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func isValidSecret(_ value: String, allowingEmpty: Bool = true) -> Bool {
        let normalized = normalizedSecret(value)
        if normalized.isEmpty { return allowingEmpty }
        return normalized.count == 64 && normalized.unicodeScalars.allSatisfy(Self.isLowercaseHexScalar)
    }

    public static func generateSecret() -> String {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0).lowercaseHexString }
    }

    public static func sign(
        method: String,
        path: String,
        timestamp: Int64,
        nonce: String,
        contentType: String,
        filename: String,
        body: Data,
        secret: String
    ) throws -> ReceiverRequestSignature {
        let normalizedSecret = normalizedSecret(secret)
        guard isValidSecret(normalizedSecret, allowingEmpty: false),
              let secretData = Data(lowercaseHexString: normalizedSecret) else {
            throw LocalTransferError.invalidUploadSecret
        }

        let normalizedMethod = method.uppercased()
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        let normalizedContentType = try normalizeContentType(contentType)
        let normalizedFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFilename.isEmpty,
              !normalizedFilename.contains("\r"),
              !normalizedFilename.contains("\n") else {
            throw LocalTransferError.invalidFilename
        }

        let normalizedNonce = nonce.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedNonce.isEmpty,
              normalizedNonce.count <= 128,
              normalizedNonce.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
              }) else {
            throw LocalTransferError.invalidNonce
        }

        let bodySHA256 = Data(SHA256.hash(data: body)).lowercaseHexString
        let timestampString = String(timestamp)
        let canonicalRequest = [
            protocolMarker,
            normalizedMethod,
            normalizedPath,
            timestampString,
            normalizedNonce,
            normalizedContentType,
            normalizedFilename,
            bodySHA256
        ].joined(separator: "\n")
        let key = SymmetricKey(data: secretData)
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: Data(canonicalRequest.utf8),
            using: key
        )
        let signature = Data(authenticationCode).lowercaseHexString

        return ReceiverRequestSignature(
            timestamp: timestampString,
            nonce: normalizedNonce,
            bodySHA256: bodySHA256,
            canonicalRequest: canonicalRequest,
            authorizationValue: "v1=\(signature)"
        )
    }

    public static func normalizeContentType(_ value: String) throws -> String {
        let baseType = value
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard baseType == "application/json" || baseType == "text/csv" else {
            throw LocalTransferError.invalidContentType
        }
        return baseType
    }

    private static func isLowercaseHexScalar(_ scalar: UnicodeScalar) -> Bool {
        (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
    }
}

public final class LocalNetworkTransferService {
    private let session: URLSession
    private let now: () -> Date
    private let nonce: () -> String

    public init(
        session: URLSession = .shared,
        now: @escaping () -> Date = { Date() },
        nonce: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.session = session
        self.now = now
        self.nonce = nonce
    }

    public func testConnection(host: String, port: Int) async throws -> String {
        try await testConnectionResult(host: host, port: port).message
    }

    public func testConnection(configuration: ReceiverConfiguration) async throws -> String {
        try await testConnectionResult(configuration: configuration).message
    }

    public func testConnectionResult(host: String, port: Int) async throws -> TransferHealthResult {
        let baseURL = try makeBaseURL(host: host, port: port)
        return try await testConnectionResult(baseURL: baseURL)
    }

    public func testConnectionResult(configuration: ReceiverConfiguration) async throws -> TransferHealthResult {
        let baseURL = try makeBaseURL(configuration: configuration)
        return try await testConnectionResult(baseURL: baseURL)
    }

    public func upload(_ exportedFile: ExportedFile, host: String, port: Int) async throws -> TransferReceipt {
        let baseURL = try makeBaseURL(host: host, port: port)
        return try await upload(exportedFile, baseURL: baseURL, uploadSecret: "")
    }

    public func upload(_ exportedFile: ExportedFile, configuration: ReceiverConfiguration) async throws -> TransferReceipt {
        let baseURL = try makeBaseURL(configuration: configuration)
        return try await upload(exportedFile, baseURL: baseURL, uploadSecret: configuration.uploadSecret)
    }

    public func makeBaseURL(host: String, port: Int) throws -> URL {
        try makeBaseURL(host: host, port: port, scheme: nil)
    }

    public func makeBaseURL(configuration: ReceiverConfiguration) throws -> URL {
        try makeBaseURL(host: configuration.host, port: configuration.port, scheme: configuration.scheme)
    }

    private func testConnectionResult(baseURL: URL) async throws -> TransferHealthResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalTransferError.invalidResponse }
        let message = responseMessage(from: data, fallback: http.statusCode == 200 ? "PC receiver is reachable." : "Health check failed.")
        guard (200...299).contains(http.statusCode) else {
            throw LocalTransferError.receiverRejected(statusCode: http.statusCode, message: message)
        }
        return TransferHealthResult(statusCode: http.statusCode, message: message)
    }

    private func upload(_ exportedFile: ExportedFile, baseURL: URL, uploadSecret: String) async throws -> TransferReceipt {
        let contentType = try ReceiverRequestSigner.normalizeContentType(exportedFile.contentType)
        let filename = exportedFile.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filename.isEmpty, !filename.contains("\r"), !filename.contains("\n") else {
            throw LocalTransferError.invalidFilename
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("upload"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = exportedFile.data
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(filename, forHTTPHeaderField: "X-Filename")
        request.setValue(String(exportedFile.data.count), forHTTPHeaderField: "Content-Length")

        let normalizedSecret = ReceiverRequestSigner.normalizedSecret(uploadSecret)
        if !normalizedSecret.isEmpty {
            let signature = try ReceiverRequestSigner.sign(
                method: "POST",
                path: "/upload",
                timestamp: Int64(now().timeIntervalSince1970.rounded(.down)),
                nonce: nonce(),
                contentType: contentType,
                filename: filename,
                body: exportedFile.data,
                secret: normalizedSecret
            )
            request.setValue(signature.timestamp, forHTTPHeaderField: ReceiverRequestSigner.timestampHeader)
            request.setValue(signature.nonce, forHTTPHeaderField: ReceiverRequestSigner.nonceHeader)
            request.setValue(signature.bodySHA256, forHTTPHeaderField: ReceiverRequestSigner.contentSHA256Header)
            request.setValue(signature.authorizationValue, forHTTPHeaderField: ReceiverRequestSigner.signatureHeader)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalTransferError.invalidResponse }
        let message = responseMessage(from: data, fallback: (200...299).contains(http.statusCode) ? "Upload saved by PC receiver." : "Upload failed.")
        guard (200...299).contains(http.statusCode) else {
            throw LocalTransferError.receiverRejected(statusCode: http.statusCode, message: message)
        }
        return TransferReceipt(statusCode: http.statusCode, message: message, responseData: data)
    }

    private func makeBaseURL(host: String, port: Int, scheme: ReceiverScheme?) throws -> URL {
        guard (1...65_535).contains(port) else { throw LocalTransferError.invalidPort }
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalTransferError.invalidHost }

        if let scheme {
            trimmed = Self.removingHTTPPrefix(from: trimmed)
            trimmed = "\(scheme.rawValue)://\(trimmed)"
        } else if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "http://\(trimmed)"
        }

        guard var components = URLComponents(string: trimmed),
              components.scheme == ReceiverScheme.http.rawValue || components.scheme == ReceiverScheme.https.rawValue,
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw LocalTransferError.invalidHost
        }
        components.port = port
        components.path = ""
        guard let url = components.url else { throw LocalTransferError.invalidHost }
        return url
    }

    private static func removingHTTPPrefix(from host: String) -> String {
        let lowercased = host.lowercased()
        if lowercased.hasPrefix("http://") { return String(host.dropFirst(7)) }
        if lowercased.hasPrefix("https://") { return String(host.dropFirst(8)) }
        return host
    }

    private func responseMessage(from data: Data, fallback: String) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "saved_path", "path", "status", "error"] {
                if let value = object[key] as? String, !value.isEmpty { return value }
            }
        }
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return String(text.prefix(500))
        }
        return fallback
    }
}

private extension Data {
    init?(lowercaseHexString: String) {
        guard lowercaseHexString.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(lowercaseHexString.count / 2)
        var index = lowercaseHexString.startIndex
        while index < lowercaseHexString.endIndex {
            let next = lowercaseHexString.index(index, offsetBy: 2)
            guard let byte = UInt8(lowercaseHexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var lowercaseHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
