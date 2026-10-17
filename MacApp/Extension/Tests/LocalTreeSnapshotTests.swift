import CryptoKit
import Darwin
import Foundation
import MyDriveCore

enum LocalTreeSnapshotTests {
    static func run() async throws -> Int {
        try await frozenReplay()
        try await boundedPages()
        try await unsupportedShapes()
        try await lateSourceChange()
        try await cancellation()
        return 5
    }

    private static func fixture() throws -> (URL, URL, MutationStaging) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Source.rtfd")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        return (root, source, try MutationStaging(root: root.appendingPathComponent("Mutations")))
    }

    private static func frozenReplay() async throws {
        let (root, source, staging) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = source.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let bytes = Data("all package bytes survive provider restart".utf8)
        try bytes.write(to: nested.appendingPathComponent("Unicode — café.rtf"))
        try Data().write(to: source.appendingPathComponent("Empty"))
        let first = try await LocalTreeSnapshot.capture(source, in: staging)
        let second = try await LocalTreeSnapshot.capture(source, in: staging)
        try mutationCheck(first.reference.sha256 == second.reference.sha256 && first.reference.id != second.reference.id &&
            first.reference.nodeCount == 4 && first.reference.totalBytes == Int64(bytes.count),
            "Logical tree digest depended on incidental staging UUID or missed directory/empty-file membership")
        try FileManager.default.removeItem(at: source)
        let replay = try LocalTreeSnapshot.load(first.reference, in: staging)
        let entries = try replay.entries(), files = entries.filter { $0.kind == .file }
        for entry in files {
            let payload = entry.payload!, local = try Data(contentsOf: replay.payloadURL(payload))
            try mutationCheck(Int64(local.count) == payload.size && MutationPeer.hash(local) == payload.sha256,
                              "Restarted tree snapshot lost private payload bytes")
        }
        try mutationCheck(try replay.sealedDirectories().last == "", "Directory intake did not seal descendants before root")
        print("PASS directory snapshot retains every byte and empty file across source deletion/restart with stable logical digest")
    }

    private static func boundedPages() async throws {
        let (root, source, staging) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<276 { try Data([UInt8(index % 256)]).write(to: source.appendingPathComponent(String(format: "File-%04d", index))) }
        let snapshot = try await LocalTreeSnapshot.capture(source, in: staging)
        var after: String?, count = 0, last: Data?
        while true {
            let page = try snapshot.entries(after: after, limit: 37)
            try mutationCheck(page.count <= 37, "Local snapshot returned an unbounded manifest page")
            for entry in page {
                let bytes = Data(entry.path.utf8)
                try mutationCheck(last == nil || last!.lexicographicallyPrecedes(bytes), "Local manifest keyset repeated or normalized a path")
                last = bytes; count += 1
            }
            guard let next = page.last else { break }
            after = next.path
        }
        try mutationCheck(count == 277 && snapshot.reference.nodeCount == 277, "Local manifest omitted a page or synthetic root")
        do { _ = try snapshot.entries(limit: 1001); throw MutationTestFailure(message: "Unbounded local page accepted") }
        catch is MutationTestFailure { throw MutationTestFailure(message: "Unbounded local page accepted") }
        catch {}
        print("PASS wide local tree uses bounded BINARY keyset pages without repeated or omitted input")
    }

    private static func unsupportedShapes() async throws {
        for shape in ["symlink", "hardlink", "fifo", "resource-fork"] {
            let (root, source, staging) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = source.appendingPathComponent("File")
            try Data("original".utf8).write(to: file)
            switch shape {
            case "symlink": try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("Link"), withDestinationURL: file)
            case "hardlink": try FileManager.default.linkItem(at: file, to: source.appendingPathComponent("Link"))
            case "fifo": guard mkfifo(source.appendingPathComponent("Pipe").path, 0o600) == 0 else { throw POSIXError(.EIO) }
            default:
                let bytes = Data("resource-fork".utf8)
                let result = bytes.withUnsafeBytes { setxattr(file.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0) }
                guard result == 0 else { throw POSIXError(.EIO) }
            }
            do {
                _ = try await LocalTreeSnapshot.capture(source, in: staging)
                throw MutationTestFailure(message: "Unsupported local tree shape was silently flattened: " + shape)
            } catch is MutationTestFailure { throw MutationTestFailure(message: "Unsupported shape accepted: " + shape) }
            catch {}
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: staging.root.path)
            try mutationCheck(leftovers.isEmpty && (try Data(contentsOf: file)) == Data("original".utf8),
                              "Rejected tree changed source bytes or left an executable partial snapshot")
        }
        print("PASS local tree rejects symlinks, hard links, FIFO and resource forks without flattening or partial executable input")
    }

    private static func cancellation() async throws {
        let (root, source, staging) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LocalTreeSnapshot.capture(source, in: staging)
        }
        do { _ = try await operation.value; throw MutationTestFailure(message: "Cancelled tree snapshot began capture") }
        catch is CancellationError {}
        try mutationCheck(try FileManager.default.contentsOfDirectory(atPath: staging.root.path).isEmpty,
                          "Cancelled snapshot left input masquerading as frozen data")
        print("PASS cancelled tree intake performs no staging or remote work")
    }

    private static func lateSourceChange() async throws {
        let (root, source, staging) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = source.appendingPathComponent("Earlier.txt")
        try Data("old".utf8).write(to: file)
        let later = Data("a later edit after the original clone was verified".utf8)
        do {
            _ = try await LocalTreeSnapshot.capture(source, in: staging) { path in
                if path == "Earlier.txt" { try later.write(to: file) }
            }
            throw MutationTestFailure(message: "Local tree accepted a file changed after its individual copy validation")
        } catch is MutationTestFailure { throw MutationTestFailure(message: "Late source modification accepted") }
        catch {}
        let retained = try Data(contentsOf: file), leftovers = try FileManager.default.contentsOfDirectory(atPath: staging.root.path)
        try mutationCheck(retained == later && leftovers.isEmpty,
                          "Rejected mixed-time source lost the newer source bytes or retained executable input")
        print("PASS final bounded source validation detects a regular file changed after its own clone/hash verification")
    }
}
