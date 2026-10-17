#if MYDRIVE_DEVELOPMENT
import Foundation

/// Opaque persistence is the test seam. The real adapter retains all of
/// CredentialStore's provider, development-build, and exact-endpoint gates.
protocol DevelopmentCredentialPersistence: Sendable {
    func load(for settings: ConnectionSettings) throws -> Data?
    func save(_ data: Data, for settings: ConnectionSettings) throws
    func remove(for settings: ConnectionSettings) throws
}

struct ProviderDevelopmentCredentialStore: DevelopmentCredentialPersistence {
    func load(for settings: ConnectionSettings) throws -> Data? {
        try CredentialStore.providerDevelopmentData(for: settings)
    }
    func save(_ data: Data, for settings: ConnectionSettings) throws {
        try CredentialStore.saveProviderDevelopmentData(data, for: settings)
    }
    func remove(for settings: ConnectionSettings) throws {
        try CredentialStore.removeProviderDevelopmentData(for: settings)
    }
}

struct DevelopmentCredentialScope: Codable, Equatable, Sendable {
    let buildID: String
    let domainID: String
    let host: String
    let share: String
    let username: String
}

struct DevelopmentCredentialRecord: Codable, Sendable {
    let version: Int
    let scope: DevelopmentCredentialScope
    let createdAt: Date
    let expiresAt: Date
    let password: String
}
#endif
