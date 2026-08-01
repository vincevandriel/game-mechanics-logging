import Foundation

public enum PersistenceError: LocalizedError {
    case cannotLocateApplicationSupport
    case cannotLocateDocuments
    case corruptPrimaryAndNoUsableBackup(primary: String, backup: String?)
    case invalidStore(String)

    public var errorDescription: String? {
        switch self {
        case .cannotLocateApplicationSupport:
            return "Could not locate the app's Application Support directory."
        case .cannotLocateDocuments:
            return "Could not locate the app's Documents directory."
        case .corruptPrimaryAndNoUsableBackup(let primary, let backup):
            if let backup {
                return "The primary data file is invalid (\(primary)) and its backup is also invalid (\(backup)). No files were overwritten."
            }
            return "The primary data file is invalid (\(primary)) and no usable backup exists. No files were overwritten."
        case .invalidStore(let reason):
            return "The data store is invalid: \(reason)"
        }
    }
}

public final class PersistenceService {
    public static let primaryFilename = "AdventureBarEncounterLoggerStore.json"
    public static let backupFilename = "AdventureBarEncounterLoggerStore.backup.json"
    public static let counterCheckpointFilename = "AdventureBarCounterCheckpoint.json"
    public static let counterCheckpointBackupFilename = "AdventureBarCounterCheckpoint.backup.json"

