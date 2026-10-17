import Foundation
import Security
import LocalAuthentication

enum CredentialStoreError: LocalizedError {
    case loginKeychainLocked

    var errorDescription: String? {
        "Unlock your login Keychain in macOS Keychain Access, then reconnect your NAS."
    }
}

enum CredentialStore {
    private static let service = "local.mydrive.NAS"
    private static let legacyLock = NSLock()

    private static func query(_ settings: ConnectionSettings) throws -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: settings.domainID]
        if let group = Bundle.main.object(forInfoDictionaryKey: "MyDriveKeychainAccessGroup") as? String {
            value[kSecAttrAccessGroup as String] = group
            value[kSecUseDataProtectionKeychain as String] = true
        } else if !AppStorage.isDevelopmentStorage {
            throw CocoaError(.featureUnsupported)
        }
        return value
    }

    static func save(_ password: String, for settings: ConnectionSettings, allowInteraction: Bool = true) throws {
        try withInteraction(allowInteraction) {
            try requireUnlockedLegacyKeychain(allowInteraction: allowInteraction)
            let base = try authenticationQuery(settings, allowInteraction: allowInteraction)
            let data = Data(password.utf8)
            var updates: [String: Any] = [kSecValueData as String: data]
            if base[kSecAttrAccessGroup as String] == nil {
                updates[kSecAttrAccess as String] = try developmentAccess()
            }
            let status = SecItemUpdate(base as CFDictionary, updates as CFDictionary)
            if status == errSecItemNotFound {
                var item = base
                item[kSecValueData as String] = data
                item[kSecAttrLabel as String] = "MyDrive — \(settings.displayName)"
                if item[kSecAttrAccessGroup as String] == nil {
                    item[kSecAttrAccess as String] = updates[kSecAttrAccess as String]
                }
                try check(SecItemAdd(item as CFDictionary, nil))
            } else { try check(status) }
        }
    }

    static func password(for settings: ConnectionSettings, allowInteraction: Bool = true) throws -> String {
        try withInteraction(allowInteraction) {
            try requireUnlockedLegacyKeychain(allowInteraction: allowInteraction)
            var request = try authenticationQuery(settings, allowInteraction: allowInteraction)
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &value)
            if status == errSecItemNotFound || status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                throw SMBClientError.authenticationRequired
            }
            try check(status)
            guard let data = value as? Data, let password = String(data: data, encoding: .utf8) else {
                throw SMBClientError.authenticationRequired
            }
            return password
        }
    }

    static func remove(for settings: ConnectionSettings) throws {
        try withInteraction(false) {
            let status = SecItemDelete(try authenticationQuery(settings, allowInteraction: false) as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
        }
    }

    #if MYDRIVE_DEVELOPMENT
    /// The provider creates this distinct item with normal creator-only access.
    /// Never add an ACL or migrate a host-created item into this namespace.
    static func saveProviderDevelopmentData(_ data: Data, for settings: ConnectionSettings) throws {
        let base = try providerDevelopmentQuery(settings)
        guard (1...32_768).contains(data.count) else { throw CocoaError(.fileWriteUnknown) }
        try withInteraction(false) {
            try requireUnlockedLegacyKeychain(allowInteraction: false)
            let updates = [kSecValueData as String: data]
            let status = SecItemUpdate(base as CFDictionary, updates as CFDictionary)
            if status == errSecItemNotFound {
                var item = base
                item[kSecValueData as String] = data
                try check(SecItemAdd(item as CFDictionary, nil))
            } else { try check(status) }
        }
    }

    static func providerDevelopmentData(for settings: ConnectionSettings) throws -> Data? {
        var request = try providerDevelopmentQuery(settings)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return try withInteraction(false) {
            try requireUnlockedLegacyKeychain(allowInteraction: false)
            var value: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &value)
            if status == errSecItemNotFound { return nil }
            try check(status)
            guard let data = value as? Data, (1...32_768).contains(data.count) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return data
        }
    }

    static func removeProviderDevelopmentData(for settings: ConnectionSettings) throws {
        let request = try providerDevelopmentQuery(settings)
        try withInteraction(false) {
            try requireUnlockedLegacyKeychain(allowInteraction: false)
            let status = SecItemDelete(request as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
        }
    }

    private static func providerDevelopmentQuery(_ settings: ConnectionSettings) throws -> [String: Any] {
        try DevelopmentConnectionScope.validate(settings)
        guard AppStorage.isDevelopmentStorage,
              Bundle.main.bundleURL.pathExtension == "appex",
              Bundle.main.bundleIdentifier == "local.mydrive.app.provider",
              Bundle.main.object(forInfoDictionaryKey: "MyDriveKeychainAccessGroup") == nil,
              let buildID = Bundle.main.object(forInfoDictionaryKey: "MyDriveDevelopmentCredentialBuildID") as? String,
              let uuid = UUID(uuidString: buildID), buildID.count == 36,
              uuid.uuidString.caseInsensitiveCompare(buildID) == .orderedSame else {
            throw CocoaError(.fileReadNoPermission)
        }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "local.mydrive.provider-development.NAS",
                kSecAttrAccount as String: settings.domainID + ":" + uuid.uuidString.lowercased()]
    }
    #endif

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func requireUnlockedLegacyKeychain(allowInteraction: Bool) throws {
        guard AppStorage.isDevelopmentStorage,
              Bundle.main.object(forInfoDictionaryKey: "MyDriveKeychainAccessGroup") == nil,
              !allowInteraction || Bundle.main.bundleURL.pathExtension == "appex" else { return }
        var status: SecKeychainStatus = 0
        try check(SecKeychainGetStatus(nil, &status))
        guard status & SecKeychainStatus(kSecUnlockStateStatus) != 0 else {
            throw CredentialStoreError.loginKeychainLocked
        }
    }

    private static func authenticationQuery(_ settings: ConnectionSettings, allowInteraction: Bool) throws -> [String: Any] {
        var request = try query(settings)
        if request[kSecAttrAccessGroup as String] != nil,
           !allowInteraction || Bundle.main.bundleURL.pathExtension == "appex" {
            let context = LAContext()
            context.interactionNotAllowed = true
            request[kSecUseAuthenticationContext as String] = context
        }
        return request
    }

    private static func withInteraction<Value>(_ allowInteraction: Bool, _ body: () throws -> Value) throws -> Value {
        guard AppStorage.isDevelopmentStorage,
              Bundle.main.object(forInfoDictionaryKey: "MyDriveKeychainAccessGroup") == nil else {
            return try body()
        }
        // Legacy Keychain ignores LAContext's no-prompt policy. This public
        // development-only flag affects this process, so serialize every call
        // and restore its previous value even when a Security operation fails.
        legacyLock.lock()
        defer { legacyLock.unlock() }
        let noPrompt = !allowInteraction || Bundle.main.bundleURL.pathExtension == "appex"
        guard noPrompt else { return try body() }
        var previous: DarwinBoolean = false
        try check(SecKeychainGetUserInteractionAllowed(&previous))
        try check(SecKeychainSetUserInteractionAllowed(false))
        defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try body()
    }

    /// Ad-hoc development only. Trust exactly the two locally built executables;
    /// production requires a provisioned shared data-protection access group.
    private static func developmentAccess() throws -> SecAccess {
        let bundle = Bundle.main.bundleURL
        let host = bundle.pathExtension == "appex"
            ? bundle.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            : bundle
        // Security requires application bundle URLs for bundled executables.
        let paths = [host.path, host.appendingPathComponent("Contents/PlugIns/MyDriveProvider.appex").path]
        var trusted: [SecTrustedApplication] = []
        for path in paths {
            var app: SecTrustedApplication?
            try check(SecTrustedApplicationCreateFromPath(path, &app))
            guard let app else { throw CocoaError(.fileReadNoPermission) }
            trusted.append(app)
        }
        var access: SecAccess?
        try check(SecAccessCreate("MyDrive development NAS credentials" as CFString, trusted as CFArray, &access))
        guard let access else { throw CocoaError(.fileReadNoPermission) }
        return access
    }
}
