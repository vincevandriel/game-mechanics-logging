import Foundation
@testable import AdventureBarEncounterLogger

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
