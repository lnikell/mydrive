#if MYDRIVE_DEVELOPMENT
import Foundation

/// Domain IDs partition records; they are not endpoint authorization. The
/// development seam permits only the explicitly authorized NAS/share/account.
enum DevelopmentConnectionScope {
    private static let example = ["host": "192.0.2.1:445", "share": "mydrive-test", "username": "mydrive-test"]

    static func validate(_ settings: ConnectionSettings, info: [String: Any] = Bundle.main.infoDictionary ?? [:]) throws {
        let expected = try self.settings(domainID: settings.domainID, info: info)
        guard settings.host.utf8.elementsEqual(expected.host.utf8),
              settings.share.utf8.elementsEqual(expected.share.utf8),
              settings.username.utf8.elementsEqual(expected.username.utf8) else { throw CocoaError(.fileReadNoPermission) }
    }

    static func settings(domainID: String, name: String = "Test NAS",
                         info: [String: Any] = Bundle.main.infoDictionary ?? [:]) throws -> ConnectionSettings {
        guard ConnectionSettings.validDomainID(domainID) else { throw CocoaError(.fileReadNoPermission) }
        let target: [String: String]
        if let raw = info["MyDriveDevelopmentConnection"] {
            guard let configured = raw as? [String: String] else { throw CocoaError(.fileReadNoPermission) }
            target = configured
        } else {
            // Standalone adapter executables have no bundle metadata. A real
            // development bundle must carry the build-validated local target.
            guard info["MyDriveDevelopmentBuild"] as? Bool != true else { throw CocoaError(.fileReadNoPermission) }
            target = example
        }
        guard Set(target.keys) == Set(example.keys), target.values.allSatisfy({ value in
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 1024 &&
                value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
        }), let host = target["host"], let share = target["share"], let username = target["username"] else {
            throw CocoaError(.fileReadNoPermission)
        }
        return ConnectionSettings(domainID: domainID, displayName: name, host: host, share: share, username: username)
    }
}
#endif
