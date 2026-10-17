import Foundation

private struct DriveTestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor private final class DriveWait {
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    var count: Int { pending.count }
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { pending[id] = $0 }
        } onCancel: {
            Task { @MainActor in self.pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }
    func advance() {
        guard let id = pending.keys.first else { return }
        pending.removeValue(forKey: id)?.resume()
    }
}

@MainActor private final class FakeDrives: DriveConnectionBackend {
    let store: ConnectionStore
    var registered: Set<String> = []
    var failVerification: Set<String> = []
    var failActivation: Set<String> = []
    var failRemoval: Set<String> = []
    var holdVerification: Set<String> = []
    var verification: [ConnectionSettings] = []
    var activation: [ConnectionSettings] = []
    var actions: [(String, DriveAction)] = []
    var removals: [String] = []
    var registrationReads = 0
    var holdRegistration = false
    var removalEvidence: ConnectionRemoval?

    init(store: ConnectionStore) { self.store = store }
    func registeredDomainIDs() async throws -> Set<String> {
        registrationReads += 1
        if holdRegistration { try await Task.sleep(for: .seconds(60)) }
        return registered
    }
    func verify(_ settings: ConnectionSettings, password: String) async throws {
        verification.append(settings)
        if holdVerification.contains(settings.id) { try await Task.sleep(for: .seconds(60)) }
        if failVerification.contains(settings.id) { throw DriveTestFailure(message: "Verification refused") }
    }
    func activate(_ settings: ConnectionSettings, password: String) async throws {
        guard try store.settings(for: settings.id) == settings else {
            throw DriveTestFailure(message: "Registration preceded durable settings")
        }
        activation.append(settings)
        registered.insert(settings.id)
        if failActivation.contains(settings.id) { throw DriveTestFailure(message: "Provider refused activation") }
    }
    func perform(_ action: DriveAction, settings: ConnectionSettings) async throws -> String {
        actions.append((settings.id, action))
        return "Completed \(settings.id)"
    }
    func remove(_ settings: ConnectionSettings, store: ConnectionStore) async throws -> ConnectionRemoval {
        removals.append(settings.id)
        if failRemoval.contains(settings.id) { throw DriveTestFailure(message: "Removal refused") }
        registered.remove(settings.id)
        _ = try store.removeUnregisteredSettings(settings)
        return removalEvidence ?? ConnectionRemoval(preservedURL: nil, cleanupFailures: [])
    }
}

