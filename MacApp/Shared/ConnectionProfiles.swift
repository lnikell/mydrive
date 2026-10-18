import Darwin
import Foundation

/// Portable endpoint descriptions deliberately omit both credentials and local
/// Domain IDs. Importing cannot steal another connection's Catalog or Keychain.
struct ConnectionProfile: Codable, Equatable, Sendable {
    var name: String
    var host: String
    var share: String
    var username: String
    var options: MountOptions?

    init(_ settings: ConnectionSettings, options: MountOptions? = nil) {
        name = settings.displayName; host = settings.host; share = settings.share; username = settings.username
        self.options = options
        self.options?.pauseReason = nil
    }

    func settings() throws -> ConnectionSettings {
        let address = try SMBAddress(server: host, share: share)
        let settings = ConnectionSettings(domainID: UUID().uuidString.lowercased(), displayName: name,
                                          host: address.endpoint, share: address.share, username: username)
        try ConnectionStore.validate(settings)
        return settings
    }
}

struct ConnectionProfiles: Codable, Sendable {
    let version: Int
    let profiles: [ConnectionProfile]

    init(settings: [ConnectionSettings], options: [String: MountOptions] = [:]) {
        version = 1
        profiles = settings.map { ConnectionProfile($0, options: options[$0.id]) }
    }

    static func decode(_ bytes: Data) throws -> [ConnectionSettings] {
        try read(bytes).map(\.settings)
    }

    struct Imported: Sendable {
        let settings: ConnectionSettings
        var options: MountOptions?
    }

    static func read(_ bytes: Data) throws -> [Imported] {
        guard bytes.count <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
        let document = try JSONDecoder().decode(Self.self, from: bytes)
        guard document.version == 1, document.profiles.count <= 1000 else { throw CocoaError(.fileReadCorruptFile) }
        return try document.profiles.map { profile in
            var options = try profile.options?.validated()
            options?.pauseReason = nil
            return Imported(settings: try profile.settings(), options: options)
        }
    }

    static func mountainDuck(_ bytes: Data) throws -> ConnectionSettings {
        guard bytes.count <= 1_048_576,
              let bookmark = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let protocolName = bookmark["Protocol"] as? String,
              protocolName.lowercased() == "smb",
              let host = bookmark["Hostname"] as? String,
              let username = bookmark["Username"] as? String,
              let path = bookmark["Path"] as? String else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Choose an SMB Mountain Duck bookmark (.duck)."])
        }
        let share = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var server = host
        if let port = bookmark["Port"] as? Int { server += ":\(port)" }
        let profile = ConnectionProfile(ConnectionSettings(domainID: "", displayName: bookmark["Nickname"] as? String ?? share,
                                                            host: server, share: share, username: username))
        return try profile.settings()
    }
}

extension ConnectionStore {
    /// Publish a new profile and its options together. A failed option write
    /// cannot leave a saved mount missing from the model until the next launch.
    func importProfile(_ profile: ConnectionProfiles.Imported) throws {
        try Self.validate(profile.settings)
        var options = try profile.options?.validated()
        options?.pauseReason = nil
        let bytes = try JSONEncoder().encode(profile.settings)
        guard bytes.count <= 65_536 else { throw ConnectionStoreError.invalidSettings }
        let destination = try folder(for: profile.settings.id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let temporary = root.appendingPathComponent(UUID().uuidString + ".import", isDirectory: true)
        guard mkdir(temporary.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try bytes.write(to: temporary.appendingPathComponent("connection.json"), options: .atomic)
        try options?.save(in: temporary)
        guard renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
