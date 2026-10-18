import Foundation

extension AppStorage {
    static func preferences(for id: String) throws -> UserPreferences {
        guard hasSharedConfiguration else { return UserPreferences() }
        return try PreferencesStore.shared().effective(for: id)
    }
}

/// Shared, nonsecret policy. Providers read a fresh snapshot for each operation;
/// the host remains a command source rather than another sync owner.
struct UserPreferences: Codable, Equatable, Sendable {
    var showMenuBar = true
    var showDock = true
    var showFinder = true
    var openAfterMount = false
    var reconnectOnChange = false
    var notifyConflicts = false
    var notifyConnections = false
    var notifyTransfers = false
    var keepNewMounts = false
    var maximumCacheGB = 20.0
    var freeOnLowDisk = false
    var cacheAgeDays = 0
    var excludedPatterns: [String] = []
    var downloadLimited = false
    var downloadMBps = 10.0
    var uploadLimited = false
    var uploadMBps = 10.0
    var limitSchedule = "Always"
    var pauseOnConstrained = false
    var pauseOnLowBattery = false
    var simultaneousTransfers = 4
    var retrySeconds = 30
    var discoverTailnet = false
    var verboseLogging = false

    func validated() throws -> Self {
        guard maximumCacheGB.isFinite, (5...100).contains(maximumCacheGB),
              downloadMBps.isFinite, (0.1...10000).contains(downloadMBps),
              uploadMBps.isFinite, (0.1...10000).contains(uploadMBps),
              ["Always", "Work hours (9–18)", "Outside work hours"].contains(limitSchedule),
              [0, 1, 7, 30, 90].contains(cacheAgeDays), (1...8).contains(simultaneousTransfers),
              [15, 30, 60, 300].contains(retrySeconds), excludedPatterns.count <= 100,
              excludedPatterns.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return self
    }

    func limitsApply(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        switch limitSchedule {
        case "Work hours (9–18)": return (9..<18).contains(hour)
        case "Outside work hours": return !(9..<18).contains(hour)
        default: return true
        }
    }

    func excludes(_ path: String) -> Bool {
        ExclusionMatcher(patterns: excludedPatterns).excludes(path)
    }
}

struct PreferencesStore: Sendable {
    let url: URL
    static func shared() throws -> Self { Self(url: try AppStorage.rootURL().appendingPathComponent("preferences.json")) }

    func load() throws -> UserPreferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return UserPreferences() }
        let bytes = try BoundedFile.read(url, maximumBytes: 65_536)
        guard bytes.count <= 65_536,
              let stored = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              var defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(UserPreferences())) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defaults.merge(stored) { _, saved in saved }
        return try JSONDecoder().decode(UserPreferences.self, from: JSONSerialization.data(withJSONObject: defaults)).validated()
    }

    func save(_ preferences: UserPreferences) throws {
        let bytes = try JSONEncoder().encode(preferences.validated())
        guard bytes.count <= 65_536 else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
