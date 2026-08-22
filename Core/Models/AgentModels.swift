import Foundation

/// Coding agents managed by the Agents page (cc-switch-style core).
enum AgentKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case claude
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var systemImage: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "terminal"
        }
    }

    var liveConfigPathHint: String {
        switch self {
        case .claude: return "~/.claude/settings.json"
        case .codex: return "~/.codex/config.toml"
        }
    }

    var modelRoles: [AgentModelRole] {
        switch self {
        case .claude: return [.main, .sonnet, .opus, .haiku, .fable, .subagent]
        case .codex: return [.main]
        }
    }

    /// Claude and Codex can pin effort when the selected model supports it.
    var supportsReasoningEffort: Bool { true }

    /// Fallback levels when no model id is known yet (prefer `AgentReasoningEffort.options`).
    var reasoningEffortOptions: [String] {
        AgentReasoningEffort.options(agent: self, modelID: "")
    }
}

/// Logical model slots mapped onto each agent's own config keys.
enum AgentModelRole: String, CaseIterable, Identifiable, Sendable {
    case main
    /// Legacy alias retained for decoding old profiles; new Claude UI uses `.haiku`.
    case fast
    case sonnet
    case opus
    case haiku
    case fable
    case subagent
    /// Legacy Grok Build slot; kept so old profiles still decode.
    case webSearch

    var id: String { rawValue }

    func title(for agent: AgentKind) -> String {
        switch self {
        case .main: return agent == .codex ? "默认模型" : "主模型（Fallback）"
        case .fast: return "快速模型"
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        case .haiku: return "Haiku"
        case .fable: return "Fable"
        case .subagent: return "Subagent"
        case .webSearch: return "Web 搜索模型"
        }
    }

    /// cc-switch appends `[1M]` to the model id for roles Claude Code serves with the
    /// 1M-context beta; Haiku has no 1M variant.
    func supportsOneMContext(for agent: AgentKind) -> Bool {
        guard agent == .claude else { return false }
        switch self {
        case .main, .sonnet, .opus, .fable, .subagent: return true
        case .fast, .haiku, .webSearch: return false
        }
    }

    /// Claude env key holding the human-readable name shown in `/model`, if the role has one.
    func claudeDisplayNameKey(for agent: AgentKind) -> String? {
        guard agent == .claude else { return nil }
        switch self {
        case .sonnet: return "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"
        case .opus: return "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"
        case .haiku, .fast: return "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME"
        case .fable: return "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME"
        case .main, .subagent, .webSearch: return nil
        }
    }

    func hint(for agent: AgentKind) -> String {
        switch (agent, self) {
        case (.claude, .main): return "ANTHROPIC_MODEL"
        case (.claude, .sonnet): return "ANTHROPIC_DEFAULT_SONNET_MODEL"
        case (.claude, .opus): return "ANTHROPIC_DEFAULT_OPUS_MODEL"
        case (.claude, .haiku), (.claude, .fast): return "ANTHROPIC_DEFAULT_HAIKU_MODEL"
        case (.claude, .fable): return "ANTHROPIC_DEFAULT_FABLE_MODEL"
        case (.claude, .subagent): return "CLAUDE_CODE_SUBAGENT_MODEL"
        case (.codex, .main): return "config.toml · model（默认）"
        case (.codex, _): return "model catalog"
        default: return ""
        }
    }
}

/// `claude-sonnet-4-5[1M]` style suffix understood by Claude Code (same shape as cc-switch).
enum ClaudeContextMarker {
    static let oneM = "[1M]"

    static func hasOneM(_ model: String) -> Bool {
        model.trimmingTrailingWhitespace().lowercased().hasSuffix("[1m]")
    }

    static func stripOneM(_ model: String) -> String {
        let trimmed = model.trimmingTrailingWhitespace()
        guard trimmed.lowercased().hasSuffix("[1m]") else { return model }
        return String(trimmed.dropLast(oneM.count)).trimmingTrailingWhitespace()
    }

