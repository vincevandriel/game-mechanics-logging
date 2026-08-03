import Foundation

public enum MovementMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case walking
    case running
    case mixedUncertain = "mixed_uncertain"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .walking: return "Walking"
        case .running: return "Running"
        case .mixedUncertain: return "Mixed/Uncertain"
        }
    }

    public init?(importValue: String) {
        let normalized = importValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "walking", "walk": self = .walking
        case "running", "run": self = .running
        case "mixed", "mixed/uncertain", "mixed_uncertain", "uncertain": self = .mixedUncertain
        default: return nil
        }
    }
}

public enum AppAppearance: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

public enum ExportFormat: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case csv
    case json

    public var id: String { rawValue }
    public var displayName: String { rawValue.uppercased() }
    public var fileExtension: String { rawValue }
    public var contentType: String { self == .csv ? "text/csv" : "application/json" }
}

public enum ExportContent: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case observationsOnly
    case observationsAndSessionMetadata
    case completeBackup

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .observationsOnly: return "Only Observations"
        case .observationsAndSessionMetadata: return "Observations + Session Metadata"
        case .completeBackup: return "Complete Backup"
        }
    }
}

public enum ModeChangeResolution: Equatable, Sendable {
    case resetAndSwitch
    case preserveAndMarkMixed
}

public enum SessionSwitchResolution: Equatable, Sendable {
    case resetCurrentCount
    case preserveCurrentCount
}

public enum UndoStrategy: Equatable, Sendable {
    case replace
    case addCurrentCount
}

public enum ImportMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case merge
    case replace

    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}
