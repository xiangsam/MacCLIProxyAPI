import Foundation

/// Reads currently active live agent configuration from disk.
enum AgentLiveConfigReader {
    struct Snapshot: Equatable, Sendable {
        var configExists = false
        var endpoint: String?
        var apiKey: String?
        var model: String?
        var fastModel: String?
        var webSearchModel: String?
        var modelMappings: [String: String] = [:]
        var reasoningEffort: String?
        /// Codex only: model ids listed in whatever `model_catalog_json` points at.
        var catalogModels: [String] = []
        /// Codex only: per-model capabilities read back from that catalog.
        var modelOverrides: [String: AgentModelOverride] = [:]
    }

    static func read(agent: AgentKind) -> Snapshot {
        switch agent {
        case .claude: return readClaude()
        case .codex: return readCodex()
        }
    }

    /// Best-effort match: endpoint (+ optional api key) against known profiles.
    ///
    /// Endpoint and key rarely identify a single profile — every profile aimed at the local core
    /// shares both — so `current` decides the tie. Without it the winner is just whoever sorts
    /// first, which is 「本机 CPA」, and enabling any other profile appears to undo itself on the
    /// next reload. `current` is only honoured while it still agrees with the file on disk, so
    /// editing the config by hand still moves the marker.
    static func matchingProfileID(
        agent: AgentKind,
        in profiles: [AgentProviderProfile],
        preferring current: String? = nil
    ) -> String? {
        matchProfileID(live: read(agent: agent), agent: agent, in: profiles, preferring: current)
    }

