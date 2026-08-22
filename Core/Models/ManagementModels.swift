import Foundation

enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case codex = "codex-api-key"
    case openai = "openai-compatibility"
    case claude = "claude-api-key"
    case gemini = "gemini-api-key"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: return "Codex 原生 Responses"
        case .openai: return "OpenAI 兼容"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        }
    }

    /// Shown near the section picker / editor: what this section actually is, since `codex-api-key`
    /// reads as OpenAI/Codex-specific but is really "raw Responses passthrough, no translation" —
    /// any vendor whose upstream speaks native Responses belongs here, DeepSeek included.
    var protocolHelpText: String? {
        switch self {
        case .codex:
            return "这是协议选择，不是品牌限定：任何上游支持原生 Responses 接口的 Provider 都可以放这里"
                + "（零转换直通）。只支持 Chat Completions 的上游请放到「OpenAI 兼容」。"
        default:
            return nil
        }
    }

    var brandKey: String {
        switch self {
        case .codex: return "codex"
        case .openai: return "openai"
        case .claude: return "claude"
        case .gemini: return "gemini"
        }
    }

    var managementPath: String { rawValue }

    /// OpenAI-compat style providers that require a `name` field.
    var requiresName: Bool {
        switch self {
        case .openai: return true
        default: return false
        }
    }

    /// OpenAI-compatible default when no base URL is entered.
    static let openAIDefaultBaseURL = "https://api.openai.com/v1"

    /// Display name for a row that carries no `name` field, derived from its base-url host.
    ///
    /// `codex-api-key` / `claude-api-key` / `gemini-api-key` rows have no `name` — they are
    /// protocol-shaped passthrough sections any vendor can use, not brand-exclusive ones — so
    /// there is nothing else to identify a provider by. CPA also reports every `codex-api-key`
    /// model as `owned_by: openai`/`codex` on its own `/v1/models`, so without this the picker
    /// would additionally lump every native-Responses provider into the "Codex 订阅" group.
    static func hostDerivedDisplayName(baseURL: String) -> String {
        let host = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?
            .host?.lowercased() ?? ""
        let label = host
            .replacingOccurrences(of: "^(api\\.|www\\.)", with: "", options: .regularExpression)
            .split(separator: ".")
            .first
            .map(String.init) ?? host
        guard !label.isEmpty else { return "unknown" }
        return label.prefix(1).uppercased() + label.dropFirst()
    }
}

struct ProviderModelEntry: Identifiable, Equatable, Sendable {
    var id: String { "\(name)|\(alias)" }
    var name: String
    var alias: String
    var displayName: String
    var maxContextLength: Int?
    var thinkingLevels: [String]

    init(raw: [String: Any]) {
        name = Self.string(raw["name"]) ?? ""
        alias = Self.string(raw["alias"]) ?? name
        displayName = Self.string(raw["display-name"])
            ?? Self.string(raw["displayName"])
            ?? (alias.isEmpty ? name : alias)
        maxContextLength = Self.int(raw["max-context-length"])
            ?? Self.int(raw["maxContextLength"])
        if let thinking = raw["thinking"] as? [String: Any],
           let levels = thinking["levels"] as? [String]
        {
            thinkingLevels = AgentReasoningEffort.sanitizeLevels(levels)
        } else if let levels = raw["thinking-levels"] as? [String] {
            thinkingLevels = AgentReasoningEffort.sanitizeLevels(levels)
        } else {
            thinkingLevels = []
        }
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func int(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String, let n = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return n
        }
        return nil
    }
}

struct ProviderConfig: Identifiable {
    var id: String
    /// Index in the management API list (not the filtered UI index).
    var listIndex: Int
    var name: String
    var baseURL: String
    var apiKey: String
    var disabled: Bool
    /// CPA fill-first / credential selection: higher wins (0 = default).
    var priority: Int
    var authIndex: String?
    var raw: [String: Any]
    /// True when api-key was restored from local cache (server often omits secrets).
    var apiKeyFromCache: Bool
    /// openai-compatibility `models` (name / alias / display-name).
    var models: [ProviderModelEntry]

