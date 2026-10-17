import Foundation

private struct UpdateTestFailure: Error { let message: String }

/// Tests launch policy without instantiating a live configured updater.
@main struct UpdateControllerTests {
    @MainActor static func check(_ value: Bool, _ message: String) throws {
        if !value { throw UpdateTestFailure(message: message) }
    }

    @MainActor static func main() throws {
        let configured: [String: Any] = [
            "MyDriveDevelopmentBuild": false,
            "SUFeedURL": "https://github.com/example/mydrive/releases/latest/download/appcast.xml",
            "SUPublicEDKey": Data(0..<32).base64EncodedString()
        ]
        try check(UpdateController.canStart(info: configured, arguments: ["MyDrive"]),
                  "Valid production configuration disabled native updates")
        for mode in ["--probe-connection", "--probe-remove", "--probe-unknown"] {
            try check(!UpdateController.canStart(info: configured, arguments: ["MyDrive", mode]),
                      "Diagnostic launch started an automatic updater")
        }
        print("PASS diagnostic launches never start an otherwise configured updater")
        for (field, value) in [("MyDriveDevelopmentBuild", true as Any),
                               ("SUFeedURL", "http://example.invalid/appcast.xml" as Any),
                               ("SUFeedURL", "not-a-url" as Any),
                               ("SUPublicEDKey", "invalid" as Any),
                               ("SUPublicEDKey", Data(repeating: 0, count: 31).base64EncodedString() as Any)] {
            var invalid = configured
            invalid[field] = value
            try check(!UpdateController.canStart(info: invalid, arguments: ["MyDrive"]),
                      "Development or invalid update metadata was accepted")
        }
        for field in configured.keys {
            var missing = configured
            missing.removeValue(forKey: field)
            try check(!UpdateController.canStart(info: missing, arguments: ["MyDrive"]),
                      "Missing metadata started an updater")
        }
        print("PASS development, missing keys and insecure feeds fail closed")
        let controller = UpdateController()
        try check(!controller.isAvailable && !controller.canCheckForUpdates,
                  "Unconfigured test process started Sparkle")
        controller.automaticallyChecksForUpdates = true
        controller.automaticallyDownloadsUpdates = true
        controller.checkForUpdates()
        try check(!controller.automaticallyChecksForUpdates && !controller.automaticallyDownloadsUpdates && !controller.allowsAutomaticUpdates,
                  "Disabled updater fabricated a persisted preference")
        print("PASS unconfigured updater commands and preference changes remain inactive")
    }
}
