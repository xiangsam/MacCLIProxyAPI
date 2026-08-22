import Foundation

/// Local cache for Provider API keys.
/// Management GET for `openai-compatibility` often omits `api-key`; we keep a copy so test/edit/toggle still work.
enum ProviderSecretStore {
    private static let fileName = "provider-secrets.json"

    private static var fileURL: URL {
        AppPaths.baseDirectory.appendingPathComponent(fileName)
    }

    static func get(
        section: ProviderKind,
        name: String?,
        authIndex: String?,
        baseURL: String? = nil
    ) -> String? {
        let map = load()
        for key in candidateKeys(section: section, name: name, authIndex: authIndex, baseURL: baseURL) {
            if let value = map[key], !value.isEmpty { return value }
        }
        return nil
    }

    static func set(
        section: ProviderKind,
        name: String?,
        authIndex: String?,
        baseURL: String? = nil,
        apiKey: String
    ) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var map = load()
        for key in candidateKeys(section: section, name: name, authIndex: authIndex, baseURL: baseURL) {
            map[key] = trimmed
        }
        save(map)
    }

    static func remove(
        section: ProviderKind,
        name: String?,
        authIndex: String?,
        baseURL: String? = nil
    ) {
        var map = load()
        for key in candidateKeys(section: section, name: name, authIndex: authIndex, baseURL: baseURL) {
            map.removeValue(forKey: key)
        }
        save(map)
    }

    /// Every stored `codex-api-key` credential's api-key, mapped to its host-derived display name.
    ///
    /// CPA reports a native-Responses leg as `provider=codex` + `auth_type=apikey`, indistinguishable
    /// from a real OpenAI key except by the credential itself — so usage attribution has to match
    /// on `source` (the upstream api-key) against this map rather than the raw `provider` column.
    static func nativeResponsesProviderNames() -> [String: String] {
        var names: [String: String] = [:]
        for (storageKey, apiKey) in load() where !apiKey.isEmpty {
            let parts = storageKey.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3, parts[0] == ProviderKind.codex.rawValue, parts[1] == "base" else { continue }
            names[apiKey] = ProviderKind.hostDerivedDisplayName(baseURL: parts[2])
        }
        return names
    }

    /// Re-inject secrets a management GET omitted, so a full-list PUT cannot blank sibling rows.
    ///
    /// Every caller that PUTs a whole provider list must run this first: CPA returns rows without
    /// `api-key`, so writing the list back verbatim would strip auth from providers the user was
    /// not even editing.
    static func reinject(into list: [[String: Any]], section: ProviderKind) -> [[String: Any]] {
        list.map { row in
            var next = row
            let existing = ProviderConfig.extractAPIKey(from: row).key
            if existing.isEmpty {
                if let cached = get(
                    section: section,
                    name: row["name"] as? String,
                    authIndex: (row["auth-index"] as? String) ?? (row["authIndex"] as? String),
                    baseURL: (row["base-url"] as? String) ?? (row["baseUrl"] as? String)
                ) {
                    ProviderConfig.applyAPIKey(to: &next, apiKey: cached)
                }
            } else {
                // Normalize to dual format even when key already present.
                ProviderConfig.applyAPIKey(to: &next, apiKey: existing)
            }
            return next
        }
    }

    // MARK: - Persistence

    /// Identity keys, most specific first.
    ///
    /// `base` is the fallback that makes nameless sections work at all: `codex-api-key`,
    /// `claude-api-key` and `gemini-api-key` rows carry no `name`, and a freshly added provider has
    /// no server-assigned `auth-index` yet, so without it nothing would be cached and 「测试」
    /// would fail right after 「保存」.
    private static func candidateKeys(
        section: ProviderKind,
        name: String?,
        authIndex: String?,
        baseURL: String?
    ) -> [String] {
        var keys: [String] = []
        let sectionID = section.rawValue
        if let authIndex, !authIndex.isEmpty {
            keys.append("\(sectionID)|auth|\(authIndex)")
        }
        if let name {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty, !n.hasPrefix("配置 ") {
                keys.append("\(sectionID)|name|\(n.lowercased())")
            }
        }
        if let baseURL {
            let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !base.isEmpty {
                keys.append("\(sectionID)|base|\(base)")
            }
        }
        return keys
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return obj
    }

    private static func save(_ map: [String: String]) {
        do {
            try AppPaths.ensureBaseDirectories()
            let data = try JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: .atomic)
            try AppPaths.secureSensitiveFile(fileURL)
        } catch {
            // Best-effort cache; never crash UI.
        }
    }
}
