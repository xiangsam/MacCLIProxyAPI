import Foundation
import Yams

/// Keeps the GPT ids a Codex subscription also serves away from every other provider.
///
/// CPA multiplexes: one `gpt-5.6-sol` request can be answered by the Codex OAuth subscription
/// or by any API-key provider that declares the same id, and a `codex-api-key` native Responses
/// row wins today because it carries a priority. That is normally what the user wants — until a
/// Codex profile claims the OpenAI provider identity to get remote compaction, because
/// `/responses/compact` only exists on the subscription. A compaction answered by a
/// `codex-api-key` provider 404s, and Codex neither retries locally nor reports it.
///
/// The lever is `excluded-models`, the per-credential counterpart of the `oauth-excluded-models`
/// used by the 「GPT 同名模型完全不走 Codex 订阅」 switch — the same idea pointed the other way.
/// It only applies to API-key credentials (`ApplyAuthExcludedModelsMeta` takes the OAuth branch
/// for everything else), which is exactly the set we want to silence: the subscription itself is
/// an OAuth credential and cannot be reached by it.
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

    enum Outcome: Equatable {
        case unchanged
        case applied
        case reverted
        /// The config page's inverse switch is still on; together they exclude the ids everywhere.
        case conflictsWithGlobalExclusion
    }

    /// Converge the core onto what `profile` wants, for both local and remote Codex flows.
    ///
    /// Called on every Codex enable, not only when the switch is on, so switching away from an
    /// isolating profile puts the other providers back into rotation.
    static func sync(
        for profile: AgentProviderProfile,
        globalExclusionEnabled: Bool,
        client: ManagementClient
    ) async throws -> Outcome {
        guard profile.agent == .codex, !profile.isDefault else { return .unchanged }
        let wanted = profile.codexSubscriptionOnly
        let changed = try await sync(enabled: wanted, client: client)
        if wanted, globalExclusionEnabled { return .conflictsWithGlobalExclusion }
        guard changed else { return .unchanged }
        return wanted ? .applied : .reverted
    }

    /// Push the desired state onto the running core. Returns true when the config had to change.
    @discardableResult
    static func sync(enabled: Bool, client: ManagementClient) async throws -> Bool {
        let yaml = try await client.getConfigYAML()
        guard var root = try Yams.load(yaml: yaml) as? [String: Any] else { return false }
        guard apply(enabled: enabled, to: &root) else { return false }
        try await client.putConfigYAML(try Yams.dump(object: root, width: -1, sortKeys: false))
        return true
    }

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
