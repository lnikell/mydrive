/// Compile the small wildcard language once per policy pass. Matching uses a
/// bounded wildcard scan, so long names or repeated stars cannot cause regex
/// backtracking, and regex metacharacters remain ordinary filename characters.
struct ExclusionMatcher: Sendable {
    private struct Rule: Sendable {
        let pattern: [Character]
        let pathScoped: Bool
    }
    private let rules: [Rule]

    init(patterns: [String]) {
        rules = patterns.map { text in
            var pattern: [Character] = []
            for character in text where character != "*" || pattern.last != "*" { pattern.append(character) }
            return Rule(pattern: pattern, pathScoped: text.contains("/"))
        }
    }

    func excludes(_ path: String) -> Bool {
        guard !rules.isEmpty else { return false }
        let whole = Array(path)
        let components = path.split(separator: "/").map { Array($0) }
        return rules.contains { rule in
            if rule.pathScoped { return Self.matches(whole, rule.pattern) }
            return components.contains { Self.matches($0, rule.pattern) }
        }
    }

    private static func matches(_ text: [Character], _ pattern: [Character]) -> Bool {
        var character = 0, token = 0, retry = 0
        var star: Int?
        while character < text.count {
            if token < pattern.count && (pattern[token] == "?" || pattern[token] == text[character]) {
                character += 1; token += 1
            } else if token < pattern.count && pattern[token] == "*" {
                star = token; token += 1; retry = character
            } else if let star {
                retry += 1; character = retry; token = star + 1
            } else { return false }
        }
        while token < pattern.count && pattern[token] == "*" { token += 1 }
        return token == pattern.count
    }
}
