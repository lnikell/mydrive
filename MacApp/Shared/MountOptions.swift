import Foundation

struct MountOptions: Codable, Equatable, Sendable {
    enum PauseReason: String, Codable, Sendable { case user, automatic }
    var pauseReason: PauseReason?
    var overrideBandwidth = false
    var downloadLimited = false
    var downloadMBps = 10.0
    var uploadLimited = false
    var uploadMBps = 10.0
    var excludedPatterns: [String] = []

    static func load(for id: String) throws -> Self {
        try load(in: AppStorage.folder(for: id, create: false))
    }

    static func load(in folder: URL) throws -> Self {
        let url = folder.appendingPathComponent("mount-options.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: BoundedFile.read(url, maximumBytes: 65_536)).validated()
    }

    func save(for id: String) throws {
        try save(in: AppStorage.folder(for: id))
    }

    func save(in folder: URL) throws {
        let bytes = try JSONEncoder().encode(validated())
        guard bytes.count <= 65_536 else { throw CocoaError(.fileWriteOutOfSpace) }
        try bytes.write(to: folder.appendingPathComponent("mount-options.json"), options: .atomic)
    }

    func validated() throws -> Self {
        var preferences = UserPreferences()
        preferences.downloadMBps = downloadMBps; preferences.uploadMBps = uploadMBps
        preferences.excludedPatterns = excludedPatterns
        _ = try preferences.validated()
        return self
    }
}

extension PreferencesStore {
    func effective(for id: String) throws -> UserPreferences {
        var preferences = try load()
        let options = try MountOptions.load(for: id)
        if options.overrideBandwidth {
            preferences.downloadLimited = options.downloadLimited; preferences.downloadMBps = options.downloadMBps
            preferences.uploadLimited = options.uploadLimited; preferences.uploadMBps = options.uploadMBps
        }
        preferences.excludedPatterns += options.excludedPatterns
        return preferences
    }
}