    static func matchProfileID(
        live: Snapshot,
        agent: AgentKind,
        in profiles: [AgentProviderProfile],
        preferring current: String? = nil
    ) -> String? {
        guard let endpoint = live.endpoint?.trimmingCharacters(in: .whitespacesAndNewlines), !endpoint.isEmpty
        else {
            if let current, let hit = profiles.first(where: { $0.id == current && $0.agent == agent && ($0.isOfficial || $0.isDefault) }) {
                return hit.id
            }
            if let hit = profiles.first(where: { $0.agent == agent && $0.isOfficial }) {
                return hit.id
            }
            return profiles.first(where: { $0.agent == agent && $0.isDefault })?.id
        }

        let key = (live.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = profiles.filter { profile in
            profile.agent == agent && endpointsMatch(profile.endpoint, endpoint, agent: agent)
        }
        let exact = key.isEmpty ? [] : candidates.filter { $0.apiKey == key }
        let pool = exact.isEmpty ? candidates : exact

        if let current, pool.contains(where: { $0.id == current }) {
            return current
        }
        // Fall back to the model actually written to the file before giving up on ordering.
        let liveModel = (live.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !liveModel.isEmpty, let hit = pool.first(where: { $0.model == liveModel }) {
            return hit.id
        }
        return pool.first?.id
    }

    static func importAsProfile(agent: AgentKind) -> AgentProviderProfile? {
        let live = read(agent: agent)
        guard let endpoint = live.endpoint?.trimmingCharacters(in: .whitespacesAndNewlines), !endpoint.isEmpty
        else { return nil }
        let key = (live.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let now = Date()
        return AgentProviderProfile(
            id: UUID().uuidString,
            agent: agent,
            name: "从 live 导入",
            endpoint: endpoint,
            apiKey: key,
            model: live.model ?? "",
            fastModel: live.fastModel ?? "",
            webSearchModel: live.webSearchModel ?? "",
            modelMappings: live.modelMappings,
            catalogModels: live.catalogModels,
            modelOverrides: live.modelOverrides,
            reasoningEffort: live.reasoningEffort ?? "",
            isLocalCPA: false,
            isDefault: false,
            notes: "Imported from \(agent.liveConfigPathHint)",
            createdAt: now,
            updatedAt: now
        )
    }

    // MARK: - Readers

    private static func readClaude() -> Snapshot {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["env"] as? [String: Any]
        else { return Snapshot(configExists: exists) }
        var mappings: [String: String] = [:]
        for (role, key) in [
            (AgentModelRole.sonnet, "ANTHROPIC_DEFAULT_SONNET_MODEL"),
            (.opus, "ANTHROPIC_DEFAULT_OPUS_MODEL"),
            (.haiku, "ANTHROPIC_DEFAULT_HAIKU_MODEL"),
            (.fable, "ANTHROPIC_DEFAULT_FABLE_MODEL"),
            (.subagent, "CLAUDE_CODE_SUBAGENT_MODEL"),
        ] {
            if let value = env[key] as? String, !value.isEmpty {
                mappings[role.rawValue] = value
            }
        }
        return Snapshot(
            configExists: true,
            endpoint: env["ANTHROPIC_BASE_URL"] as? String,
            apiKey: env["ANTHROPIC_AUTH_TOKEN"] as? String,
            model: env["ANTHROPIC_MODEL"] as? String,
            fastModel: (env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] as? String)
                ?? (env["ANTHROPIC_SMALL_FAST_MODEL"] as? String),
            modelMappings: mappings,
            reasoningEffort: AgentLiveConfigWriter.readClaudeEffort(from: json)
        )
    }

    private static func readCodex() -> Snapshot {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
        let exists = FileManager.default.fileExists(atPath: configURL.path)
        let text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let providerID = TOMLEdit.value(text, table: nil, key: "model_provider")
        let providerTable = providerID.map { "model_providers." + TOMLEdit.quoteTableComponent($0) }
        let baseURL = providerTable.flatMap { TOMLEdit.value(text, table: $0, key: "base_url") }
            ?? TOMLEdit.value(text, table: nil, key: "openai_base_url")
        let model = TOMLEdit.value(text, table: nil, key: "model")

        var apiKey = providerTable.flatMap {
            TOMLEdit.value(text, table: $0, key: "experimental_bearer_token")
        } ?? TOMLEdit.value(text, table: nil, key: "experimental_bearer_token")
        if apiKey == nil {
            let authURL = configURL.deletingLastPathComponent().appendingPathComponent("auth.json")
            if let data = try? Data(contentsOf: authURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                apiKey = (json["OPENAI_API_KEY"] as? String)
                    ?? (json["tokens"] as? [String: Any])?["access_token"] as? String
            }
        }
        // `/model` in Codex lists the external catalog, not `model` alone — import it too or the
        // re-created profile would silently drop every model but the default one.
        var catalog = CodexModelCatalogWriter.ParsedCatalog()
        if let path = TOMLEdit.value(text, table: nil, key: "model_catalog_json"),
           let parsed = CodexModelCatalogWriter.readCatalog(
               pathFromConfig: path,
               configDirectory: configURL.deletingLastPathComponent()
           )
        {
            catalog = parsed
        }
        return Snapshot(
            configExists: exists,
            endpoint: baseURL,
            apiKey: apiKey,
            model: model,
            reasoningEffort: TOMLEdit.value(text, table: nil, key: "model_reasoning_effort"),
            catalogModels: catalog.modelIDs,
            modelOverrides: catalog.overrides
        )
    }

    // MARK: - Helpers

    private static func firstTOMLValue(in text: String, key: String) -> String? {
        // Prefer values inside MacCLIProxyAPI managed block when present.
        if let managed = managedBlock(in: text),
           let value = matchTOML(key: key, in: managed)
        {
            return value
        }
        return matchTOML(key: key, in: text)
    }

    private static func managedBlock(in text: String) -> String? {
        guard let start = text.range(of: "# BEGIN MacCLIProxyAPI"),
              let end = text.range(of: "# END MacCLIProxyAPI"),
              start.upperBound < end.lowerBound
        else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }

    private static func matchTOML(key: String, in text: String) -> String? {
        let pattern = #"^\s*"# + NSRegularExpression.escapedPattern(for: key) + #"\s*=\s*"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text)
        else { return nil }
        let value = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func normalizeComparableEndpoint(_ endpoint: String, agent: AgentKind) -> String {
        var e = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while e.hasSuffix("/") { e.removeLast() }
        switch agent {
        case .claude:
            if e.hasSuffix("/v1") { e = String(e.dropLast(3)) }
            while e.hasSuffix("/") { e.removeLast() }
        case .codex:
            if !e.hasSuffix("/v1") { e += "/v1" }
        }
        return e
    }

    /// True when two endpoints target the same upstream for this agent.
    static func endpointsMatch(_ lhs: String, _ rhs: String, agent: AgentKind) -> Bool {
        normalizeComparableEndpoint(lhs, agent: agent)
            == normalizeComparableEndpoint(rhs, agent: agent)
    }
}