    static func setOneM(_ model: String, enabled: Bool) -> String {
        let base = stripOneM(model).trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return "" }
        return enabled ? base + oneM : base
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var s = self
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return s
    }
}

/// Stable Codex `model_provider` bucket so history does not fragment across upstreams.
enum CodexStableProvider {
    static let id = "custom"
    static let reservedIDs: Set<String> = ["openai", "ollama", "azure", "custom"]

    /// Exact string Codex compares `[model_providers.*].name` against to decide whether a
    /// provider gets the official feature gates — remote compaction above all.
    static let openAIProviderName = "OpenAI"
}

/// Per-model overrides for context window and supported reasoning levels.
struct AgentModelOverride: Equatable, Codable, Sendable {
    /// Tokens; nil = use known default / writer fallback.
    var contextWindow: Int?
    /// Supported effort tags for catalog / hints; nil = use matrix default.
    var reasoningLevels: [String]?

    var isEmpty: Bool {
        (contextWindow == nil || (contextWindow ?? 0) <= 0)
            && (reasoningLevels == nil)
    }
}

struct AgentProviderProfile: Identifiable, Equatable, Codable, Sendable {
    var id: String
    var agent: AgentKind
    var name: String
    /// Base URL written into the agent (Claude: Anthropic base; Codex: often …/v1).
    var endpoint: String
    var apiKey: String
    /// Main model (`AgentModelRole.main`).
    var model: String
    var fastModel: String
    /// Legacy Grok Build field; kept so old profiles still decode.
    var webSearchModel: String
    /// Additional cc-switch model roles (sonnet / opus / haiku / fable / subagent).
    var modelMappings: [String: String]
    /// Codex external catalog model ids (written to `maccliproxy-model-catalog.json`).
    /// Empty → fall back to `[model]` (or CPA `/v1/models` at write time).
    var catalogModels: [String]
    /// Per model-id overrides (context window + supported reasoning levels).
    var modelOverrides: [String: AgentModelOverride]
    /// Codex `model_reasoning_effort`; empty = leave to the agent's own default.
    var reasoningEffort: String
    /// Write `name = "OpenAI"` into `[model_providers.custom]` so Codex's `is_openai()`
    /// feature gates match and it uses remote compaction.
    ///
    /// Only correct when every catalog model reaches an upstream that implements
    /// `/responses/compact`: Codex picks remote-vs-local once from this flag and never
    /// falls back, so a failed remote compaction just leaves the history uncompacted.
    var claimsOpenAIProvider: Bool
    /// While enabled, keep the GPT ids the Codex subscription also serves away from every
    /// other provider, so they cannot be answered by an upstream without remote compaction.
    var codexSubscriptionOnly: Bool
    /// Built-in Local CPA profile — endpoint/key refreshed from GUI config on enable.
    var isLocalCPA: Bool
    /// Pre-enable live snapshot (cc-switch-style default); restore writes files back from backup.
    var isDefault: Bool
    /// Built-in official direct profile (Anthropic/OpenAI direct connection without custom proxy).
    var isOfficial: Bool
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    static func defaultID(for agent: AgentKind) -> String {
        "default-\(agent.rawValue)"
    }

    static func officialID(for agent: AgentKind) -> String {
        "official-\(agent.rawValue)"
    }

