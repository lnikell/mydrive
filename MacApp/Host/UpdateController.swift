import Foundation
import Observation
import Sparkle

/// One host-only owner of Sparkle's updater and its persisted preferences.
/// Development and diagnostic launches never start network update checks.
@MainActor @Observable final class UpdateController {
    private(set) var isAvailable = false
    private(set) var canCheckForUpdates = false
    private(set) var allowsAutomaticUpdates = false
    private var automaticChecks = false
    private var automaticDownloads = false
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    var automaticallyChecksForUpdates: Bool {
        get { automaticChecks }
        set {
            guard let updater = controller?.updater else { return }
            updater.automaticallyChecksForUpdates = newValue
            automaticChecks = updater.automaticallyChecksForUpdates
            allowsAutomaticUpdates = updater.allowsAutomaticUpdates
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { automaticDownloads }
        set {
            guard let updater = controller?.updater, updater.allowsAutomaticUpdates else { return }
            updater.automaticallyDownloadsUpdates = newValue
            automaticDownloads = updater.automaticallyDownloadsUpdates
        }
    }

    init() {
        guard Self.canStart(info: Bundle.main.infoDictionary ?? [:], arguments: CommandLine.arguments) else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        isAvailable = true
        let updater = controller.updater
        automaticChecks = updater.automaticallyChecksForUpdates
        automaticDownloads = updater.automaticallyDownloadsUpdates
        allowsAutomaticUpdates = updater.allowsAutomaticUpdates
        canCheckForUpdates = updater.canCheckForUpdates
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { @Sendable [weak self] _, change in
                let available = change.newValue ?? false
                Task { @MainActor [weak self] in self?.canCheckForUpdates = available }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { @Sendable [weak self] _, change in
                let enabled = change.newValue ?? false
                Task { @MainActor [weak self] in self?.automaticChecks = enabled }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { @Sendable [weak self] _, change in
                let enabled = change.newValue ?? false
                Task { @MainActor [weak self] in self?.automaticDownloads = enabled }
            },
            updater.observe(\.allowsAutomaticUpdates, options: [.new]) { @Sendable [weak self] _, change in
                let allowed = change.newValue ?? false
                Task { @MainActor [weak self] in self?.allowsAutomaticUpdates = allowed }
            }
        ]
    }

    /// When Sparkle last checked for updates, if it has.
    var lastUpdateCheckDate: Date? { controller?.updater.lastUpdateCheckDate }

    static func canStart(info: [String: Any], arguments: [String]) -> Bool {
        guard info["MyDriveDevelopmentBuild"] as? Bool == false,
              !arguments.dropFirst().contains(where: { $0.hasPrefix("--probe-") }),
              let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return false }
        return true
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }
}
