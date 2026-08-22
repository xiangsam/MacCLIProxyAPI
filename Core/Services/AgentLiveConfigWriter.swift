import Foundation

/// Writes live agent configs for Claude Code / Codex.
enum AgentLiveConfigWriter {
    static func enable(_ profile: AgentProviderProfile, settings: AgentSettings) throws {
        if profile.isDefault {
            try AgentDefaultSnapshot.restore(agent: profile.agent)
            if profile.agent == .codex, settings.unifyCodexSessionHistory {
                try repinOfficialCodexBucket()
            }
            return
        }
        // First non-default enable: snapshot current live as 「默认」 so user can switch back.
        try AgentDefaultSnapshot.captureIfNeeded(agent: profile.agent)

        switch profile.agent {
        case .claude:
            try writeClaude(profile)
        case .codex:
            try writeCodex(profile, settings: settings)
        }
    }

    /// `model_provider` currently in the live Codex config, or nil when unset.
    ///
    /// Used to verify a write actually landed before reporting success to the user.
    static func codexLiveProviderID() -> String? {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        return TOMLEdit.value(text, table: nil, key: "model_provider")
    }

    /// Put a just-restored 「默认」 Codex config back into the stable `custom` bucket.
    ///
    /// The snapshot is replayed byte for byte, which is the point of 「默认」 — but a config
    /// taken before we ever touched it names no provider at all, so Codex falls back to its
    /// built-in `openai` bucket and every session started from 「默认」 lands outside the
    /// unified history the user asked for.
    ///
    /// Only the official backend is re-pinned. A snapshot naming a third-party provider is
    /// left exactly as captured: rehoming it would point that provider's traffic at a bucket
    /// it never wrote to.
    ///
    /// Returns true when the file was rewritten. False means there was nothing to do — either
    /// already pinned, or a config we must not touch; `canRepinOfficialCodexBucket()` tells the
    /// two apart before offering the action.
    @discardableResult
    static func repinOfficialCodexBucket() throws -> Bool {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
        let text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        guard let repinned = repinningOfficialCodexBucket(in: text) else { return false }
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try repinned.write(to: configURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        return true
    }

    /// Whether the live config is an official-backend one we may move into the `custom` bucket.
    static func canRepinOfficialCodexBucket() -> Bool {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
        let text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        return repinningOfficialCodexBucket(in: text) != nil
    }

    /// Rewrite `text` so the official backend is reached through `custom`, or nil to leave it be.
    ///
    /// Mirrors cc-switch's `codex_official_provider_table`: `requires_openai_auth` keeps auth on
    /// the ChatGPT login in `auth.json` and makes the omitted `base_url` default back to the
    /// official Codex backend, `name = "OpenAI"` keeps the official feature gates (remote
    /// compaction, web search) matching, and `supports_websockets` restores a default that
    /// custom entries otherwise lose.
    static func repinningOfficialCodexBucket(in text: String) -> String? {
        let current = TOMLEdit.value(text, table: nil, key: "model_provider")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard current.isEmpty || current == "openai" else { return nil }

        let providerTable = "model_providers.\(CodexStableProvider.id)"
        var next = TOMLEdit.setString(text, table: nil, key: "model_provider", value: CodexStableProvider.id)
        next = TOMLEdit.removeTable(next, name: providerTable)
        next = TOMLEdit.setString(
            next,
            table: providerTable,
            key: "name",
            value: CodexStableProvider.openAIProviderName
        )
        next = TOMLEdit.setRaw(next, table: providerTable, key: "requires_openai_auth", literal: "true")
        next = TOMLEdit.setRaw(next, table: providerTable, key: "supports_websockets", literal: "true")
        next = TOMLEdit.setString(next, table: providerTable, key: "wire_api", value: "responses")
        return next
    }

    // MARK: - Claude

    static func writeClaude(_ profile: AgentProviderProfile) throws {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing = try? Data(contentsOf: settingsURL)
        let data = try mergeClaude(existingJSON: existing, profile: profile)
        try backupIfExists(settingsURL, stamp: "claude")
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Merge provider-owned Claude env keys into an existing settings.json document.
    static func mergeClaude(existingJSON: Data?, profile: AgentProviderProfile) throws -> Data {
        var root: [String: Any] = [:]
        if let data = existingJSON,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            root = json
        }
        var env = (root["env"] as? [String: Any]) ?? [:]
        // cc-switch treats these as provider-owned core keys: clear stale values first.
        root.removeValue(forKey: "apiBaseUrl")
        root.removeValue(forKey: "primaryModel")
        root.removeValue(forKey: "smallFastModel")
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_REASONING_MODEL")
        env.removeValue(forKey: "ANTHROPIC_SMALL_FAST_MODEL")

        let mapping: [(AgentModelRole, String)] = [
            (.main, "ANTHROPIC_MODEL"),
            (.sonnet, "ANTHROPIC_DEFAULT_SONNET_MODEL"),
            (.opus, "ANTHROPIC_DEFAULT_OPUS_MODEL"),
            (.haiku, "ANTHROPIC_DEFAULT_HAIKU_MODEL"),
            (.fable, "ANTHROPIC_DEFAULT_FABLE_MODEL"),
            (.subagent, "CLAUDE_CODE_SUBAGENT_MODEL"),
        ]

        if profile.isOfficial {
            env.removeValue(forKey: "ANTHROPIC_BASE_URL")
            env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
            for (role, key) in mapping {
                env.removeValue(forKey: key)
                if let nameKey = role.claudeDisplayNameKey(for: .claude) {
                    env.removeValue(forKey: nameKey)
                }
            }
            root.removeValue(forKey: "effortLevel")
            env.removeValue(forKey: "CLAUDE_CODE_EFFORT_LEVEL")
        } else {
            let endpoint = profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            if endpoint.isEmpty {
                env.removeValue(forKey: "ANTHROPIC_BASE_URL")
            } else {
                env["ANTHROPIC_BASE_URL"] = endpoint
            }
            let key = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
            } else {
                env["ANTHROPIC_AUTH_TOKEN"] = key
            }

            for (role, key) in mapping {
                var trimmed = profile.model(for: role).trimmingCharacters(in: .whitespacesAndNewlines)
                if !role.supportsOneMContext(for: .claude) {
                    trimmed = ClaudeContextMarker.stripOneM(trimmed)
                }
                let nameKey = role.claudeDisplayNameKey(for: .claude)
                if trimmed.isEmpty {
                    env.removeValue(forKey: key)
                    if let nameKey { env.removeValue(forKey: nameKey) }
                    continue
                }
                env[key] = trimmed
                // Without a *_NAME the `[1M]` suffix leaks into Claude Code's model picker.
                if let nameKey {
                    if ClaudeContextMarker.hasOneM(trimmed) {
                        env[nameKey] = ClaudeContextMarker.stripOneM(trimmed)
                    } else {
                        env.removeValue(forKey: nameKey)
                    }
                }
            }

            applyClaudeEffort(to: &root, env: &env, effort: profile.reasoningEffort)
        }

        root["env"] = env
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Only writes when `effort` is non-empty. Empty leaves the user's Claude-side setting alone.
    static func applyClaudeEffort(
        to root: inout [String: Any],
        env: inout [String: Any],
        effort: String
    ) {
        let trimmed = effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return }
        root.removeValue(forKey: "effortLevel")
        env.removeValue(forKey: "CLAUDE_CODE_EFFORT_LEVEL")
        if trimmed == "max" {
            env["CLAUDE_CODE_EFFORT_LEVEL"] = "max"
            return
        }
        root["effortLevel"] = trimmed
    }