    /// Catalog ids for Codex enable: `catalogModels` order preserved; default appended if missing.
    var resolvedCodexCatalogModels: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in catalogModels {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            out.append(id)
        }
        let main = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !main.isEmpty, seen.insert(main).inserted {
            out.append(main)
        }
        return out
    }

    static func localCPA(agent: AgentKind, port: UInt16, apiKey: String, model: String = "") -> AgentProviderProfile {
        let now = Date()
        let endpoint: String
        switch agent {
        case .claude:
            endpoint = "http://127.0.0.1:\(port)"
        case .codex:
            endpoint = "http://127.0.0.1:\(port)/v1"
        }
        return AgentProviderProfile(
            id: "cpa-\(agent.rawValue)",
            agent: agent,
            name: "本机 CPA",
            endpoint: endpoint,
            apiKey: apiKey,
            model: model,
            catalogModels: model.isEmpty ? [] : [model],
            isLocalCPA: true,
            isDefault: false,
            notes: "MacCLIProxyAPI 本地内核",
            createdAt: now,
            updatedAt: now
        )
    }

    static func makeDefault(
        agent: AgentKind,
        endpoint: String = "",
        apiKey: String = "",
        model: String = "",
        fastModel: String = "",
        webSearchModel: String = "",
        modelMappings: [String: String] = [:],
        catalogModels: [String] = [],
        reasoningEffort: String = ""
    ) -> AgentProviderProfile {
        let now = Date()
        return AgentProviderProfile(
            id: defaultID(for: agent),
            agent: agent,
            name: "默认",
            endpoint: endpoint,
            apiKey: apiKey,
            model: model,
            fastModel: fastModel,
            webSearchModel: webSearchModel,
            modelMappings: modelMappings,
            catalogModels: catalogModels,
            reasoningEffort: reasoningEffort,
            isLocalCPA: false,
            isDefault: true,
            isOfficial: false,
            notes: "启用前的配置快照，可随时切回",
            createdAt: now,
            updatedAt: now
        )
    }

    static func official(agent: AgentKind) -> AgentProviderProfile {
        let now = Date()
        let name: String
        let notes: String
        switch agent {
        case .claude:
            name = "Claude 官方"
            notes = "Anthropic 官方直连，使用 Claude CLI 自带登录认证"
        case .codex:
            name = "OpenAI 官方"
            notes = "OpenAI 官方直连，使用 ChatGPT Plus/Pro 订阅 OAuth 登录"
        }
        return AgentProviderProfile(
            id: officialID(for: agent),
            agent: agent,
            name: name,
            endpoint: "",
            apiKey: "",
            model: "",
            isLocalCPA: false,
            isDefault: false,
            isOfficial: true,
            notes: notes,
            createdAt: now,
            updatedAt: now
        )
    }

    func model(for role: AgentModelRole) -> String {
        switch role {
        case .main: return model
        case .fast: return fastModel
        case .sonnet, .opus:
            return modelMappings[role.rawValue] ?? model
        case .haiku:
            return modelMappings[role.rawValue] ?? fastModel
        case .fable, .subagent:
            return modelMappings[role.rawValue] ?? ""
        case .webSearch: return webSearchModel
        }
    }

    mutating func setModel(_ value: String, for role: AgentModelRole) {
        switch role {
        case .main: model = value
        case .fast: fastModel = value
        case .sonnet, .opus, .haiku, .fable, .subagent:
            modelMappings[role.rawValue] = value
        case .webSearch: webSearchModel = value
        }
    }

    func modelOverride(for modelID: String) -> AgentModelOverride? {
        let key = AgentReasoningEffort.normalizeModelID(modelID)
        guard !key.isEmpty else { return nil }
        if let exact = modelOverrides[modelID] { return exact }
        if let normalized = modelOverrides[key] { return normalized }
        return modelOverrides.first(where: {
            AgentReasoningEffort.normalizeModelID($0.key) == key
        })?.value
    }

    func resolvedContextWindow(for modelID: String, fallback: Int = 128_000) -> Int {
        AgentReasoningEffort.resolveContextWindow(
            modelID: modelID,
            override: modelOverride(for: modelID)?.contextWindow,
            fallback: fallback
        )
    }

    func resolvedReasoningLevels(for modelID: String) -> [String] {
        AgentReasoningEffort.options(
            agent: agent,
            modelID: modelID,
            override: modelOverride(for: modelID)?.reasoningLevels
        )
    }

    mutating func setContextWindow(_ value: Int?, for modelID: String) {
        let key = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        var entry = modelOverrides[key] ?? AgentModelOverride()
        entry.contextWindow = (value ?? 0) > 0 ? value : nil
        if entry.isEmpty {
            modelOverrides.removeValue(forKey: key)
        } else {
            modelOverrides[key] = entry
        }
    }

    mutating func setReasoningLevels(_ levels: [String]?, for modelID: String) {
        let key = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        var entry = modelOverrides[key] ?? AgentModelOverride()
        if let levels {
            entry.reasoningLevels = AgentReasoningEffort.sanitizeLevels(levels)
        } else {
            entry.reasoningLevels = nil
        }
        if entry.isEmpty {
            modelOverrides.removeValue(forKey: key)
        } else {
            modelOverrides[key] = entry
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, agent, name, endpoint, apiKey, model, fastModel, webSearchModel, modelMappings
        case catalogModels, modelOverrides
        case reasoningEffort
        case claimsOpenAIProvider, codexSubscriptionOnly
        case isLocalCPA, isDefault, isOfficial, notes, createdAt, updatedAt
    }

    init(
        id: String,
        agent: AgentKind,
        name: String,
        endpoint: String,
        apiKey: String,
        model: String,
        fastModel: String = "",
        webSearchModel: String = "",
        modelMappings: [String: String] = [:],
        catalogModels: [String] = [],
        modelOverrides: [String: AgentModelOverride] = [:],
        reasoningEffort: String = "",
        claimsOpenAIProvider: Bool = false,
        codexSubscriptionOnly: Bool = false,
        isLocalCPA: Bool,
        isDefault: Bool = false,
        isOfficial: Bool = false,
        notes: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.agent = agent
        self.name = name
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.fastModel = fastModel
        self.webSearchModel = webSearchModel
        self.modelMappings = modelMappings
        self.catalogModels = catalogModels
        self.modelOverrides = modelOverrides
        self.reasoningEffort = reasoningEffort
        self.claimsOpenAIProvider = claimsOpenAIProvider
        self.codexSubscriptionOnly = codexSubscriptionOnly
        self.isLocalCPA = isLocalCPA
        self.isDefault = isDefault
        self.isOfficial = isOfficial
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agent = try c.decode(AgentKind.self, forKey: .agent)
        name = try c.decode(String.self, forKey: .name)
        endpoint = try c.decode(String.self, forKey: .endpoint)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        model = try c.decode(String.self, forKey: .model)
        fastModel = try c.decodeIfPresent(String.self, forKey: .fastModel) ?? ""
        webSearchModel = try c.decodeIfPresent(String.self, forKey: .webSearchModel) ?? ""
        modelMappings = try c.decodeIfPresent([String: String].self, forKey: .modelMappings) ?? [:]
        catalogModels = try c.decodeIfPresent([String].self, forKey: .catalogModels) ?? []
        modelOverrides = try c.decodeIfPresent([String: AgentModelOverride].self, forKey: .modelOverrides) ?? [:]
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? ""
        claimsOpenAIProvider = try c.decodeIfPresent(Bool.self, forKey: .claimsOpenAIProvider) ?? false
        codexSubscriptionOnly = try c.decodeIfPresent(Bool.self, forKey: .codexSubscriptionOnly) ?? false
        isLocalCPA = try c.decode(Bool.self, forKey: .isLocalCPA)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? (id == Self.defaultID(for: agent))
        isOfficial = try c.decodeIfPresent(Bool.self, forKey: .isOfficial) ?? (id == Self.officialID(for: agent))
        notes = try c.decode(String.self, forKey: .notes)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(agent, forKey: .agent)
        try c.encode(name, forKey: .name)
        try c.encode(endpoint, forKey: .endpoint)
        try c.encode(apiKey, forKey: .apiKey)
        try c.encode(model, forKey: .model)
        try c.encode(fastModel, forKey: .fastModel)
        try c.encode(webSearchModel, forKey: .webSearchModel)
        try c.encode(modelMappings, forKey: .modelMappings)
        try c.encode(catalogModels, forKey: .catalogModels)
        try c.encode(modelOverrides, forKey: .modelOverrides)
        try c.encode(reasoningEffort, forKey: .reasoningEffort)
        try c.encode(claimsOpenAIProvider, forKey: .claimsOpenAIProvider)
        try c.encode(codexSubscriptionOnly, forKey: .codexSubscriptionOnly)
        try c.encode(isLocalCPA, forKey: .isLocalCPA)
        try c.encode(isDefault, forKey: .isDefault)
        try c.encode(isOfficial, forKey: .isOfficial)
        try c.encode(notes, forKey: .notes)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

struct AgentSettings: Equatable, Codable, Sendable {
    /// Per-agent currently enabled provider id (live config target).
    var currentProviderIDs: [String: String]
    /// Force Codex live config + new sessions into the stable `custom` bucket.
    var unifyCodexSessionHistory: Bool
    /// When enabling unify, also rewrite existing openai-tagged sessions → custom.
    var migrateCodexSessionsOnUnify: Bool
    /// When turning unify off, move the migrated sessions back to the official bucket.
    var restoreCodexSessionsOnDisableUnify: Bool

    static let `default` = AgentSettings(
        currentProviderIDs: [:],
        unifyCodexSessionHistory: true,
        migrateCodexSessionsOnUnify: false,
        restoreCodexSessionsOnDisableUnify: true
    )

    init(
        currentProviderIDs: [String: String],
        unifyCodexSessionHistory: Bool,
        migrateCodexSessionsOnUnify: Bool,
        restoreCodexSessionsOnDisableUnify: Bool = true
    ) {
        self.currentProviderIDs = currentProviderIDs
        self.unifyCodexSessionHistory = unifyCodexSessionHistory
        self.migrateCodexSessionsOnUnify = migrateCodexSessionsOnUnify
        self.restoreCodexSessionsOnDisableUnify = restoreCodexSessionsOnDisableUnify
    }

    // Hand-rolled so settings files written before a key existed still decode instead of
    // silently resetting the whole struct to `.default`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentProviderIDs = try c.decodeIfPresent([String: String].self, forKey: .currentProviderIDs) ?? [:]
        unifyCodexSessionHistory = try c.decodeIfPresent(Bool.self, forKey: .unifyCodexSessionHistory) ?? true
        migrateCodexSessionsOnUnify = try c.decodeIfPresent(Bool.self, forKey: .migrateCodexSessionsOnUnify) ?? false
        restoreCodexSessionsOnDisableUnify = try c.decodeIfPresent(
            Bool.self,
            forKey: .restoreCodexSessionsOnDisableUnify
        ) ?? true
    }

    func currentProviderID(for agent: AgentKind) -> String? {
        currentProviderIDs[agent.rawValue]
    }

    mutating func setCurrentProviderID(_ id: String?, for agent: AgentKind) {
        if let id {
            currentProviderIDs[agent.rawValue] = id
        } else {
            currentProviderIDs.removeValue(forKey: agent.rawValue)
        }
    }
}

struct AgentSessionRecord: Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var agent: AgentKind
    var title: String
    var projectPath: String?
    var filePath: String
    var updatedAt: Date
    var modelProvider: String?
    var resumeCommand: String?
}

struct CodexUnifyResult: Equatable, Sendable {
    var jsonlRewritten: Int
    var sqliteUpdated: Int
    var backupDirectory: String?
}

struct CodexRestoreResult: Equatable, Sendable {
    var jsonlRestored: Int
    var sqliteRestored: Int
    var backupDirectory: String?
    var skippedReason: String?
}
