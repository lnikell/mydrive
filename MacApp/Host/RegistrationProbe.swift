import AppKit

/// Development diagnostics execute through backend APIs inside the signed host.
@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.contains(where: { $0.hasPrefix("--probe-") }) else { return }
        guard AppStorage.isDevelopmentStorage else {
            FileHandle.standardError.write(Data("Development diagnostics are unavailable.\n".utf8))
            NSApplication.shared.terminate(nil)
            return
        }
        Task {
            await HostDiagnostic.run(arguments)
            NSApplication.shared.terminate(nil)
        }
    }
}
