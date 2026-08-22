import Foundation

/// Writes Codex's external model catalog (cc-switch equivalent of
/// `cc-switch-model-catalog.json`) so Codex Desktop / `/model` can list third-party models.
///
/// Catalog-entry shaping is ported from cc-switch's `codex_config.rs`
/// (github.com/farion1231/cc-switch) — see `CodexCatalogToolProfile` below, and
/// `scripts/sync-cc-switch-codex-catalog.sh` for pulling in cc-switch updates.
enum CodexModelCatalogWriter {
    /// Basename of the catalog written next to `config.toml`.
    static let filename = "maccliproxy-model-catalog.json"

    /// Directory holding the local Codex config and catalog.
    static var localDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
    }

    static var localURL: URL {
        localDirectory.appendingPathComponent(filename)
    }

    /// Absolute catalog path for `model_catalog_json`; Codex rejects relative values.
    static func catalogPath(inDirectory directory: String) -> String {
        (directory as NSString).appendingPathComponent(filename)
    }

    // MARK: - Tool profile

    /// Which Codex tool surface a model's catalog entry may declare. Ported from cc-switch's
    /// `CodexCatalogToolProfile`, adapted to this app's routing: cc-switch resolves one profile
    /// per Codex *provider* (one `model_providers.X` block, one `wire_api`); this app multiplexes
    /// every model through a single `model_providers.custom` pointed at CPA, so the profile is
    /// resolved per *model* instead, from which CPA `config.yaml` section currently serves it.
    ///
    /// - `.proxyChat`: CPA translates Responses<->Chat Completions itself (the
    ///   `openai-compatibility` section), so the catalog keeps Codex's default tool set
    ///   (including the freeform `apply_patch` custom tool and `tool_mode`) — CPA's own
    ///   translator rewrites custom<->function tools on the way through.
    /// - `.nativeResponses`: Codex talks straight to a provider's native `/responses` endpoint
    ///   (the `codex-api-key` section, zero translation). Most such gateways reject
    ///   `type=="custom"` tools and don't implement Codex's `tool_mode: code_mode_only` code-mode
    ///   protocol, so the catalog must suppress them and rely on `shell_type="shell_command"`
    ///   for edits.
    /// - `.anthropic`: kept for structural parity with cc-switch (a Codex session bridged to a
    ///   native Anthropic Messages gateway). This app has no such bridge today, so `resolve`
    ///   below never produces it; it exists so a future bridge only needs a resolver case, not a
    ///   new enum member.
    enum CodexCatalogToolProfile: Equatable {
        case proxyChat
        case nativeResponses
        case anthropic

        static func resolve(_ leg: AgentModelCatalogService.CoreRoutingLeg?) -> CodexCatalogToolProfile {
            switch leg {
            case .none, .openAICompatibility:
                return .proxyChat
            case .codexAPIKeyNative:
                return .nativeResponses
            }
        }
    }

    // MARK: - web_search compatibility

    /// Native `/responses` gateways whose first-party models do NOT support Codex's built-in
    /// `web_search` hosted tool. A BLACKLIST (default-on): everything not listed keeps Codex's
    /// default, so relays/aggregators fronting real GPT — and any unknown provider — are never
    /// touched. Ported verbatim from cc-switch's `CODEX_WEB_SEARCH_REJECT_HOSTS` (verified
    /// 2026-06-28 doc audit there: MiMo hard-400s, LongCat's official config ships
    /// `web_search = "disabled"`, MiniMax's tool-type enum is `['function']` only).
    private static let webSearchRejectHosts: [String] = [
        "xiaomimimo.com", // Xiaomi MiMo (api.xiaomimimo.com, token-plan-cn.xiaomimimo.com)
        "longcat.chat", // Meituan LongCat (api.longcat.chat)
        "minimax.io", // MiniMax global (api.minimax.io)
        "minimaxi.com", // MiniMax CN (api.minimaxi.com)
    ]

    /// Brand prefixes of models whose native gateways reject `web_search`, matched against the
    /// model id's last `/`-segment so an aggregator id like `MiniMaxAI/MiniMax-M3` is caught.
    /// Ported verbatim from cc-switch's `CODEX_WEB_SEARCH_REJECT_MODEL_PREFIXES`.
    private static let webSearchRejectModelPrefixes: [String] = ["mimo", "longcat", "minimax", "qwen3-coder"]

    /// Whether a `.nativeResponses` model's gateway is known to reject Codex's `web_search`
    /// hosted tool — by base-url host OR by the model's brand (so an aggregator fronting a
    /// reject vendor's model is caught too). Mirrors cc-switch's
    /// `codex_native_gateway_rejects_web_search`.
    static func nativeGatewayRejectsWebSearch(modelID: String, baseURL: String) -> Bool {
        let host = baseURL.lowercased()
        if webSearchRejectHosts.contains(where: { host.contains($0) }) {
            return true
        }
        let normalizedModel = modelID.lowercased()
        let tail = normalizedModel.split(separator: "/").last.map(String.init) ?? normalizedModel
        return webSearchRejectModelPrefixes.contains { tail.hasPrefix($0) }
    }

    /// Whether Codex's built-in `web_search` hosted tool should be disabled for the current
    /// active model. Mirrors the `disable_web_search` dispatch inside cc-switch's
    /// `prepare_codex_config_text_with_model_catalog`.
    static func shouldDisableWebSearch(
        activeModelID: String,
        profile: CodexCatalogToolProfile,
        routingLeg: AgentModelCatalogService.CoreRoutingLeg?
    ) -> Bool {
        switch profile {
        case .anthropic:
            // The Responses->Anthropic transform silently drops the Codex web_search hosted
            // tool, so always disable it rather than present a dead tool. This app has no such
            // bridge today, so this branch is unreachable in practice.
            return true
        case .nativeResponses:
            guard case let .codexAPIKeyNative(baseURL)? = routingLeg else { return false }
            return nativeGatewayRejectsWebSearch(modelID: activeModelID, baseURL: baseURL)
        case .proxyChat:
            return false
        }
    }

    // MARK: - Build / write

    /// Build `{ "models": [ ... ] }` JSON for the given model ids.
    ///
    /// `routingLegs` (model id -> which config.yaml section currently serves it) drives the
    /// per-model tool profile — pass `AgentModelCatalogService.coreRoutingLegs(from:)` for a live
    /// build. Omitted (the default), every id resolves to `.proxyChat`, i.e. today's behavior
    /// for callers/tests with no routing information available.
    static func buildCatalogJSON(
        modelIDs: [String],
        overrides: [String: AgentModelOverride] = [:],
        defaultContextWindow: Int = 128_000,
        routingLegs: [String: AgentModelCatalogService.CoreRoutingLeg] = [:]
    ) throws -> Data {
        let ids = uniqueNonEmpty(modelIDs)
        guard !ids.isEmpty else {
            throw AppError("Codex model catalog 需要至少一个模型 id")
        }
        var entries: [[String: Any]] = []
        for (index, id) in ids.enumerated() {
            let override = override(for: id, in: overrides)
            let context = AgentReasoningEffort.resolveContextWindow(
                modelID: id,
                override: override?.contextWindow,
                fallback: defaultContextWindow
            )
            let leg = routingLegs[id]
            entries.append(
                entry(
                    modelID: id,
                    profile: CodexCatalogToolProfile.resolve(leg),
                    routingLeg: leg,
                    priority: index,
                    contextWindow: context,
                    reasoningOverride: override?.reasoningLevels
                )
            )
        }
        let root: [String: Any] = ["models": entries]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Write catalog beside `~/.codex/config.toml`. Returns the catalog basename.
    @discardableResult
    static func writeLocalCatalog(
        modelIDs: [String],
        overrides: [String: AgentModelOverride] = [:],
        defaultContextWindow: Int = 128_000,
        routingLegs: [String: AgentModelCatalogService.CoreRoutingLeg] = [:]
    ) throws -> String {
        let data = try buildCatalogJSON(
            modelIDs: modelIDs,
            overrides: overrides,
            defaultContextWindow: defaultContextWindow,
            routingLegs: routingLegs
        )
        let dir = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: localURL, options: .atomic)
        return filename
    }

    struct ParsedCatalog: Equatable, Sendable {
        var modelIDs: [String] = []
        var overrides: [String: AgentModelOverride] = [:]
    }

    /// Parse a catalog written by us (or by Codex itself) back into editable model ids + overrides.
    ///
    /// Only values that differ from what we would derive automatically become overrides, so a
    /// round-trip through the editor does not freeze today's defaults into the profile.
    static func parseCatalog(_ data: Data) -> ParsedCatalog {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = json["models"] as? [[String: Any]]
        else { return ParsedCatalog() }

        var parsed = ParsedCatalog()
        for entry in models {
            guard
                let slug = (entry["slug"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !slug.isEmpty,
                !parsed.modelIDs.contains(slug)
            else { continue }
            parsed.modelIDs.append(slug)

            var override = AgentModelOverride()
            if let context = entry["context_window"] as? Int,
               context > 0,
               context != AgentReasoningEffort.resolveContextWindow(modelID: slug, override: nil)
            {
                override.contextWindow = context
            }
            if let rows = entry["supported_reasoning_levels"] as? [[String: Any]] {
                let levels = AgentReasoningEffort.sanitizeLevels(
                    rows.compactMap { $0["effort"] as? String }
                )
                if levels != AgentReasoningEffort.options(agent: .codex, modelID: slug) {
                    override.reasoningLevels = levels
                }
            }
            if !override.isEmpty {
                parsed.overrides[slug] = override
            }
        }
        return parsed
    }

    /// Read whatever `model_catalog_json` points at, resolving relative paths like Codex does.
    static func readCatalog(pathFromConfig raw: String, configDirectory: URL) -> ParsedCatalog? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : configDirectory.appendingPathComponent(expanded)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let parsed = parseCatalog(data)
        return parsed.modelIDs.isEmpty ? nil : parsed
    }

    static func removeLocalCatalogIfOurs() {
        let url = localURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Collect model ids for catalog: explicit list, else profile catalog/default, else CPA fetch.
    static func resolveModelIDs(
        profile: AgentProviderProfile,
        explicit: [String]? = nil
    ) -> [String] {
        if let explicit {
            let ids = uniqueNonEmpty(explicit)
            if !ids.isEmpty { return ids }
        }
        let fromProfile = profile.resolvedCodexCatalogModels
        if !fromProfile.isEmpty { return fromProfile }
        // Best-effort: pull from CPA so `/model` isn't empty when user left model blank.
        if let fetched = try? fetchModelIDsSync(endpoint: profile.endpoint, apiKey: profile.apiKey),
           !fetched.isEmpty
        {
            return fetched
        }
        return []
    }

    // MARK: - Per-model entry dispatch

    /// Build one model's catalog entry, mirroring cc-switch's `codex_model_catalog_from_settings`
    /// dispatch: an official vendor catalog wins for its host, otherwise fall back to the generic
    /// per-profile template.
    private static func entry(
        modelID: String,
        profile: CodexCatalogToolProfile,
        routingLeg: AgentModelCatalogService.CoreRoutingLeg?,
        priority: Int,
        contextWindow: Int,
        reasoningOverride: [String]?
    ) -> [String: Any] {
        if let vendorTemplate = officialVendorTemplate(modelID: modelID, profile: profile, routingLeg: routingLeg) {
            return makeVendorEntry(
                from: vendorTemplate,
                modelID: modelID,
                priority: priority,
                contextWindow: contextWindow,
                reasoningOverride: reasoningOverride
            )
        }
        return makeGenericEntry(
            from: genericTemplate(for: profile),
            modelID: modelID,
            profile: profile,
            priority: priority,
            contextWindow: contextWindow,
            reasoningOverride: reasoningOverride
        )
    }

    // MARK: - Official vendor catalogs

    /// Hosts whose native `/responses` gateway publishes an OFFICIAL Codex model catalog that
    /// this app mirrors verbatim, keyed to the bundled resource carrying it. Ported from
    /// cc-switch's `CODEX_DEEPSEEK_OFFICIAL_CATALOG_HOSTS`. Matched by `base-url` ONLY, never by
    /// model id/brand — the official entries GRANT capabilities (freeform `apply_patch`, vendor
    /// harness) that an aggregator merely hosting the same model name may not actually honor; the
    /// safe failure direction for an aggregator is the neutral generic template.
    private static let officialVendorCatalogHosts: [(host: String, resource: String)] = [
        ("deepseek.com", "codex_deepseek_catalog_template"),
    ]

    /// The official vendor entry for `modelID`, if its `codex-api-key` base-url matches a known
    /// vendor host. Only the `.nativeResponses` profile qualifies — ProxyChat runs through CPA's
    /// own converter (the generic template contract) regardless of upstream.
    private static func officialVendorTemplate(
        modelID: String,
        profile: CodexCatalogToolProfile,
        routingLeg: AgentModelCatalogService.CoreRoutingLeg?
    ) -> [String: Any]? {
        guard profile == .nativeResponses,
              case let .codexAPIKeyNative(baseURL)? = routingLeg
        else { return nil }
        let host = baseURL.lowercased()
        guard let resource = officialVendorCatalogHosts.first(where: { host.contains($0.host) })?.resource
        else { return nil }
        guard let models = loadBundledModelsArray(resource), !models.isEmpty else { return nil }
        let matched = models.first {
            ($0["slug"] as? String)?.caseInsensitiveCompare(modelID) == .orderedSame
        }
        // Unknown id under a known vendor host clones the vendor's first (flagship) entry, so it
        // keeps the gateway's real capability profile instead of impersonating the flagship's
        // own identity — matches cc-switch's `codex_vendor_catalog_model_entry`.
        return matched ?? models[0]
    }

    /// Overlay this app's per-model overrides onto an OFFICIAL vendor catalog entry. The vendor
    /// entry is authoritative for protocol-compatibility fields (`tool_mode`,
    /// `apply_patch_tool_type`, `input_modalities`, `base_instructions`, ...) — nothing here ever
    /// strips a vendor-declared field, mirroring cc-switch's `codex_vendor_catalog_model_entry`.
    /// Context window and reasoning levels still come from this app's own override system
    /// (`AgentModelOverride` / the model editor UI), which cc-switch has no equivalent of.
    private static func makeVendorEntry(
        from template: [String: Any],
        modelID: String,
        priority: Int,
        contextWindow: Int,
        reasoningOverride: [String]?
    ) -> [String: Any] {
        var entry = template
        entry["slug"] = modelID
        if entry["display_name"] == nil { entry["display_name"] = modelID }
        if entry["description"] == nil { entry["description"] = modelID }
        entry["context_window"] = contextWindow
        entry["max_context_window"] = contextWindow
        entry["priority"] = 1000 + priority
        entry["supported_reasoning_levels"] = AgentReasoningEffort.catalogLevels(
            modelID: modelID,
            override: reasoningOverride
        )
        let levels = AgentReasoningEffort.options(agent: .codex, modelID: modelID, override: reasoningOverride)
        if levels.contains("medium") {
            entry["default_reasoning_level"] = "medium"
        } else if let first = levels.first {
            entry["default_reasoning_level"] = first
        }
        // Defensive: if a future Codex parser requires a field the vendor file predates,
        // backfill only whitelisted parser-required keys — mirrors cc-switch's
        // `fill_template_fields_from_static`.
        return fillParserRequiredFields(entry)
    }

    // MARK: - Generic (non-vendor) templates

    private static func genericTemplate(for profile: CodexCatalogToolProfile) -> [String: Any] {
        switch profile {
        case .nativeResponses, .anthropic:
            // Bundled clean template: no freeform apply_patch/web_search, no tool_mode, no
            // GPT-5 base_instructions — Codex never emits a type=="custom" tool (or treats this
            // model as code-mode-only) that a native gateway would reject. Deliberately NOT
            // models_cache.json here — that would reintroduce gpt-5.5's freeform apply_patch /
            // tool_mode. Mirrors cc-switch's `load_codex_native_responses_template`.
            return loadBundledJSON("codex_native_responses_template") ?? minimalFallbackTemplate()
        case .proxyChat:
            return loadProxyChatTemplate()
        }
    }

    /// ProxyChat trusts CPA's own Responses<->Chat translator to handle whatever tool shape
    /// Codex emits, so — matching cc-switch — it clones a live GPT catalog entry rather than a
    /// hand-audited static one, to automatically pick up new Codex/OpenAI catalog fields.
    private static func loadProxyChatTemplate() -> [String: Any] {
        if let cached = loadTemplateFromModelsCache() {
            return cached
        }
        // cc-switch's next fallback shells out to `codex debug models --bundled`; this app
        // doesn't assume a `codex` CLI is on PATH, so it goes straight to the bundled static
        // gpt-5.5 template cc-switch ships for the same last-resort case.
        return loadBundledJSON("gpt5_5_template") ?? minimalFallbackTemplate()
    }

    private static func loadTemplateFromModelsCache() -> [String: Any]? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = json["models"] as? [[String: Any]],
            !models.isEmpty
        else { return nil }
        // cc-switch pins the exact "gpt-5.5" slug (its `CODEX_MODEL_CATALOG_TEMPLATE_SLUG`);
        // fall back to a looser "gpt-5" match, then the first entry, so an older/newer local
        // cache still yields a template instead of forcing the static bundled fallback.
        if let exact = models.first(where: { ($0["slug"] as? String) == "gpt-5.5" }) {
            return exact
        }
        if let preferred = models.first(where: {
            let slug = ($0["slug"] as? String)?.lowercased() ?? ""
            return slug.contains("gpt-5")
        }) {
            return preferred
        }
        return models[0]
    }

    private static func loadBundledJSON(_ resourceName: String) -> [String: Any]? {
        guard
            let url = Bundle.main.url(forResource: resourceName, withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private static func loadBundledModelsArray(_ resourceName: String) -> [[String: Any]]? {
        loadBundledJSON(resourceName)?["models"] as? [[String: Any]]
    }

    private static func minimalFallbackTemplate() -> [String: Any] {
        [
            "slug": "template",
            "display_name": "template",
            "description": "template",
            "base_instructions": "You are Codex, a coding agent. You and the user share the same workspace and collaborate to achieve the user's goals.",
            "default_reasoning_level": "medium",
            "supported_reasoning_levels": [
                ["effort": "low", "description": "Fast responses with lighter reasoning"],
                ["effort": "medium", "description": "Balances speed and reasoning depth"],
                ["effort": "high", "description": "Greater reasoning depth for complex problems"],
            ],
            "shell_type": "shell_command",
            "visibility": "list",
            "supported_in_api": true,
            "priority": 0,
            "supports_reasoning_summaries": true,
            "default_reasoning_summary": "none",
            "support_verbosity": false,
            "truncation_policy": ["mode": "tokens", "limit": 10_000],
            "supports_parallel_tool_calls": true,
            "supports_image_detail_original": false,
            "context_window": 128_000,
            "max_context_window": 128_000,
            "effective_context_window_percent": 95,
            "experimental_supported_tools": [],
            "supports_search_tool": false,
        ]
    }

    /// Fields Codex's external-catalog parser REQUIRES (no serde/Codable default): when one is
    /// missing Codex rejects the whole catalog file at startup. `base_instructions` is the other
    /// known required field; every template here always carries it. Mirrors cc-switch's
    /// `CODEX_CATALOG_PARSER_REQUIRED_FIELDS` / `fill_template_fields_from_static`.
    private static func fillParserRequiredFields(_ entry: [String: Any]) -> [String: Any] {
        var next = entry
        if next["supports_reasoning_summaries"] == nil {
            next["supports_reasoning_summaries"] = true
        }
        return next
    }

    private static func makeGenericEntry(
        from template: [String: Any],
        modelID: String,
        profile: CodexCatalogToolProfile,
        priority: Int,
        contextWindow: Int,
        reasoningOverride: [String]?
    ) -> [String: Any] {
        var entry = template
        let display = modelID
        entry["slug"] = modelID
        entry["display_name"] = display
        entry["description"] = display
        entry["context_window"] = contextWindow
        entry["max_context_window"] = contextWindow
        entry["priority"] = 1000 + priority
        entry["additional_speed_tiers"] = []
        entry["service_tiers"] = []
        entry["availability_nux"] = NSNull()
        entry["upgrade"] = NSNull()

        // Image support is a model capability, not a tool-profile capability: consult the
        // shared confirmed-text-only registry regardless of profile (matches cc-switch's
        // unconditional `codex_catalog_input_modalities` call). Unknown models fail open so a
        // GPT/relay alias is never declared text-only just because a template had a
        // conservative default.
        switch CodexModelCapabilities.imageInputCapability(model: modelID, modalities: nil) {
        case .unsupported:
            entry["input_modalities"] = ["text"]
        case .supported, .unknown:
            entry["input_modalities"] = ["text", "image"]
        }

        if entry["supports_reasoning_summaries"] == nil {
            entry["supports_reasoning_summaries"] = true
        }
        if entry["base_instructions"] == nil {
            entry["base_instructions"] =
                "You are Codex, a coding agent. You and the user share the same workspace and collaborate to achieve the user's goals."
        }
        if entry["visibility"] == nil {
            entry["visibility"] = "list"
        }
        if entry["supported_reasoning_levels"] == nil {
            entry["supported_reasoning_levels"] = [
                ["effort": "medium", "description": "Balances speed and reasoning depth"],
                ["effort": "high", "description": "Greater reasoning depth for complex problems"],
            ]
        }

        if profile != .proxyChat {
            // Native `/responses` and Anthropic gateways reject / drop Codex's freeform
            // `apply_patch` (type=="custom") tool and don't implement `tool_mode:
            // code_mode_only` code mode. Strip any key that would make Codex emit a
            // custom/freeform tool or treat this model as code-mode-only; shell_type
            // "shell_command" below covers edits instead. ProxyChat keeps them all — CPA's
            // own translator rewrites custom<->function tools on the way through. Mirrors
            // cc-switch's NativeResponses posture (`codex_catalog_model_entry`), plus
            // `tool_mode`, which cc-switch's own bundled templates simply never carry.
            entry.removeValue(forKey: "apply_patch_tool_type")
            entry.removeValue(forKey: "web_search_tool_type")
            entry.removeValue(forKey: "tools")
            entry.removeValue(forKey: "model_messages")
            entry.removeValue(forKey: "tool_mode")
        }
        entry["shell_type"] = "shell_command"

        entry["supported_reasoning_levels"] = AgentReasoningEffort.catalogLevels(
            modelID: modelID,
            override: reasoningOverride
        )
        let levels = AgentReasoningEffort.options(
            agent: .codex,
            modelID: modelID,
            override: reasoningOverride
        )
        if levels.contains("medium") {
            entry["default_reasoning_level"] = "medium"
        } else if let first = levels.first {
            entry["default_reasoning_level"] = first
        }
        return entry
    }

    private static func override(
        for modelID: String,
        in overrides: [String: AgentModelOverride]
    ) -> AgentModelOverride? {
        if let exact = overrides[modelID] { return exact }
        let key = AgentReasoningEffort.normalizeModelID(modelID)
        if let normalized = overrides[key] { return normalized }
        return overrides.first(where: {
            AgentReasoningEffort.normalizeModelID($0.key) == key
        })?.value
    }

    private static func uniqueNonEmpty(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in ids {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            out.append(id)
        }
        return out
    }

    private static func fetchModelIDsSync(endpoint: String, apiKey: String) throws -> [String] {
        // Avoid blocking forever from UI enable path.
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[String], Error> = .failure(AppError("模型列表超时"))
        Task.detached {
            do {
                let models = try await AgentModelCatalogService.fetch(endpoint: endpoint, apiKey: apiKey)
                result = .success(models.map(\.id))
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 4)
        return try result.get()
    }
}
