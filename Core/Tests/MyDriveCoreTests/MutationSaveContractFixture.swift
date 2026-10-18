import Foundation
@testable import MyDriveCore

func contractIntent(_ contract: MutationSaveContract? = nil, id: String = "legacy-file") -> JournalIntent {
    .init(idempotencyKey: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        itemID: id, expectedVersion: nil,
        action: .create(parentID: Catalog.rootID, name: "café.bin", kind: .file),
        payload: .init(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            size: 42, sha256: String(repeating: "a", count: 64)),
        destinationPath: "café.bin", saveContract: contract)
}

func evidenceJSON(_ text: String) throws -> MutationContentEvidence {
    try JSONDecoder().decode(MutationContentEvidence.self, from: Data(text.utf8))
}

func sortedIntentJSON(_ intent: JournalIntent) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(intent), as: UTF8.self)
}

func intentJSON(_ text: String) throws -> JournalIntent {
    try JSONDecoder().decode(JournalIntent.self, from: Data(text.utf8))
}

func contractEntry(_ request: JournalIntent) -> CatalogMutationItem {
    .init(id: request.itemID, parentID: Catalog.rootID,
        entry: .init(name: "café.bin", kind: .file, remoteKey: "contract-key", contentVersion: "v1",
                     metadataVersion: "m1", size: 42,
                     objectIdentity: .init(indexNumber: 98, createdFiletime: 99)))
}

func evidence(_ kind: MutationContentEvidence.Kind = .smbAcknowledged,
              bytes: Int64 = 42, hash: String = String(repeating: "a", count: 64)) -> MutationContentEvidence {
    .init(kind: kind, bytes: bytes, sha256: hash)
}

func legacyContractJSON() -> String {
    // Captured from public30e's independently built original Core archive.
    #"{"action":{"create":{"kind":"file","name":"café.bin","parentID":"root"}},"destinationPath":"café.bin","idempotencyKey":"11111111-1111-1111-1111-111111111111","itemID":"legacy-file","payload":{"id":"22222222-2222-2222-2222-222222222222","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":42}}"#
}

func removeStoredRootContract(_ trial: ImportTrial) throws {
    let encoded = try JSONEncoder().encode(trial.intent)
    var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    object.removeValue(forKey: "saveContract")
    let bytes = try JSONSerialization.data(withJSONObject: object)
    let database = try SQLiteConnection(url: trial.fixture.url, cacheKiB: 2_048)
    try database.execute("UPDATE operations SET intent = ? WHERE idempotency_key = ?",
        [.text(String(decoding: bytes, as: UTF8.self)), .text(trial.intent.idempotencyKey.uuidString)])
}