    /// Read Claude effort from live settings (env max wins over effortLevel).
    static func readClaudeEffort(from root: [String: Any]) -> String? {
        let env = root["env"] as? [String: Any] ?? [:]
        if let max = env["CLAUDE_CODE_EFFORT_LEVEL"] as? String,
           max.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "max"
        {
            return "max"
        }
        if let level = root["effortLevel"] as? String {
            let trimmed = level.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    // MARK: - Codex

    /// Writes `~/.codex/config.toml`. The live config targets the stable `custom` bucket (or official OpenAI).
    static func writeCodex(
        _ profile: AgentProviderProfile,
        catalogModels: [String]? = nil,
        settings: AgentSettings = .default
    ) throws {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try backupIfExists(configURL, stamp: "codex")

        var text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let modelIDs = CodexModelCatalogWriter.resolveModelIDs(profile: profile, explicit: catalogModels)
        // Only the local CPA's config.yaml is safe to read directly; a remote profile's upstream
        // routing is out of reach here, so every one of its models falls back to the .proxyChat
        // profile (this function's pre-routing-aware behavior).
        let routingLegs: [String: AgentModelCatalogService.CoreRoutingLeg] = profile.isLocalCPA
            ? AgentModelCatalogService.coreRoutingLegs(from: AppPaths.coreConfigURL)
            : [:]
        text = mergeCodex(
            existingText: text,
            profile: profile,
            catalogModelIDs: modelIDs,
            routingLegs: routingLegs,
            unifySessionHistory: settings.unifyCodexSessionHistory
        )
        try text.write(to: configURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)

        if profile.isOfficial || modelIDs.isEmpty {
            CodexModelCatalogWriter.removeLocalCatalogIfOurs()
        } else {
            try CodexModelCatalogWriter.writeLocalCatalog(
                modelIDs: modelIDs,
                overrides: profile.modelOverrides,
                routingLegs: routingLegs
            )
        }
    }

    /// Replace Codex provider-owned keys while preserving unrelated TOML.
    ///
    /// When `catalogModelIDs` is non-empty, points `model_catalog_json` at our catalog inside
    /// `catalogDirectory`. Codex rejects a relative value ("AbsolutePathBuf deserialized without
    /// a base path"), so the directory must be absolute — for a remote host that means its real
    /// home directory, not `$HOME`, since Codex reads the value literally.
    static func mergeCodex(
        existingText: String,
        profile: AgentProviderProfile,
        catalogModelIDs: [String]? = nil,
        catalogDirectory: String = CodexModelCatalogWriter.localDirectory.path,
        routingLegs: [String: AgentModelCatalogService.CoreRoutingLeg] = [:],
        unifySessionHistory: Bool = true
    ) -> String {
        var text = stripManagedBlock(from: existingText)

        if profile.isOfficial {
            // Remove our model catalog pointer if it points to maccliproxy-model-catalog.json
            if let current = TOMLEdit.value(text, table: nil, key: "model_catalog_json"),
               (current as NSString).lastPathComponent == CodexModelCatalogWriter.filename
                || current == CodexModelCatalogWriter.filename
            {
                text = TOMLEdit.removeKey(text, table: nil, key: "model_catalog_json")
            }
            if TOMLEdit.value(text, table: nil, key: "web_search") == codexWebSearchDisabledSentinel {
                text = TOMLEdit.removeKey(text, table: nil, key: "web_search")
            }
            let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if model.isEmpty {
                text = TOMLEdit.removeKey(text, table: nil, key: "model")
            } else {
                text = TOMLEdit.setString(text, table: nil, key: "model", value: model)
            }
            let effort = profile.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
            if effort.isEmpty {
                text = TOMLEdit.removeKey(text, table: nil, key: "model_reasoning_effort")
            } else {
                text = TOMLEdit.setString(text, table: nil, key: "model_reasoning_effort", value: effort)
            }

            let providerTable = "model_providers.\(CodexStableProvider.id)"
            if unifySessionHistory {
                text = TOMLEdit.setString(text, table: nil, key: "model_provider", value: CodexStableProvider.id)
                text = TOMLEdit.removeTable(text, name: providerTable)
                text = TOMLEdit.setString(
                    text,
                    table: providerTable,
                    key: "name",
                    value: CodexStableProvider.openAIProviderName
                )
                text = TOMLEdit.setRaw(text, table: providerTable, key: "requires_openai_auth", literal: "true")
                text = TOMLEdit.setRaw(text, table: providerTable, key: "supports_websockets", literal: "true")
                text = TOMLEdit.setString(text, table: providerTable, key: "wire_api", value: "responses")
            } else {
                if TOMLEdit.value(text, table: nil, key: "model_provider") == CodexStableProvider.id {
                    text = TOMLEdit.removeKey(text, table: nil, key: "model_provider")
                }
                text = TOMLEdit.removeTable(text, name: providerTable)
            }
            text = replaceCatalogRevStamp(in: text)
            return text
        }

        // Live config always lands in the shared `custom` bucket so switching upstreams
        // does not fragment history.
        let providerID = CodexStableProvider.id
        let endpoint = normalizeOpenAIBase(profile.endpoint)
        let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = profile.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)

        text = TOMLEdit.setString(text, table: nil, key: "model_provider", value: providerID)
        if model.isEmpty {
            text = TOMLEdit.removeKey(text, table: nil, key: "model")
        } else {
            text = TOMLEdit.setString(text, table: nil, key: "model", value: model)
        }
        if !effort.isEmpty {
            text = TOMLEdit.setString(text, table: nil, key: "model_reasoning_effort", value: effort)
        }
        // Empty effort: leave whatever the user set inside Codex alone.

        let catalogIDs = catalogModelIDs ?? CodexModelCatalogWriter.resolveModelIDs(profile: profile)
        if catalogIDs.isEmpty {
            // Only remove our owned pointer; leave a user/cc-switch catalog path alone if different.
            if let current = TOMLEdit.value(text, table: nil, key: "model_catalog_json"),
               (current as NSString).lastPathComponent == CodexModelCatalogWriter.filename
                || current == CodexModelCatalogWriter.filename
            {
                text = TOMLEdit.removeKey(text, table: nil, key: "model_catalog_json")
            }
        } else {
            text = TOMLEdit.setString(
                text,
                table: nil,
                key: "model_catalog_json",
                value: CodexModelCatalogWriter.catalogPath(inDirectory: catalogDirectory)
            )
        }

        let providerTable = "model_providers.\(providerID)"
        text = TOMLEdit.removeTable(text, name: providerTable)
        // Codex gates remote compaction on `name == "OpenAI"` and nothing else
        // (`ProviderCapabilities::remote_compaction` ← `ModelProviderInfo::is_openai`).
        text = TOMLEdit.setString(
            text,
            table: providerTable,
            key: "name",
            value: profile.claimsOpenAIProvider ? CodexStableProvider.openAIProviderName : profile.name
        )
        text = TOMLEdit.setString(text, table: providerTable, key: "base_url", value: endpoint)
        // Codex agent always speaks Responses to the local proxy (`wire_api = "responses"`);
        // for an `openai-compatibility` provider the proxy converts ↔ Chat Completions.
        text = TOMLEdit.setString(text, table: providerTable, key: "wire_api", value: "responses")
        text = TOMLEdit.setRaw(text, table: providerTable, key: "requires_openai_auth", literal: "true")
        text = TOMLEdit.setString(
            text,
            table: providerTable,
            key: "experimental_bearer_token",
            value: profile.apiKey
        )
        if !model.isEmpty {
            let leg = routingLegs[model]
            let toolProfile = CodexModelCatalogWriter.CodexCatalogToolProfile.resolve(leg)
            let disableWebSearch = CodexModelCatalogWriter.shouldDisableWebSearch(
                activeModelID: model,
                profile: toolProfile,
                routingLeg: leg
            )
            text = setCodexNativeWebSearchField(text, disable: disableWebSearch)
        }

        // Bump a comment stamp so saving the same provider with only catalog/override
        // changes still mutates config.toml (helps Codex reload model_catalog_json).
        text = replaceCatalogRevStamp(in: text)
        return text
    }

    /// CPA's own sentinel for the top-level `web_search` field: writing `web_search =
    /// "disabled"` turns off Codex's built-in web-search hosted tool; clearing only ever removes
    /// a value that equals this sentinel, so switching to a web-search-capable model re-enables
    /// Codex's default without clobbering a user's own manual setting. Mirrors cc-switch's
    /// `set_codex_native_web_search_field`.
    private static let codexWebSearchDisabledSentinel = "disabled"

    private static func setCodexNativeWebSearchField(_ text: String, disable: Bool) -> String {
        if disable {
            return TOMLEdit.setString(
                text,
                table: nil,
                key: "web_search",
                value: codexWebSearchDisabledSentinel
            )
        }
        if TOMLEdit.value(text, table: nil, key: "web_search") == codexWebSearchDisabledSentinel {
            return TOMLEdit.removeKey(text, table: nil, key: "web_search")
        }
        return text
    }

    /// Replace or append `# maccliproxy-catalog-rev = <unix>`.
    private static func replaceCatalogRevStamp(in text: String) -> String {
        let pattern = #"(?m)^#\s*maccliproxy-catalog-rev\s*=\s*.*$\n?"#
        var result = text
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        let stamp = "# maccliproxy-catalog-rev = \(Int(Date().timeIntervalSince1970))\n"
        if let providerRange = result.range(of: "[model_providers.") {
            // Rewriting the provider table drops it and re-appends it behind a blank
            // separator, but the stamp then moves back above the table and orphans that
            // blank — left alone the file grows a line on every single save. Pin the gap
            // at one blank line, which also drains whatever earlier saves piled up.
            var head = String(result[..<providerRange.lowerBound])
            while head.hasSuffix("\n\n\n") { head.removeLast() }
            return head + stamp + String(result[providerRange.lowerBound...])
        }
        if result.isEmpty || result.hasSuffix("\n") {
            return result + stamp
        }
        return result + "\n" + stamp
    }

    // MARK: - Helpers

    private static func stripManagedBlock(from text: String) -> String {
        let start = "# BEGIN MacCLIProxyAPI"
        let end = "# END MacCLIProxyAPI"
        var result = text
        while let s = result.range(of: start), let e = result.range(of: end) {
            let from = s.lowerBound
            var to = e.upperBound
            if to < result.endIndex, result[to] == "\n" {
                to = result.index(after: to)
            }
            result.removeSubrange(from..<to)
        }
        return result
    }

    private static func normalizeOpenAIBase(_ endpoint: String) -> String {
        var e = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while e.hasSuffix("/") { e.removeLast() }
        if !e.hasSuffix("/v1") {
            e += "/v1"
        }
        return e
    }

    private static func backupIfExists(_ url: URL, stamp: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try AppPaths.ensureBaseDirectories()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let dir = AppPaths.agentBackupsDirectory
            .appendingPathComponent("\(stamp)-\(formatter.string(from: Date()))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: url, to: dest)
    }
}
