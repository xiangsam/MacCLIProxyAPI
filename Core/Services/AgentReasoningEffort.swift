import Foundation

/// Reasoning / thinking effort options aligned with DeepSeek Responses API docs
/// plus Codex/Grok fallbacks.
enum AgentReasoningEffort {
    /// Canonical effort tags shown in editors (order preserved).
    static let selectableTags: [String] = [
        "none", "minimal", "low", "medium", "high", "xhigh", "max",
    ]

    /// Normalize a model id for matrix lookup (strip Claude `[1M]`, `models/` prefix).
    static func normalizeModelID(_ raw: String) -> String {
        var id = ClaudeContextMarker.stripOneM(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if id.hasPrefix("models/") {
            id = String(id.dropFirst("models/".count))
        }
        return id
    }

    /// Allowed effort tags for this agent + primary model (empty = no effort UI).
    /// `override` wins when non-nil (including empty = explicitly none).
    static func options(
        agent: AgentKind,
        modelID: String,
        override: [String]? = nil
    ) -> [String] {
        if let override {
            return sanitizeLevels(override)
        }
        let id = normalizeModelID(modelID)
        if id.isEmpty {
            return defaultOptions(for: agent)
        }
        if let matrix = effortMatrix(for: id) {
            return matrix
        }
        return defaultOptions(for: agent)
    }

    /// Whether the editor should show a thinking-effort picker for this agent/model.
    static func isSupported(agent: AgentKind, modelID: String, override: [String]? = nil) -> Bool {
        !options(agent: agent, modelID: modelID, override: override).isEmpty
    }

    /// Keep a previously saved effort only if still valid for the model; otherwise clear.
    static func sanitized(
        _ effort: String,
        agent: AgentKind,
        modelID: String,
        override: [String]? = nil
    ) -> String {
        let trimmed = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let allowed = options(agent: agent, modelID: modelID, override: override)
        if allowed.isEmpty { return "" }
        return allowed.contains(trimmed) ? trimmed : ""
    }

    /// Codex catalog `supported_reasoning_levels` rows for a model id.
    static func catalogLevels(modelID: String, override: [String]? = nil) -> [[String: String]] {
        let efforts = options(agent: .codex, modelID: modelID, override: override)
        guard !efforts.isEmpty else {
            return [
                ["effort": "medium", "description": description(for: "medium")],
                ["effort": "high", "description": description(for: "high")],
            ]
        }
        return efforts.map { ["effort": $0, "description": description(for: $0)] }
    }

    static func description(for effort: String) -> String {
        switch effort.lowercased() {
        case "none": return "No extra reasoning"
        case "minimal": return "Minimal reasoning for the fastest replies"
        case "low": return "Fast responses with lighter reasoning"
        case "medium": return "Balances speed and reasoning depth"
        case "high": return "Greater reasoning depth for complex problems"
        case "xhigh": return "Extra-high reasoning for hard multi-step work"
        case "max": return "Maximum reasoning depth"
        default: return effort
        }
    }

    /// Best-known context window for a model id (tokens). Nil → caller uses fallback.
    static func knownContextWindow(for modelID: String) -> Int? {
        let id = normalizeModelID(modelID)
        guard !id.isEmpty else { return nil }

        if id.hasPrefix("deepseek-v4") {
            return 1_000_000
        }
        if id.hasPrefix("gpt-5.6") {
            return 1_000_000
        }
        if id == "gpt-5.5" || id.hasPrefix("gpt-5.5-") {
            return 1_000_000
        }
        if id.hasPrefix("gpt-5.4") || id.hasPrefix("gpt-5.3") {
            return 272_000
        }
        if ClaudeContextMarker.hasOneM(modelID) || id.hasSuffix("-1m") {
            return 1_000_000
        }
        if id.hasPrefix("claude-sonnet-5") {
            return 200_000
        }
        if id.hasPrefix("claude-") {
            return 176_000
        }
        if id.hasPrefix("grok-") {
            return 500_000
        }
        return nil
    }

    /// Resolve context window: user override → known matrix/catalog → fallback.
    static func resolveContextWindow(
        modelID: String,
        override: Int?,
        fallback: Int = 128_000
    ) -> Int {
        if let override, override > 0 { return override }
        if let known = knownContextWindow(for: modelID), known > 0 { return known }
        return max(fallback, 1)
    }

    static func sanitizeLevels(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tag in selectableTags {
            guard raw.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else {
                continue
            }
            if seen.insert(tag).inserted {
                out.append(tag)
            }
        }
        // Preserve unknown custom tags after known ones.
        for value in raw {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    // MARK: - Matrix

    /// DeepSeek V4 official Responses API supports `none`…`max`
    /// (https://api-docs.deepseek.com/api/create-response); other families get narrower matrices.
    private static func effortMatrix(for id: String) -> [String]? {
        if id.hasPrefix("deepseek-v4") {
            return ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        }
        if ["gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"].contains(id)
            || id.hasPrefix("gpt-5.6-")
        {
            return ["low", "medium", "high", "xhigh", "max"]
        }
        if id == "gpt-5.5" || id.hasPrefix("gpt-5.5-") {
            return ["none", "low", "medium", "high", "xhigh"]
        }
        if ["claude-sonnet-5", "claude-opus-4.7", "claude-opus-4.8"].contains(id)
            || id.hasPrefix("claude-sonnet-5")
            || id.hasPrefix("claude-opus-4.7")
            || id.hasPrefix("claude-opus-4.8")
        {
            return ["low", "medium", "high", "xhigh", "max"]
        }
        if ["claude-sonnet-4.6", "claude-opus-4.6"].contains(id)
            || id.hasPrefix("claude-sonnet-4.6")
            || id.hasPrefix("claude-opus-4.6")
        {
            return ["low", "medium", "high", "max"]
        }
        if id == "claude-haiku-4.5" || id.hasPrefix("claude-haiku-4.5") {
            return []
        }
        // Known model family without a dedicated row above → base three.
        if id.hasPrefix("gpt-")
            || id.hasPrefix("claude-")
            || id.contains("-ioa")
            || id.hasPrefix("glm-")
            || id.hasPrefix("kimi-")
            || id.hasPrefix("deepseek-")
            || id.hasPrefix("minimax-")
            || id.hasPrefix("hy3")
        {
            return ["low", "medium", "high"]
        }
        return nil
    }

    private static func defaultOptions(for agent: AgentKind) -> [String] {
        switch agent {
        case .codex:
            return ["minimal", "low", "medium", "high", "xhigh"]
        case .claude:
            return ["low", "medium", "high", "xhigh", "max"]
        }
    }
}