@main struct DriveModelTests {
    @MainActor static func check(_ value: Bool, _ message: String) throws {
        if !value { throw DriveTestFailure(message: message) }
    }
    @MainActor static func eventually(_ message: String, _ value: () -> Bool) async throws {
        for _ in 0..<10_000 { if value() { return }; await Task.yield() }
        throw DriveTestFailure(message: message)
    }
    static func connection(_ name: String) -> ConnectionSettings {
        ConnectionSettings(domainID: UUID().uuidString.lowercased(), displayName: name,
                           host: "nas.local:445", share: name, username: "account")
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConnectionStore(root: root), backend = FakeDrives(store: store)
        let a = connection("A"), b = connection("B"), pending = connection("Pending")
        try store.save(a); try store.save(b); try store.save(pending)
        backend.registered = [a.id, b.id, "unknown-domain"]
        var clocks: [DriveWait] = []
        let model = AppModel(store: .success(store), backend: backend, makeMonitor: {
            let clock = DriveWait(); clocks.append(clock); return ConnectionMonitor(wait: clock.sleep)
        }, launchArguments: [])
        await model.startup()
        try check(model.drives.count == 3 && model.loadIssues.count == 1, "Startup lost a saved/pending domain or unconfigured registration evidence")
        let driveA = model.drives.first { $0.id == a.id }!, driveB = model.drives.first { $0.id == b.id }!
        try check(driveA.isRegistered && driveB.isRegistered && model.drives.first { $0.id == pending.id }?.isRegistered == false,
                  "Startup did not reconcile each saved registration independently")
        try await eventually("Only registered drives should monitor") { clocks.map(\.count).reduce(0, +) == 2 }
        let draft1 = model.makeDraft(), draft2 = model.makeDraft()
        try check(draft1.id != draft2.id && ConnectionSettings.validDomainID(draft1.id), "Draft IDs were not fresh canonical UUIDs")
        print("PASS startup reconciles saved, pending and unknown Finder domains with separate monitors")

        backend.holdVerification.insert(a.id)
        let connecting = Task { await driveA.reconnect(password: "synthetic") }
        try await eventually("A reconnect did not suspend independently") { driveA.busy && backend.verification.contains(a) }
        await driveB.refresh()
        try check(!driveB.busy && backend.actions.contains { $0.0 == b.id }, "A reconnect blocked or retargeted B")
        connecting.cancel()
        try check(await connecting.value == false, "Cancelled reconnect succeeded")
        try await eventually("Cancelled reconnect did not restore A's monitor") { clocks.map(\.count).reduce(0, +) == 2 }
        try check(try store.settings(for: a.id) == a && store.settings(for: b.id) == b, "Cancelled A changed persisted endpoints")
        backend.holdVerification.remove(a.id)
        print("PASS per-drive busy/cancellation preserves immutable endpoint and permits other-drive work")

        let failed = connection("Retry")
        backend.failActivation.insert(failed.id)
        try check(await model.add(failed, password: "synthetic") == false, "Failed activation reported success")
        try check(model.drives.filter { $0.id == failed.id }.count == 1 && backend.registered.contains(failed.id),
                  "Accepted but failed registration was abandoned")
        let sameModel = model.drives.first { $0.id == failed.id }!
        backend.failActivation.remove(failed.id)
        try check(await model.add(failed, password: "synthetic") && model.drives.first { $0.id == failed.id } === sameModel,
                  "Same-sheet retry duplicated or rejected its recoverable drive")
        var reassigned = failed; reassigned.share = "different"
        try check(await model.add(reassigned, password: "synthetic") == false, "Retry retargeted a saved domain")
        let unverified = connection("Bad")
        backend.failVerification.insert(unverified.id)
        try check(await model.add(unverified, password: "synthetic") == false, "Verification failure succeeded")
        try check(try store.existingSettings(for: unverified.id) == nil && !model.drives.contains { $0.id == unverified.id },
                  "Unverified connection wrote a record")
        print("PASS failed activation retains one recoverable ID; verification failure creates nothing")

        backend.failRemoval.insert(a.id)
        try check(await model.remove(driveA) == false && model.drives.contains { $0 === driveA }, "Failed removal discarded A")
        try await eventually("Failed removal did not resume its own monitoring") { clocks.map(\.count).reduce(0, +) == 3 }
        let bRecord = try Data(contentsOf: store.folder(for: b.id).appendingPathComponent("connection.json"))
        backend.failRemoval.remove(a.id)
        backend.removalEvidence = ConnectionRemoval(preservedURL: root.appendingPathComponent("Recovered work"),
                                                     cleanupFailures: [String(repeating: "detail ", count: 120)])
        try check(await model.remove(driveA) && !model.drives.contains { $0.id == a.id }, "Successful removal retained A row")
        try check(model.status.contains("Recovered work") && model.status.count > 512, "Removal truncated preserved-work or cleanup evidence")
        try check(try Data(contentsOf: store.folder(for: b.id).appendingPathComponent("connection.json")) == bRecord && driveB.isRegistered,
                  "Removing A changed B's settings or registration")
        await model.shutdown()
        try await eventually("Shutdown left a monitor owned") { clocks.allSatisfy { $0.count == 0 } }
        print("PASS failed removal resumes only its monitor; successful removal preserves evidence and other drives")

        let diagnosticBackend = FakeDrives(store: store)
        let diagnostic = AppModel(store: .success(store), backend: diagnosticBackend,
                                  launchArguments: ["--probe-remove"])
        await diagnostic.startup()
        try check(diagnostic.drives.isEmpty && diagnosticBackend.registrationReads == 0 && diagnostic.busy,
                  "Diagnostic launch started normal domain loading/monitoring")
        try check(await diagnostic.add(connection("Blocked"), password: "synthetic") == false,
                  "Diagnostic launch permitted concurrent UI registration")
        print("PASS diagnostic launch bypasses UI backend and monitors")

        let retryBackend = FakeDrives(store: store)
        retryBackend.registered = [b.id]
        retryBackend.holdRegistration = true
        let retryModel = AppModel(store: .success(store), backend: retryBackend, launchArguments: [])
        let loading = Task { await retryModel.startup() }
        try await eventually("Startup did not await registration") { retryBackend.registrationReads == 1 }
        loading.cancel(); await loading.value
        try check(retryModel.drives.isEmpty, "Cancelled startup mislabeled saved drives as unregistered")
        retryBackend.holdRegistration = false
        await retryModel.startup()
        try check(retryBackend.registrationReads == 2 && retryModel.drives.first { $0.id == b.id }?.isRegistered == true,
                  "Cancelled startup could not retry")
        await retryModel.shutdown()
        print("PASS cancelled startup retries registration instead of caching a false disconnected state")

        #if MYDRIVE_DEVELOPMENT
        try await developmentRegistration()
        #endif
    }

