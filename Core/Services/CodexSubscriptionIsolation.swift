import Foundation
import Yams

/// Implements the API-key side of the core-wide, mutually exclusive source policy.
/// Client profile switches never call this service. Priority values are left untouched.
enum CodexSubscriptionIsolation {
    /// Config sections holding API-key credentials, i.e. everything that is not a subscription.
    static let credentialSections = [
        ProviderKind.codex.rawValue,
        ProviderKind.openai.rawValue,
        ProviderKind.claude.rawValue,
        ProviderKind.gemini.rawValue,
    ]

    /// Ids the Codex subscription serves. Shared with the inverse global switch so both sides of
    /// the overlap are described in one place.
    static var patterns: [String] { CoreConfigStore.codexOverlappingModelExclusions }

    /// Add or remove our patterns across every API-key credential. Returns true when `root` changed.
    ///
    /// Enabling only touches rows that actually declare a matching model, so a provider with no
    /// GPT ids is left without a pointless `excluded-models` key.
    static func apply(enabled: Bool, to root: inout [String: Any]) -> Bool {
        var changed = false
        for section in credentialSections {
            guard var rows = root[section] as? [[String: Any]] else { continue }
            var sectionChanged = false
            for index in rows.indices {
                let wanted = enabled ? matchingPatterns(in: rows[index]) : []
                if applyPatterns(wanted, to: &rows[index]) {
                    sectionChanged = true
                }
            }
            if sectionChanged {
                root[section] = rows
                changed = true
            }
        }
        return changed
    }

    /// Patterns that hit at least one model this credential declares.
    private static func matchingPatterns(in row: [String: Any]) -> [String] {
        let ids = declaredModelIDs(in: row)
        guard !ids.isEmpty else { return [] }
        return patterns.filter { pattern in
            ids.contains { matches(pattern: pattern.lowercased(), value: $0) }
        }
    }

    /// Public ids this credential answers to. CPA exposes `alias` when present, `name` otherwise.
    private static func declaredModelIDs(in row: [String: Any]) -> [String] {
        guard let models = row["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { model in
            let raw = (model["alias"] as? String) ?? (model["name"] as? String) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Merge `wanted` into the row's `excluded-models` and drop the ones we no longer want.
    ///
    /// Entries the user added by hand are preserved; only our own patterns are removed, which
    /// is what makes turning the switch off non-destructive.
    private static func applyPatterns(_ wanted: [String], to row: inout [String: Any]) -> Bool {
        let existing = (row["excluded-models"] as? [String]) ?? []
        let ours = Set(patterns.map { $0.lowercased() })
        var next = existing.filter { !ours.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        next.append(contentsOf: wanted)

        if next == existing { return false }
        if next.isEmpty {
            guard row["excluded-models"] != nil else { return false }
            row.removeValue(forKey: "excluded-models")
        } else {
            row["excluded-models"] = next
        }
        return true
    }

    /// Mirror of CPA's `matchWildcard`, limited to the `*` it supports.
    static func matches(pattern: String, value: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        guard pattern.contains("*") else { return pattern == value }

        let parts = pattern.components(separatedBy: "*")
        var rest = Substring(value)
        if let prefix = parts.first, !prefix.isEmpty {
            guard rest.hasPrefix(prefix) else { return false }
            rest = rest.dropFirst(prefix.count)
        }
        if let suffix = parts.last, !suffix.isEmpty {
            guard rest.hasSuffix(suffix) else { return false }
            rest = rest.dropLast(suffix.count)
        }
        for middle in parts.dropFirst().dropLast() where !middle.isEmpty {
            guard let hit = rest.range(of: middle) else { return false }
            rest = rest[hit.upperBound...]
        }
        return true
    }
}