    public let directoryURL: URL
    public let documentsDirectoryURL: URL
    public let primaryStoreURL: URL
    public let backupStoreURL: URL
    public let counterCheckpointURL: URL
    public let counterCheckpointBackupURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        directoryURL: URL,
        documentsDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.documentsDirectoryURL = documentsDirectoryURL ?? directoryURL
        self.primaryStoreURL = directoryURL.appendingPathComponent(Self.primaryFilename, isDirectory: false)
        self.backupStoreURL = directoryURL.appendingPathComponent(Self.backupFilename, isDirectory: false)
        self.counterCheckpointURL = directoryURL.appendingPathComponent(Self.counterCheckpointFilename, isDirectory: false)
        self.counterCheckpointBackupURL = directoryURL.appendingPathComponent(Self.counterCheckpointBackupFilename, isDirectory: false)
        self.fileManager = fileManager
        self.encoder = JSONCoding.makeEncoder()
        self.decoder = JSONCoding.makeDecoder()
    }

    public static func live() throws -> PersistenceService {
        let manager = FileManager.default
        guard let applicationSupport = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw PersistenceError.cannotLocateApplicationSupport
        }
        guard let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw PersistenceError.cannotLocateDocuments
        }
        let directory = applicationSupport.appendingPathComponent("AdventureBarEncounterLogger", isDirectory: true)
        return PersistenceService(directoryURL: directory, documentsDirectoryURL: documents, fileManager: manager)
    }

    public func loadOrCreate(now: Date = Date()) throws -> PersistentAppState {
        try ensureDirectoriesExist()

        if fileManager.fileExists(atPath: primaryStoreURL.path) {
            do {
                var state = try decodeValidatedState(at: primaryStoreURL)
                if InitialSeed.applyIfNeeded(to: &state, now: now) {
                    try save(state)
                }
                return applyingCompatibleCounterCheckpoint(to: state)
            } catch {
                let primaryDescription = error.localizedDescription
                guard fileManager.fileExists(atPath: backupStoreURL.path) else {
                    throw PersistenceError.corruptPrimaryAndNoUsableBackup(primary: primaryDescription, backup: nil)
                }
                do {
                    var recovered = try decodeValidatedState(at: backupStoreURL)
                    if InitialSeed.applyIfNeeded(to: &recovered, now: now) {
                        try StateValidator.validate(recovered)
                    }
                    let restored = applyingCompatibleCounterCheckpoint(
                        to: recovered,
                        allowingCheckpointFromNewerRecoveredRevision: true
                    )
                    try writePrimaryWithoutRotatingBackup(restored)
                    return restored
                } catch let backupError {
                    throw PersistenceError.corruptPrimaryAndNoUsableBackup(
                        primary: primaryDescription,
                        backup: backupError.localizedDescription
                    )
                }
            }
        }

        if fileManager.fileExists(atPath: backupStoreURL.path) {
            do {
                var recovered = try decodeValidatedState(at: backupStoreURL)
                if InitialSeed.applyIfNeeded(to: &recovered, now: now) {
                    try StateValidator.validate(recovered)
                }
                let restored = applyingCompatibleCounterCheckpoint(
                    to: recovered,
                    allowingCheckpointFromNewerRecoveredRevision: true
                )
                try writePrimaryWithoutRotatingBackup(restored)
                return restored
            } catch {
                throw PersistenceError.corruptPrimaryAndNoUsableBackup(primary: "Primary file is missing", backup: error.localizedDescription)
            }
        }

        let initial = InitialSeed.makeInitialState(now: now)
        try save(initial)
        return applyingCompatibleCounterCheckpoint(to: initial)
    }

    /// Validates before writing, preserves the previous *valid* primary as the
    /// backup, and atomically replaces the primary file.
    public func save(_ state: PersistentAppState) throws {
        try StateValidator.validate(state)
        try ensureDirectoriesExist()
        let newData = try encoder.encode(state)

        if fileManager.fileExists(atPath: primaryStoreURL.path),
           let existingData = try? Data(contentsOf: primaryStoreURL),
           (try? decodeValidatedState(from: existingData)) != nil {
            try existingData.write(to: backupStoreURL, options: [.atomic])
        }
        try newData.write(to: primaryStoreURL, options: [.atomic])
    }

    /// Persists only the unfinished interval. The checkpoint is tied to the
    /// exact full-store revision it overlays, so a later submit/edit save makes
    /// an older checkpoint harmless without a delete race.
    public func saveCounterCheckpoint(
        counter: CounterState,
        activeSessionID: UUID,
        baseStoreRevision: UUID?,
        baseStoreLastModifiedAt: Date,
        now: Date = Date()
    ) throws {
        guard counter.currentCount >= 0,
              counter.selectedBaseMode == .walking || counter.selectedBaseMode == .running else {
            throw PersistenceError.invalidStore("Counter checkpoint contains invalid values")
        }
        try ensureDirectoriesExist()
        let checkpoint = CounterCheckpoint(
            baseStoreRevision: baseStoreRevision,
            baseStoreLastModifiedAt: baseStoreLastModifiedAt,
            activeSessionID: activeSessionID,
            counter: counter,
            persistedAt: now
        )
        let data = try encoder.encode(checkpoint)

        if let previous = try? decodeCounterCheckpoint(at: counterCheckpointURL),
           previous.baseStoreRevision == baseStoreRevision,
           storedDatesEqual(previous.baseStoreLastModifiedAt, baseStoreLastModifiedAt),
           previous.activeSessionID == activeSessionID,
           let existingData = try? Data(contentsOf: counterCheckpointURL) {
            try existingData.write(to: counterCheckpointBackupURL, options: [.atomic])
        }
        try data.write(to: counterCheckpointURL, options: [.atomic])
    }

    public func createPreImportBackup(of state: PersistentAppState, now: Date = Date()) throws -> URL {
        try StateValidator.validate(state)
        try ensureDirectoriesExist()
        let timestamp = filenameTimestamp(now)
        var candidate = directoryURL.appendingPathComponent("AdventureBar_PreImport_\(timestamp).json")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directoryURL.appendingPathComponent("AdventureBar_PreImport_\(timestamp)_\(suffix).json")
            suffix += 1
        }
        try encoder.encode(state).write(to: candidate, options: [.atomic])
        return candidate
    }

    public func decodeValidatedState(from data: Data) throws -> PersistentAppState {
        do {
            let state = try decoder.decode(PersistentAppState.self, from: data)
            try StateValidator.validate(state)
            return state
        } catch {
            throw PersistenceError.invalidStore(error.localizedDescription)
        }
    }

    private func decodeValidatedState(at url: URL) throws -> PersistentAppState {
        try decodeValidatedState(from: Data(contentsOf: url))
    }

    private func writePrimaryWithoutRotatingBackup(_ state: PersistentAppState) throws {
        try StateValidator.validate(state)
        try encoder.encode(state).write(to: primaryStoreURL, options: [.atomic])
    }

    private func applyingCompatibleCounterCheckpoint(
        to state: PersistentAppState,
        allowingCheckpointFromNewerRecoveredRevision: Bool = false
    ) -> PersistentAppState {
        // The atomic primary is always preferred by write order. Normally a
        // checkpoint must match the exact full-store revision. During explicit
        // full-store backup recovery only, a checkpoint tied to a different,
        // non-older revision may restore the unfinished interval if its active
        // session is still valid in the recovered store.
        for url in [counterCheckpointURL, counterCheckpointBackupURL] {
            guard let checkpoint = try? decodeCounterCheckpoint(at: url),
                  checkpoint.schemaVersion == CounterCheckpoint.currentSchemaVersion,
                  let checkpointSession = state.sessions.first(where: {
                      $0.id == checkpoint.activeSessionID && !$0.isArchived
                  }),
                  checkpoint.counter.currentCount >= 0,
                  checkpoint.counter.selectedBaseMode == .walking
                    || checkpoint.counter.selectedBaseMode == .running else {
                continue
            }

            let exactlyMatchesFullStore = checkpoint.baseStoreRevision == state.fullStoreRevision
                && checkpoint.baseStoreLastModifiedAt == state.lastModifiedAt
                && checkpoint.activeSessionID == state.activeSessionID
            let safelyRepresentsNewerCounterDuringBackupRecovery =
                allowingCheckpointFromNewerRecoveredRevision
                && checkpoint.baseStoreRevision != nil
                && state.fullStoreRevision != nil
                && checkpoint.baseStoreRevision != state.fullStoreRevision
                && checkpoint.baseStoreLastModifiedAt >= state.lastModifiedAt

            guard exactlyMatchesFullStore || safelyRepresentsNewerCounterDuringBackupRecovery else {
                continue
            }
            var restored = state
            restored.activeSessionID = checkpointSession.id
            restored.counter = checkpoint.counter
            return restored
        }
        return state
    }

    private func decodeCounterCheckpoint(at url: URL) throws -> CounterCheckpoint {
        try decoder.decode(CounterCheckpoint.self, from: Data(contentsOf: url))
    }

    private func storedDatesEqual(_ left: Date, _ right: Date) -> Bool {
        ISO8601Coding.string(from: left) == ISO8601Coding.string(from: right)
    }

    private func ensureDirectoriesExist() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: documentsDirectoryURL, withIntermediateDirectories: true)
    }

    private func filenameTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return formatter.string(from: date)
    }
}
