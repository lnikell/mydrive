import Foundation
import MyDriveCore

/// Native actions describe the currently supported representation, not NAS ACLs.
enum ProviderItemAccess: Equatable, Sendable { case readOnly, readWrite }

/// One immutable projection for lookup, enumeration and callback error items.
/// Catalog ancestry is shared only within this bounded call, never cached across
/// a move/rename. The mutation guard remains the authority for every actual RPC.
enum ProviderItemProjection {
    static func item(_ model: CatalogItem, catalog: Catalog, displayName: String) async throws -> ProviderItem {
        try await items([model], catalog: catalog, displayName: displayName)[0]
    }

    /// Once remote work and its Catalog receipt committed, cancellation cannot
    /// turn the accepted upload into a failed callback. Only projection lookup
    /// errors propagate here; the same ancestry/representation rules still apply.
    static func committedItem(_ model: CatalogItem, catalog: Catalog, displayName: String) async throws -> ProviderItem {
        try await project([model], displayName: displayName,
            lookup: { try await catalog.item(id: $0) }, policy: { try await catalog.offlinePolicy(for: $0) },
            registryAvailable: MutationRepresentationPolicy.registryIsAvailable, checkCancellation: {})[0]
    }

    static func items(_ models: [CatalogItem], catalog: Catalog, displayName: String) async throws -> [ProviderItem] {
        try await items(models, displayName: displayName,
            lookup: { try await catalog.item(id: $0) }, policy: { try await catalog.offlinePolicy(for: $0) })
    }

    static func items(
        _ models: [CatalogItem], displayName: String,
        lookup: @escaping @Sendable (String) async throws -> CatalogItem?,
        policy: @escaping @Sendable (String) async throws -> OfflinePolicy,
        registryAvailable: @escaping @Sendable () -> Bool = MutationRepresentationPolicy.registryIsAvailable
    ) async throws -> [ProviderItem] {
        try await project(models, displayName: displayName, lookup: lookup, policy: policy,
            registryAvailable: registryAvailable, checkCancellation: { try Task.checkCancellation() })
    }

    private static func project(
        _ models: [CatalogItem], displayName: String,
        lookup: @escaping @Sendable (String) async throws -> CatalogItem?,
        policy: @escaping @Sendable (String) async throws -> OfflinePolicy,
        registryAvailable: @escaping @Sendable () -> Bool,
        checkCancellation: @escaping @Sendable () throws -> Void
    ) async throws -> [ProviderItem] {
        guard models.count <= 128, Set(models.map(\.id)).count == models.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var resolver = PackageAccess(models: models, lookup: lookup, registryAvailable: registryAvailable,
            checkCancellation: checkCancellation)
        var result: [ProviderItem] = []
        result.reserveCapacity(models.count)
        for model in models {
            try checkCancellation()
            let access = try await resolver.access(for: model)
            let offline = try await policy(model.id)
            try checkCancellation()
            result.append(ProviderItem(model, policy: offline, displayName: displayName, access: access))
        }
        return result
    }

    private struct PackageAccess {
        let models: [String: CatalogItem]
        let lookup: @Sendable (String) async throws -> CatalogItem?
        let registryAvailable: @Sendable () -> Bool
        let checkCancellation: @Sendable () throws -> Void
        // A page can contain unrelated deep leaves. Cap shared observations,
        // while each uncached walk still has its own128-node stack bound.
        var ancestors: [String: CatalogItem] = [:]

        init(models: [CatalogItem], lookup: @escaping @Sendable (String) async throws -> CatalogItem?,
             registryAvailable: @escaping @Sendable () -> Bool,
             checkCancellation: @escaping @Sendable () throws -> Void) {
            self.models = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
            self.lookup = lookup
            self.registryAvailable = registryAvailable
            self.checkCancellation = checkCancellation
        }

        mutating func access(for model: CatalogItem) async throws -> ProviderItemAccess {
            var current = model
            var visited: Set<String> = []
            var value = ProviderItemAccess.readOnly
            for _ in 0..<128 {
                try checkCancellation()
                guard visited.insert(current.id).inserted, !current.isDeleted else { break }
                if current.id == Catalog.rootID {
                    if current.entry.kind == .directory, current.parentID == nil { value = .readWrite }
                    break
                }
                do {
                    if try MutationRepresentationPolicy.isPackageDirectory(current.entry,
                        registryAvailable: registryAvailable) { break }
                } catch { break } // Unavailable type registry must not enable writes.
                guard let parentID = current.parentID else { break }
                let parent: CatalogItem?
                if let known = models[parentID] ?? ancestors[parentID] { parent = known }
                else {
                    parent = try await lookup(parentID)
                    try checkCancellation()
                    if let parent, parent.id == parentID, ancestors.count < 128 { ancestors[parentID] = parent }
                }
                guard let parent, parent.id == parentID, !parent.isDeleted, parent.entry.kind == .directory else { break }
                current = parent
            }
            return value
        }
    }
}
