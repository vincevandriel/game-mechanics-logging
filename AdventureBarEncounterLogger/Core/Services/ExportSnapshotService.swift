import Foundation

public struct SnapshotURLs: Equatable, Sendable {
    public var csv: URL
    public var json: URL

    public init(csv: URL, json: URL) {
        self.csv = csv
        self.json = json
    }
}

public struct SnapshotPayloads: Equatable, Sendable {
    public var csv: Data
    public var json: Data

    public init(csv: Data, json: Data) {
        self.csv = csv
        self.json = json
    }
}

public final class ExportSnapshotService: @unchecked Sendable {
    public static let csvFilename = "AdventureBar_CurrentData.csv"
    public static let jsonFilename = "AdventureBar_CurrentData.json"

    public let directoryURL: URL
    private let exportService: ExportService
    private let fileManager: FileManager

    public init(
        directoryURL: URL,
        exportService: ExportService = ExportService(),
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.exportService = exportService
        self.fileManager = fileManager
    }

    @discardableResult
    public func writeCurrentSnapshots(for state: PersistentAppState, now: Date = Date()) throws -> SnapshotURLs {
        let payloads = try makeCurrentSnapshotPayloads(for: state, now: now)
        return try write(payloads)
    }

    public func makeCurrentSnapshotPayloads(
        for state: PersistentAppState,
        now: Date = Date()
    ) throws -> SnapshotPayloads {
        try Task.checkCancellation()
        let csv = try exportService.export(
            state: state,
            selection: .allSessions,
            format: .csv,
            content: .observationsAndSessionMetadata,
            now: now
        )
        try Task.checkCancellation()
        let json = try exportService.export(
            state: state,
            selection: .allSessions,
            format: .json,
            content: .observationsAndSessionMetadata,
            now: now
        )
        try Task.checkCancellation()
        return SnapshotPayloads(csv: csv.data, json: json.data)
    }

    public func write(_ payloads: SnapshotPayloads) throws -> SnapshotURLs {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let csvURL = directoryURL.appendingPathComponent(Self.csvFilename)
        let jsonURL = directoryURL.appendingPathComponent(Self.jsonFilename)
        try payloads.csv.write(to: csvURL, options: [.atomic])
        try payloads.json.write(to: jsonURL, options: [.atomic])
        return SnapshotURLs(csv: csvURL, json: jsonURL)
    }
}

/// Serializes predictable-filename writes and rejects any generation older
/// than one already written, so a slow old export cannot overwrite new data.
public actor SnapshotFileWriter {
    private let service: ExportSnapshotService
    private var latestWrittenGeneration: UInt64 = 0

    public init(service: ExportSnapshotService) {
        self.service = service
    }

    @discardableResult
    public func write(
        _ payloads: SnapshotPayloads,
        generation: UInt64
    ) throws -> SnapshotURLs? {
        guard generation >= latestWrittenGeneration else { return nil }
        let urls = try service.write(payloads)
        latestWrittenGeneration = generation
        return urls
    }
}
