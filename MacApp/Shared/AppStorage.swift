import Foundation

struct ConnectionSettings: Codable, Equatable, Identifiable, Sendable {
    let domainID: String
    var displayName: String
    var host: String
    var share: String
    var username: String

    var id: String { domainID }

    static func validDomainID(_ value: String) -> Bool {
        value == "unas-test" || UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    func hasSameEndpoint(as other: ConnectionSettings) -> Bool {
        host == other.host && share == other.share && username == other.username
    }
}

enum AppStorage {
    static var hasSharedConfiguration: Bool {
        Bundle.main.object(forInfoDictionaryKey: "MyDriveAppGroupID") != nil ||
            Bundle.main.object(forInfoDictionaryKey: "MyDriveDevelopmentStoragePath") != nil
    }

    static var groupID: String {
        Bundle.main.object(forInfoDictionaryKey: "MyDriveAppGroupID") as? String ?? "group.local.mydrive"
    }

    static var isDevelopmentStorage: Bool {
        Bundle.main.object(forInfoDictionaryKey: "MyDriveDevelopmentBuild") as? Bool == true
    }

    static func rootURL() throws -> URL {
        if let path = Bundle.main.object(forInfoDictionaryKey: "MyDriveDevelopmentStoragePath") as? String {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw CocoaError(.fileReadNoPermission)
        }
        return url
    }

    static func folder(for domainID: String, create: Bool = true) throws -> URL {
        try connectionStore().folder(for: domainID, create: create)
    }

    static func settings(for domainID: String) throws -> ConnectionSettings {
        try connectionStore().settings(for: domainID)
    }

    static func existingSettings(for domainID: String) throws -> ConnectionSettings? {
        try connectionStore().existingSettings(for: domainID)
    }

    static func save(_ settings: ConnectionSettings) throws {
        try connectionStore().save(settings)
    }

    static func connectionStore() throws -> ConnectionStore { ConnectionStore(root: try rootURL()) }

    static func catalogURL(for domainID: String) throws -> URL {
        try folder(for: domainID).appendingPathComponent("catalog.sqlite")
    }

    static func transportURL() throws -> URL {
        // Each sandboxed executable carries its own inherited-sandbox helper.
        // An extension must not depend on traversal outside its bundle.
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/nas-transport")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw CocoaError(.executableNotLoadable) }
        return url
    }
}