    init(raw: [String: Any], index: Int, cachedAPIKey: String? = nil) {
        self.raw = raw
        self.listIndex = index
        name = Self.string(raw["name"])
            ?? Self.string(raw["api-key"])
            ?? Self.string(raw["apiKey"])
            ?? "配置 \(index + 1)"
        baseURL = Self.string(raw["base-url"]) ?? Self.string(raw["baseUrl"]) ?? ""
        let extracted = Self.extractAPIKey(from: raw)
        let serverKey = extracted.key
        if !serverKey.isEmpty {
            apiKey = serverKey
            apiKeyFromCache = false
        } else if let cachedAPIKey, !cachedAPIKey.isEmpty {
            apiKey = cachedAPIKey
            apiKeyFromCache = true
        } else {
            apiKey = ""
            apiKeyFromCache = false
        }
        disabled = Self.bool(raw["disabled"])
        priority = Self.int(raw["priority"]) ?? 0
        authIndex = Self.string(raw["auth-index"])
            ?? Self.string(raw["authIndex"])
            ?? extracted.authIndex
        if let list = raw["models"] as? [[String: Any]] {
            models = list.map(ProviderModelEntry.init(raw:))
                .filter { !$0.name.isEmpty || !$0.alias.isEmpty }
        } else {
            models = []
        }
        // Prefer stable server identity when present.
        if let authIndex, !authIndex.isEmpty {
            id = "auth:\(authIndex)"
        } else {
            id = [
                Self.string(raw["name"]),
                Self.string(raw["base-url"]) ?? Self.string(raw["baseUrl"]),
                String(index),
            ]
            .compactMap { $0 }
            .joined(separator: "|")
        }
    }

    /// Prefer modern `api-key-entries`; fall back to legacy top-level `api-key`.
    static func extractAPIKey(from raw: [String: Any]) -> (key: String, authIndex: String?) {
        if let entries = raw["api-key-entries"] as? [[String: Any]] {
            for entry in entries {
                if let key = string(entry["api-key"]) ?? string(entry["apiKey"]), !key.isEmpty {
                    let idx = string(entry["auth-index"]) ?? string(entry["authIndex"])
                    return (key, idx)
                }
            }
        }
        if let keys = raw["api-keys"] as? [String] {
            for key in keys {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return (trimmed, nil) }
            }
        }
        let top = string(raw["api-key"]) ?? string(raw["apiKey"]) ?? ""
        return (top, nil)
    }

    /// Write both legacy `api-key` and modern `api-key-entries` so CLIProxyAPI always has auth.
    static func applyAPIKey(to row: inout [String: Any], apiKey: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        row["api-key"] = key
        var entry: [String: Any] = ["api-key": key]
        if let existing = row["api-key-entries"] as? [[String: Any]],
           let first = existing.first
        {
            // Preserve auth-index / weight / proxy-url on first entry.
            entry = first
            entry["api-key"] = key
            var rest = Array(existing.dropFirst())
            row["api-key-entries"] = [entry] + rest
        } else {
            row["api-key-entries"] = [entry]
        }
    }

    var deletionQuery: [String: String] {
        var query: [String: String] = [:]
        if let name = Self.string(raw["name"]) ?? (name.hasPrefix("配置 ") ? nil : name) {
            query["name"] = name
        }
        if !apiKey.isEmpty { query["api-key"] = apiKey }
        if !baseURL.isEmpty { query["base-url"] = baseURL }
        if let authIndex, !authIndex.isEmpty { query["auth-index"] = authIndex }
        return query
    }

    /// Row payload for PUT list, preserving fields and injecting known secret.
    func putDictionary(apiKeyOverride: String? = nil) -> [String: Any] {
        var row = raw
        let key = (apiKeyOverride ?? apiKey).trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            Self.applyAPIKey(to: &row, apiKey: key)
        }
        if !name.isEmpty, !name.hasPrefix("配置 ") {
            row["name"] = name
        }
        if !baseURL.isEmpty {
            row["base-url"] = baseURL
        }
        row["disabled"] = disabled
        if priority > 0 {
            row["priority"] = priority
        } else {
            row.removeValue(forKey: "priority")
        }
        return row
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return false
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? Double { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

struct AuthFileInfo: Identifiable {
    var id: String { name }
    var name: String
    var provider: String
    var disabled: Bool
    var priority: Int?
    var authIndex: String?

    init?(raw: [String: Any]) {
        guard let name = Self.string(raw["name"]) ?? Self.string(raw["file"]) else {
            return nil
        }
        self.name = name
        provider = Self.string(raw["provider"]) ?? Self.string(raw["type"]) ?? "unknown"
        disabled = Self.bool(raw["disabled"])
        priority = Self.int(raw["priority"])
        authIndex = Self.string(raw["auth_index"]) ?? Self.string(raw["authIndex"])
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return false
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}
