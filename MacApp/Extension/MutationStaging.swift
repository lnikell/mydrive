import CryptoKit
import Darwin
import Foundation
import MyDriveCore

/// Durable payloads and nonsecret transport receipts owned by one domain.
/// SQLite references UUIDs; no arbitrary filesystem path comes from the journal.
struct MutationStaging: Sendable {
    let root: URL

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var url = root; try url.setResourceValues(values)
    }

    func payloadURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString.lowercased() + ".payload") }
    private func planURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString.lowercased() + ".json") }

    func stage(_ source: URL) async throws -> StagedPayload {
        try Task.checkCancellation()
        guard source.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let sourceFD = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard sourceFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let original = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
        defer { try? original.close() }
        var info = stat()
        guard fstat(sourceFD, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw MutationInput.unsupported("Only regular file contents can be uploaded.")
        }
        try rejectResourceFork(sourceFD)
        let id = UUID()
        let url = payloadURL(id)
        do {
            // APFS clones avoid a second full data copy. Across filesystems,
            // copy through the already-open regular file with cancellation.
            if fclonefileat(sourceFD, AT_FDCWD, url.path, UInt32(CLONE_NOFOLLOW)) != 0 {
                let destinationFD = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard destinationFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let destination = FileHandle(fileDescriptor: destinationFD, closeOnDealloc: true)
                defer { try? destination.close() }
                _ = try Self.readChunks(original) { try destination.write(contentsOf: $0) }
                try destination.synchronize()
            }
            let stagedFD = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard stagedFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let file = FileHandle(fileDescriptor: stagedFD, closeOnDealloc: true)
            defer { try? file.close() }
            try rejectResourceFork(stagedFD)
            var digest = SHA256()
            let count = try Self.readChunks(file) { digest.update(data: $0) }
            let writer = try FileHandle(forWritingTo: url)
            try writer.synchronize(); try writer.close()
            try synchronizeDirectory()
            return StagedPayload(id: id, size: count,
                                 sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Read and consume inside the same pool: Foundation's temporary backing
    /// objects must drain before the next chunk. These consumers never retain
    /// data or suspend; FileHandle ownership and durability stay with stage.
    static func readChunks(_ file: FileHandle, consume: (Data) throws -> Void) throws -> Int64 {
        var count: Int64 = 0
        while try autoreleasepool(invoking: {
            try Task.checkCancellation()
            guard let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty else { return false }
            try Task.checkCancellation()
            let (next, overflow) = count.addingReportingOverflow(Int64(bytes.count))
            guard !overflow else { throw CocoaError(.fileReadTooLarge) }
            try consume(bytes)
            count = next
            return true
        }) { }
        return count
    }

    func discard(_ payload: StagedPayload?) {
        if let payload { try? FileManager.default.removeItem(at: payloadURL(payload.id)) }
    }

    func load(_ id: UUID) throws -> MutationPlan? {
        let url = planURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 131_072 else { throw CocoaError(.fileReadCorruptFile) }
        let data = try file.read(upToCount: 131_073) ?? Data()
        guard data.count <= 131_072 else { throw CocoaError(.fileReadCorruptFile) }
        let plan = try JSONDecoder().decode(MutationPlan.self, from: data)
        guard plan.key == id else { throw CocoaError(.fileReadCorruptFile) }
        return plan
    }

    func save(_ plan: MutationPlan) throws {
        let data = try JSONEncoder().encode(plan)
        guard data.count <= 131_072 else { throw MutationInput.unsupported("This operation is too large to record safely. Its local contents are preserved.") }
        let temporary = root.appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let file = try FileHandle(forWritingTo: temporary)
        try file.write(contentsOf: data); try file.synchronize(); try file.close()
        guard rename(temporary.path, planURL(plan.key).path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try synchronizeDirectory()
    }

    func removePlan(_ id: UUID) throws {
        try FileManager.default.removeItem(at: planURL(id))
        try synchronizeDirectory()
    }

    /// A bounded local directory read; no remote work or whole-share crawl.
    func planKeys(limit: Int, after: UUID? = nil) -> [UUID] {
        guard limit > 0, let entries = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]) else { return [] }
        var keys: [UUID] = []
        while let url = entries.nextObject() as? URL {
            if url.pathExtension == "json", let key = UUID(uuidString: url.deletingPathExtension().lastPathComponent) {
                if after == nil || key.uuidString > after!.uuidString {
                    keys.append(key)
                    keys.sort { $0.uuidString < $1.uuidString }
                    if keys.count > min(limit, 128) { keys.removeLast() }
                }
            }
        }
        return keys
    }

    private func rejectResourceFork(_ fd: Int32) throws {
        let count = fgetxattr(fd, "com.apple.ResourceFork", nil, 0, 0, 0)
        if count > 0 { throw MutationInput.unsupported("This file has a resource fork that MyDrive cannot upload yet.") }
        if count < 0 && errno != ENOATTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func synchronizeDirectory() throws {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

struct MutationPlan: Codable, Sendable {
    struct Step: Codable, Sendable {
        var request: SMBMutationRequest
        var result: SMBMutationResult?
    }
    let key: UUID
    let itemID: String
    var parentID: String
    var filename: String
    var steps: [Step]
    var preservedOriginal: CatalogMutationItem?
    var sourceParentID: String? = nil
    var retainedRequests: [SMBMutationRequest] = []
    var cleanedArtifacts: Set<String> = []
    var unresolvedAllocationPaths: [String] = []
    var localRecovery: MutationLocalRecovery? = nil
    var readOnlyDeletionAbsence = false
    var treeImport: TreeImportLocalState? = nil

    private enum CodingKeys: String, CodingKey {
        case key, itemID, parentID, filename, steps, preservedOriginal, sourceParentID
        case retainedRequests, cleanedArtifacts, unresolvedAllocationPaths, localRecovery, readOnlyDeletionAbsence, treeImport
    }
}

extension MutationPlan {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(UUID.self, forKey: .key)
        itemID = try values.decode(String.self, forKey: .itemID)
        parentID = try values.decode(String.self, forKey: .parentID)
        filename = try values.decode(String.self, forKey: .filename)
        steps = try values.decode([Step].self, forKey: .steps)
        preservedOriginal = try values.decodeIfPresent(CatalogMutationItem.self, forKey: .preservedOriginal)
        sourceParentID = try values.decodeIfPresent(String.self, forKey: .sourceParentID)
        retainedRequests = try values.decodeIfPresent([SMBMutationRequest].self, forKey: .retainedRequests) ?? []
        cleanedArtifacts = try values.decodeIfPresent(Set<String>.self, forKey: .cleanedArtifacts) ?? []
        unresolvedAllocationPaths = try values.decodeIfPresent([String].self, forKey: .unresolvedAllocationPaths) ?? []
        localRecovery = try values.decodeIfPresent(MutationLocalRecovery.self, forKey: .localRecovery)
        readOnlyDeletionAbsence = try values.decodeIfPresent(Bool.self, forKey: .readOnlyDeletionAbsence) ?? false
        treeImport = try values.decodeIfPresent(TreeImportLocalState.self, forKey: .treeImport)
    }
}

/// Bounded local input/recovery reference. Per-node transport receipts remain
/// individual ordinary plans; this never embeds the manifest in JSON.
struct TreeImportLocalState: Codable, Sendable {
    let tree: StagedTreeReference
    let layoutVersion: Int
    let saveContract: MutationSaveContract?
    var localRetirementStarted = false
    init(tree: StagedTreeReference, saveContract: MutationSaveContract? = nil) {
        self.tree = tree; layoutVersion = 2; self.saveContract = saveContract
    }
    private enum CodingKeys: String, CodingKey { case tree, layoutVersion, localRetirementStarted, saveContract }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tree = try values.decode(StagedTreeReference.self, forKey: .tree)
        layoutVersion = try values.decode(Int.self, forKey: .layoutVersion)
        saveContract = try values.decodeIfPresent(MutationSaveContract.self, forKey: .saveContract)
        localRetirementStarted = try values.decodeIfPresent(Bool.self, forKey: .localRetirementStarted) ?? false
        guard layoutVersion == 2 else { throw DecodingError.dataCorruptedError(forKey: .layoutVersion, in: values,
            debugDescription: "Unsupported private tree input layout") }
    }
}

/// A dirty callback may arrive after its Catalog identity was retired. Retain
/// the requested edit and cloned bytes even when Core cannot yet accept a live
/// item mutation. This is recovery evidence, never an upload-completion receipt.
struct MutationLocalRecovery: Codable, Sendable {
    let payload: StagedPayload
    let requestedParentID: String
    let requestedName: String
    let requestedKind: ItemKind
    let fields: UInt64
    let baseContent: Data?
    let baseMetadata: Data?
    let saveContract: MutationSaveContract?

    init(input: MutationInput, payload: StagedPayload, saveContract: MutationSaveContract? = nil) {
        self.payload = payload
        self.saveContract = saveContract
        requestedParentID = input.parentID; requestedName = input.filename
        requestedKind = input.kind; fields = UInt64(input.fields.rawValue)
        baseContent = input.baseContent; baseMetadata = input.baseMetadata
    }
}
