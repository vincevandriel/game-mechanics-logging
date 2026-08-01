import Foundation
@testable import AdventureBarEncounterLogger

func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }

    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { return nil }
        if count == 0 { return result }
        result.append(contentsOf: buffer.prefix(count))
    }
}

struct TestEnvironment {
    let rootURL: URL
    let storeURL: URL
    let documentsURL: URL
    let persistence: PersistenceService

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdventureBarTests-\(UUID().uuidString)", isDirectory: true)
        storeURL = rootURL.appendingPathComponent("ApplicationSupport", isDirectory: true)
        documentsURL = rootURL.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        persistence = PersistenceService(
            directoryURL: storeURL,
            documentsDirectoryURL: documentsURL
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

final class DeterministicUUIDFactory {
    private var counter = 100

    func next() -> UUID {
        defer { counter += 1 }
        let suffix = String(format: "%012d", counter)
        return UUID(uuidString: "C0000000-0000-4000-8000-\(suffix)")!
    }
}