    #if MYDRIVE_DEVELOPMENT
    @MainActor private static func developmentRegistration() async throws {
        var effects: [String] = []
        var registered = false
        var hidden = false
        var failInstall = false, failRefresh = false, failReveal = false
        var cancelAfterHidden: (() -> Void)?
        func activate() async throws {
            try await SystemDriveConnectionBackend.activateDevelopment(
                isRegistered: { effects.append("lookup"); return registered },
                register: { value in
                    effects.append(value ? "hidden" : "visible")
                    if !value && failReveal { throw DriveTestFailure(message: "Reveal refused") }
                    registered = true; hidden = value
                    if value { cancelAfterHidden?() }
                },
                installCredential: {
                    effects.append("credential")
                    if failInstall { throw DriveTestFailure(message: "Credential refused") }
                },
                connectionRestored: {
                    effects.append("refresh")
                    if failRefresh { throw DriveTestFailure(message: "Refresh refused") }
                })
        }
        try await activate()
        try check(effects == ["lookup", "hidden", "credential", "refresh", "visible"] && registered && !hidden,
                  "New development domain became visible before verified provider access")
        print("PASS development registration hides a new domain until credentials and provider refresh succeed")

        for phase in ["credential", "refresh", "visible"] {
            effects = []; registered = false; hidden = false
            failInstall = phase == "credential"; failRefresh = phase == "refresh"; failReveal = phase == "visible"
            do { try await activate(); throw DriveTestFailure(message: "Failed activation reported success") }
            catch let error as DriveTestFailure where error.message.hasSuffix("refused") { }
            let expected = phase == "credential" ? ["lookup", "hidden", "credential"] :
                phase == "refresh" ? ["lookup", "hidden", "credential", "refresh"] :
                ["lookup", "hidden", "credential", "refresh", "visible"]
            try check(effects == expected && registered && hidden, "Failed activation exposed or abandoned its hidden registration")
            effects = []; failInstall = false; failRefresh = false; failReveal = false
            try await activate()
            try check(effects == ["lookup", "credential", "refresh", "visible"] && !hidden,
                      "Retry failed to reveal the same prior hidden domain without re-registering it hidden")
        }
        print("PASS credential, refresh and reveal failures preserve a hidden registration that same-ID retry can finish")

        effects = []
        try await activate()
        try check(effects == ["lookup", "credential", "refresh", "visible"] && !hidden,
                  "Reconnect hid an already registered development domain")
        effects = []; registered = false; hidden = false
        let cancelled = Task { @MainActor in
            cancelAfterHidden = { withUnsafeCurrentTask { $0?.cancel() } }
            try await activate()
        }
        do { try await cancelled.value; throw DriveTestFailure(message: "Cancelled activation succeeded") }
        catch is CancellationError { }
        cancelAfterHidden = nil
        try check(effects == ["lookup", "hidden"] && registered && hidden,
                  "Cancellation after hidden registration installed credentials or revealed the domain")
        effects = []
        try await activate()
        try check(effects == ["lookup", "credential", "refresh", "visible"] && !hidden,
                  "A fresh retry could not finish a cancelled hidden registration")
        print("PASS reconnect never hides an existing drive; cancellation stops before credentials and supports fresh retry")
    }
    #endif
}
