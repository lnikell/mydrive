import FileProvider
import Foundation
import MyDriveCore
import Darwin

extension MutationTests {
    static func unsupportedForkAndBoundedPlans() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try MutationStaging(root: root.appendingPathComponent("forks"))
        let forked = root.appendingPathComponent("forked")
        try Data("data".utf8).write(to: forked)
        let fork = Data("resource".utf8)
        let status = fork.withUnsafeBytes { setxattr(forked.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0) }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            _ = try await staging.stage(forked)
            throw MutationTestFailure(message: "Resource-fork contents were silently flattened")
        } catch let error as NSError {
            try mutationCheck(error.domain == NSFileProviderErrorDomain && error.code == NSFileProviderError.cannotSynchronize.rawValue,
                              "Unsupported resource fork lost its preserving error")
        }
        print("PASS resource-fork upload fails closed while retaining the system-owned source")
        let invalidPlan = UUID()
        let fifo = staging.root.appendingPathComponent(invalidPlan.uuidString.lowercased() + ".json")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let clock = ContinuousClock(); let beforeRead = clock.now
        do {
            _ = try staging.load(invalidPlan)
            throw MutationTestFailure(message: "A FIFO was accepted as a mutation recovery record")
        } catch let error as CocoaError {
            try mutationCheck(error.code == .fileReadCorruptFile, "Invalid plan shape lost its corruption error")
        }
        try mutationCheck(beforeRead.duration(to: clock.now) < .seconds(1), "A FIFO blocked the recovery record read")
        let tooLarge = UUID()
        try Data(repeating: 32, count: 131_073).write(to: staging.root.appendingPathComponent(tooLarge.uuidString.lowercased() + ".json"))
        do {
            _ = try staging.load(tooLarge)
            throw MutationTestFailure(message: "An oversized recovery record was accepted")
        } catch let error as CocoaError {
            try mutationCheck(error.code == .fileReadCorruptFile, "Oversized record lost its corruption error")
        }
        print("PASS recovery records reject FIFOs and oversize inputs before blocking or unbounded reads")
        return 2
    }

    static func unexpectedDirectoryContents() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("unexpected flattened package bytes".utf8)
        let source = root.appendingPathComponent("system-owned-package")
        try bytes.write(to: source)
        let peer = MutationPeer()
        let owner = try fixture(root.appendingPathComponent("provider"), peer)
        do {
            let input = try MutationInput(item: WriteTemplate(id: "package", name: "Document.rtfd", directory: true),
                fields: [.filename, .parentItemIdentifier, .contents], contents: source)
            _ = try await owner.write(input, create: true, progress: Progress(totalUnitCount: 1))
            throw MutationTestFailure(message: "Directory contents were acknowledged without transferring them")
        } catch let error as NSError {
            try mutationCheck(error.domain == NSFileProviderErrorDomain && error.code == NSFileProviderError.cannotSynchronize.rawValue,
                              "Unexpected directory contents did not retain a preserving native error")
        }
        try mutationCheck(await peer.counts().2 == 0 && (try Data(contentsOf: source)) == bytes,
                          "Rejected directory contents mutated the NAS or system-owned bytes")
        try mutationCheck(try await owner.catalog.children().items.isEmpty,
                          "Rejected directory contents published an empty-folder success")
        print("PASS unexpected directory/package contents fail closed before mutation without acknowledging or changing their bytes")
        return 1
    }

    static func wrongPurposeRecoveryPlan() async throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = MutationPeer(), owner = try fixture(root, peer)
        var plan = MutationPlan(key: UUID(), itemID: "item", parentID: Catalog.rootID,
                                filename: "File.txt", steps: [], preservedOriginal: nil)
        try owner.staging.save(plan)
        plan = try owner.staging.load(plan.key)!
        do {
            try await owner.performStep(0, plan: &plan, recovering: true, progress: nil)
            throw MutationTestFailure(message: "An empty recovery plan was executed as a mutation")
        } catch let error as CocoaError {
            try mutationCheck(error.code == .fileReadCorruptFile, "Wrong-purpose recovery plan lost its typed corruption error")
        }
        try mutationCheck(await peer.counts().2 == 0 && owner.staging.planKeys(limit: 8).count == 1,
                          "Wrong-purpose recovery state contacted the NAS or discarded evidence")
        print("PASS a decodable wrong-purpose recovery plan fails closed without trapping, remote work or lost evidence")
        return 1
    }

}
