import FileProvider
import Foundation

extension ProviderTreeImport {
    /// Folder contents arrive as one atomic create. A partial upload would
    /// acknowledge excluded local children incorrectly, so retain the complete
    /// intake instead. Only the existing bounded metadata index is inspected.
    func validateExclusions(snapshot: LocalTreeSnapshot, destination: String,
                            previous: [String]? = nil) async throws -> UserPreferences {
        let policy = try await mutations.preferences()
        if previous == policy.excludedPatterns { return policy }
        guard !policy.excludedPatterns.isEmpty else { return policy }
        let matcher = ExclusionMatcher(patterns: policy.excludedPatterns)
        func check(_ path: String) throws {
            if matcher.excludes(path) {
                throw NSFileProviderError(.excludedFromSync, userInfo: [NSLocalizedDescriptionKey:
                    "This folder contains a path matching Never sync. Its complete local contents are kept. Change the rules or move the excluded files before retrying."])
            }
        }
        try check(destination)
        var cursor: String?
        while true {
            try await mutations.checkActive()
            let page = try snapshot.entries(after: cursor)
            for entry in page where !entry.path.isEmpty { try check(ProviderMutations.join(destination, entry.path)) }
            guard let last = page.last else { break }
            cursor = last.path
        }
        return policy
    }
}
