import Foundation
import Yams

/// Fetches and groups a provider's OpenAI-compatible model catalog.
enum AgentModelCatalogService {
    struct Model: Identifiable, Equatable, Sendable {
        /// Upstream model id used when writing live config (may collide across providers).
        var id: String
        var owner: String

        /// Stable list identity: same model id from different providers must both appear.
        var identity: String { "\(owner)\u{1f}\(id)" }
    }

    struct Group: Identifiable, Equatable, Sendable {
        var id: String { owner }
        var owner: String
        var title: String
        var models: [Model]
    }

    static func fetch(
        endpoint: String,
        apiKey: String,
        session: URLSession = .shared,
        coreConfigURL: URL = AppPaths.coreConfigURL,
        authDir: URL = AppPaths.oauthDirectory,
        codexSubscriptionPresent: Bool? = nil
    ) async throws -> [Model] {
        let remote = try await fetchUpstream(endpoint: endpoint, apiKey: apiKey, session: session)
        let local = loadLocalProviderModels(from: coreConfigURL)
        let hasSubscription = codexSubscriptionPresent ?? hasCodexOAuthSubscription(authDir: authDir)
        // CPA labels every codex-api-key row as owned_by=openai. When there is no Codex
        // OAuth, that remote row is a mislabel — drop it so the picker keeps only the local
        // native-Responses attribution. With OAuth, keep both groups (CPA collapses them;
        // local re-adds the native-Responses provider's own group).
        let filtered = suppressMisattributedCodexModels(
            remote: remote,
            local: local,
            codexSubscriptionPresent: hasSubscription
        )
        return mergePreservingOwners(filtered, with: local)
    }

    /// Fetch only the upstream `/models` payload, without merging local provider rows.
    static func fetchUpstream(
        endpoint: String,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> [Model] {
        var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let baseURL = URL(string: base) else {
            throw AppError("Endpoint 无效，无法获取模型列表")
        }

        var lastStatus: Int?
        for url in modelURLs(baseURL: baseURL) {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            }

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AppError("模型列表无 HTTP 响应")
            }
            lastStatus = http.statusCode
            if http.statusCode == 404 { continue }
            guard (200..<300).contains(http.statusCode) else {
                throw AppError("获取模型列表失败：HTTP \(http.statusCode)")
            }
            let models = try parse(data)
            guard !models.isEmpty else {
                throw AppError("上游未返回任何模型")
            }
            return models
        }

        throw AppError("获取模型列表失败：HTTP \(lastStatus ?? 404)")
    }

    static func parse(_ data: Data) throws -> [Model] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError("模型列表不是合法 JSON")
        }
        // OpenAI: { data: [{ id }] } · Anthropic: { data: [{ id }] } · Gemini: { models: [{ name }] }
        let entries = (json["data"] as? [[String: Any]]) ?? (json["models"] as? [[String: Any]]) ?? []
        var models: [Model] = []
        for entry in entries {
            let owner = string(entry["owned_by"])
                ?? string(entry["provider"])
                ?? string(entry["vendor"])
                ?? "unknown"
            if let id = entry["id"] as? String, !id.isEmpty {
                models.append(Model(id: id, owner: owner))
            } else if let name = entry["name"] as? String, !name.isEmpty {
                models.append(Model(
                    id: name.replacingOccurrences(of: "models/", with: ""),
                    owner: owner
                ))
            }
        }
        return uniquedSorted(models)
    }

    /// Build CPA `models` rows from an upstream list, preserving any existing row whose
    /// upstream name (or alias) matches, so a sync does not wipe custom aliases/capabilities.
    ///
    /// A brand-new row whose id collides with a *different* already-configured provider's alias
    /// gets `-<ownerName slug>` appended. CPA routes purely by alias, not by provider, so two
    /// providers sharing an alias become interchangeable to it (which is correct for multiple
    /// accounts of the *same* provider, handled by CPA's own priority/round-robin routing) --
    /// but wrong across different providers, where the point of picking a specific model id is to
    /// pin the request to that one provider. `otherProviderAliases` should already be lowercased.
    static func openAIModelRows(
        from models: [Model],
        existingRows: [[String: Any]] = [],
        ownerName: String = "",
        otherProviderAliases: Set<String> = []
    ) -> [[String: Any]] {
        var byUpstreamName: [String: [String: Any]] = [:]
        for row in existingRows {
            let name = (row["name"] as? String)
                ?? (row["alias"] as? String)
                ?? ""
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty, byUpstreamName[key] == nil {
                byUpstreamName[key] = row
            }
        }
        let slug = slugify(ownerName)
        return models.map { model in
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = byUpstreamName[id.lowercased()] {
                return existing
            }
            if !slug.isEmpty, otherProviderAliases.contains(id.lowercased()) {
                return ["name": model.id, "alias": "\(id)-\(slug)"]
            }
            return ["name": model.id, "alias": model.id]
        }
    }

    /// Lowercase, hyphen-joined slug for appending to a colliding model alias.
    private static func slugify(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if out.last != "-" {
                out.append("-")
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Merge remote `/v1/models` with local `openai-compatibility` rows without dropping
    /// same-id models that belong to a different provider.
    static func mergePreservingOwners(_ remote: [Model], with local: [Model]) -> [Model] {
        uniquedSorted(remote + local)
    }

    /// Whether auth-dir holds an enabled Codex / OpenAI OAuth subscription credential.
    ///
    /// API-key rows live in `config.yaml` (`codex-api-key`), not here — so an install with
    /// only a codex-api-key provider correctly reports false even though GPT traffic uses
    /// the Codex executor.
    static func hasCodexOAuthSubscription(authDir: URL) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: authDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for url in entries where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }
            if boolValue(json["disabled"]) == true { continue }
            let kind = (string(json["type"]) ?? string(json["provider"]) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard kind == "codex" || kind == "openai" else { continue }
            // OAuth files carry access_token; plain API-key auth files do not.
            if string(json["access_token"]) != nil {
                return true
            }
        }
        return false
    }

    /// Drop remote `openai`/`codex` rows that are actually a `codex-api-key` native-Responses
    /// leg (DeepSeek or any other provider configured there).
    ///
    /// Local entries are never removed or rewritten. A remote row only survives when both (a) a
    /// real Codex OAuth subscription is present and (b) the id is one the subscription is
    /// actually known to serve (`CodexSubscriptionIsolation.patterns`) — that is a genuine
    /// ambiguity worth showing as a separate "Codex 订阅" destination. Every other id sharing the
    /// mislabel (e.g. `deepseek-v4-flash`) can never come from the subscription, so keeping it
    /// would just duplicate the local provider's own entry under the wrong group.
    static func suppressMisattributedCodexModels(
        remote: [Model],
        local: [Model],
        codexSubscriptionPresent: Bool
    ) -> [Model] {
        let nativeResponsesIDs = Set(
            local
                .filter { !isSubscriptionOwner($0.owner) }
                .map(\.id)
        )
        guard !nativeResponsesIDs.isEmpty else { return remote }
        return remote.filter { model in
            let owner = model.owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isCodexLabel = owner == "openai" || owner == "codex"
            guard isCodexLabel, nativeResponsesIDs.contains(model.id) else { return true }
            return codexSubscriptionPresent && overlapsSubscriptionCatalog(model.id)
        }
    }

    /// Whether `id` is one the Codex OAuth subscription is actually known to serve.
    private static func overlapsSubscriptionCatalog(_ id: String) -> Bool {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return CodexSubscriptionIsolation.patterns.contains {
            CodexSubscriptionIsolation.matches(pattern: $0.lowercased(), value: normalized)
        }
    }

    /// Whether `owner` is one of the real subscription/OAuth labels `groupTitle` maps to a
    /// "订阅" group, as opposed to a `codex-api-key` native-Responses provider CPA mislabels.
    private static func isSubscriptionOwner(_ owner: String) -> Bool {
        switch owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "xai", "grok", "openai", "codex", "anthropic", "claude", "google", "gemini":
            return true
        default:
            return false
        }
    }

    /// Locally declared API-provider models, across both sections a provider can occupy.
    ///
    /// A single vendor can have models under `codex-api-key` (native Responses) while its
    /// other models live under `openai-compatibility`; reading only the latter would hide
    /// the native-Responses ones from the picker.
    static func loadLocalProviderModels(from configURL: URL) -> [Model] {
        guard let root = loadConfigRoot(from: configURL) else { return [] }
        return uniquedSorted(
            compatibilityModels(in: root) + nativeResponsesModels(in: root)
        )
    }

    /// Models declared under core `openai-compatibility`.
    static func loadOpenAICompatibilityModels(from configURL: URL) -> [Model] {
        guard let root = loadConfigRoot(from: configURL) else { return [] }
        return uniquedSorted(compatibilityModels(in: root))
    }

    /// Which core config.yaml section currently answers a model alias, keyed by base-url
    /// for `codexAPIKeyNative` so callers can match a vendor (e.g. deepseek.com) without a
    /// second config read. `codex-api-key` is a raw native-Responses passthrough — no
    /// request/response translation — while `openai-compatibility` is translated through
    /// CPA's own chat<->responses converter. `CodexModelCatalogWriter` uses this to decide
    /// how much Codex protocol surface (freeform/custom tools, `tool_mode`) a model's
    /// catalog entry may safely declare.
    ///
    /// A model declared under both legs (a mixed-routing misconfiguration — CPA may then
    /// answer either leg's traffic for that id) resolves to `.codexAPIKeyNative`: the
    /// stricter, zero-translation catalog entry is the only one safe on both.
    enum CoreRoutingLeg: Equatable {
        case openAICompatibility
        case codexAPIKeyNative(baseURL: String)
    }

    static func coreRoutingLegs(from configURL: URL) -> [String: CoreRoutingLeg] {
        guard let root = loadConfigRoot(from: configURL) else { return [:] }
        var legs: [String: CoreRoutingLeg] = [:]
        for model in compatibilityModels(in: root) {
            legs[model.id] = .openAICompatibility
        }
        for entry in allNativeResponsesModels(in: root) {
            legs[entry.model.id] = .codexAPIKeyNative(baseURL: entry.baseURL)
        }
        return legs
    }

    /// How CPA resolves a model id, once each candidate leg's provider identity and priority are
    /// known. Declaring the same id under both sections is not automatically ambiguous: CPA's
    /// fill-first routing sends *all* traffic to whichever candidate has the higher `priority`,
    /// full stop -- only an exact tie is genuinely unpredictable (CPA then spreads traffic between
    /// the two, so the protocol answering any given request varies request to request).
    enum RoutingResolution: Equatable {
        case single(CoreRoutingLeg)
        case resolvedByPriority(
            winner: CoreRoutingLeg,
            winnerOwner: String,
            winnerPriority: Int,
            loserOwner: String,
            loserPriority: Int
        )
        case tiedPriority(priority: Int, compatOwner: String, nativeOwner: String)
    }

    private struct LegCandidate {
        var priority: Int
        var owner: String
        var baseURL: String?
    }

    static func routingResolutions(from configURL: URL) -> [String: RoutingResolution] {
        guard let root = loadConfigRoot(from: configURL) else { return [:] }
        let compat = compatCandidates(in: root)
        let native = nativeCandidates(in: root)
        var out: [String: RoutingResolution] = [:]
        for id in Set(compat.keys).union(native.keys) {
            switch (compat[id], native[id]) {
            case (let c?, let n?) where c.priority == n.priority:
                out[id] = .tiedPriority(priority: c.priority, compatOwner: c.owner, nativeOwner: n.owner)
            case (let c?, let n?) where c.priority > n.priority:
                out[id] = .resolvedByPriority(
                    winner: .openAICompatibility, winnerOwner: c.owner, winnerPriority: c.priority,
                    loserOwner: n.owner, loserPriority: n.priority
                )
            case (let c?, let n?):
                out[id] = .resolvedByPriority(
                    winner: .codexAPIKeyNative(baseURL: n.baseURL ?? ""), winnerOwner: n.owner, winnerPriority: n.priority,
                    loserOwner: c.owner, loserPriority: c.priority
                )
            case (.some, nil):
                out[id] = .single(.openAICompatibility)
            case (nil, let n?):
                out[id] = .single(.codexAPIKeyNative(baseURL: n.baseURL ?? ""))
            case (nil, nil):
                break
            }
        }
        return out
    }

    private static func compatCandidates(in root: [String: Any]) -> [String: LegCandidate] {
        guard let providers = arrayOfDictionaries(root[ProviderKind.openai.rawValue]) else { return [:] }
        var out: [String: LegCandidate] = [:]
        for provider in providers {
            guard boolValue(provider["disabled"]) != true else { continue }
            let priority = intValue(provider["priority"]) ?? 0
            let owner = string(provider["name"]) ?? "unknown"
            for row in arrayOfDictionaries(provider["models"]) ?? [] {
                guard let id = string(row["alias"]) ?? string(row["name"]), !id.isEmpty else { continue }
                if let existing = out[id], existing.priority >= priority { continue }
                out[id] = LegCandidate(priority: priority, owner: owner, baseURL: nil)
            }
        }
        return out
    }

    private static func nativeCandidates(in root: [String: Any]) -> [String: LegCandidate] {
        guard let providers = arrayOfDictionaries(root[ProviderKind.codex.rawValue]) else { return [:] }
        var out: [String: LegCandidate] = [:]
        for provider in providers {
            guard boolValue(provider["disabled"]) != true else { continue }
            let base = string(provider["base-url"]) ?? string(provider["baseUrl"]) ?? ""
            guard !base.isEmpty else { continue }
            let priority = intValue(provider["priority"]) ?? 0
            let owner = ProviderKind.hostDerivedDisplayName(baseURL: base)
            for row in arrayOfDictionaries(provider["models"]) ?? [] {
                guard let id = string(row["alias"]) ?? string(row["name"]), !id.isEmpty else { continue }
                if let existing = out[id], existing.priority >= priority { continue }
                out[id] = LegCandidate(priority: priority, owner: owner, baseURL: base)
            }
        }
        return out
    }

    /// Model picker label, split so a menu row can stay short while a persistent card can show
    /// the full reasoning. `detail` is nil for a plain single-leg model.
    struct ProtocolLabel: Equatable {
        var short: String
        var detail: String?
    }

    static func protocolLabel(modelID: String, resolutions: [String: RoutingResolution]) -> ProtocolLabel? {
        switch resolutions[modelID] {
        case .single(.codexAPIKeyNative):
            return ProtocolLabel(short: "Responses", detail: nil)
        case .single(.openAICompatibility):
            return ProtocolLabel(short: "Chat", detail: nil)
        case .resolvedByPriority(let winner, let winnerOwner, let winnerPriority, let loserOwner, let loserPriority):
            let proto = { () -> String in
                switch winner {
                case .codexAPIKeyNative: return "Responses"
                case .openAICompatibility: return "Chat"
                }
            }()
            return ProtocolLabel(
                short: proto,
                detail: "\(winnerOwner) 优先级 P\(winnerPriority) 高于 \(loserOwner) 的 P\(loserPriority)，稳定走这一条"
            )
        case .tiedPriority(let priority, let compatOwner, let nativeOwner):
            return ProtocolLabel(
                short: "Chat + Responses",
                detail: "\(compatOwner) 与 \(nativeOwner) 优先级同为 P\(priority)，CPA 会在两者间分配流量——"
                    + "去「API 接入」调高其一优先级，或禁用重复的一方"
            )
        case nil:
            return nil
        }
    }

    /// `protocolLabel`'s `short` form appended to `modelID`, for a menu row where there is no
    /// room for `detail` -- callers with more space (a persistent card) should show `detail` too.
    static func menuRowLabel(modelID: String, resolutions: [String: RoutingResolution]) -> String {
        guard let label = protocolLabel(modelID: modelID, resolutions: resolutions) else { return modelID }
        return "\(modelID)  ·  \(label.short)"
    }

    /// Every `codex-api-key` model alias, regardless of vendor (unlike `nativeResponsesModels`,
    /// which derives a display name per row so the model picker doesn't misgroup it).
    private static func allNativeResponsesModels(
        in root: [String: Any]
    ) -> [(model: Model, baseURL: String)] {
        guard let providers = arrayOfDictionaries(root[ProviderKind.codex.rawValue]) else { return [] }
        return providers.flatMap { provider -> [(model: Model, baseURL: String)] in
            let base = string(provider["base-url"]) ?? string(provider["baseUrl"]) ?? ""
            return providerModels(provider, owner: base).map { (model: $0, baseURL: base) }
        }
    }

    private static func loadConfigRoot(from configURL: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: configURL.path),
              let text = try? String(contentsOf: configURL, encoding: .utf8),
              let loaded = try? Yams.load(yaml: text)
        else { return nil }
        return dictionary(loaded)
    }

    private static func compatibilityModels(in root: [String: Any]) -> [Model] {
        guard let providers = arrayOfDictionaries(root[ProviderKind.openai.rawValue]) else { return [] }
        return providers.flatMap { provider -> [Model] in
            guard boolValue(provider["disabled"]) != true else { return [] }
            return providerModels(provider, owner: string(provider["name"]) ?? "unknown")
        }
    }

    /// `codex-api-key` rows carry no `name`, so each row is attributed by host — via
    /// `ProviderKind.hostDerivedDisplayName` — instead of being grouped as a Codex
    /// subscription (CPA's own `/v1/models` labels every row here `owned_by: openai`/`codex`).
    private static func nativeResponsesModels(in root: [String: Any]) -> [Model] {
        guard let providers = arrayOfDictionaries(root[ProviderKind.codex.rawValue]) else { return [] }
        return providers.flatMap { provider -> [Model] in
            guard boolValue(provider["disabled"]) != true else { return [] }
            let base = string(provider["base-url"]) ?? string(provider["baseUrl"]) ?? ""
            guard !base.isEmpty else { return [] }
            return providerModels(provider, owner: ProviderKind.hostDerivedDisplayName(baseURL: base))
        }
    }

    private static func providerModels(_ provider: [String: Any], owner: String) -> [Model] {
        (arrayOfDictionaries(provider["models"]) ?? []).compactMap { row in
            // CPA exposes alias as the public model id when present.
            guard let id = string(row["alias"]) ?? string(row["name"]), !id.isEmpty else {
                return nil
            }
            return Model(id: id, owner: owner)
        }
    }

    /// Grouped case-insensitively: a vendor's `openai-compatibility` leg (user-typed name, e.g.
    /// "DeepSeek") and its `codex-api-key` leg (host-derived, e.g. "Deepseek") otherwise produce
    /// two owner strings that differ only in case, splitting one provider into two picker groups.
    /// The first-seen casing of each owner wins as the group's display identity.
    static func groups(_ models: [Model]) -> [Group] {
        var canonicalOwner: [String: String] = [:]
        for model in models {
            let key = model.owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if canonicalOwner[key] == nil { canonicalOwner[key] = model.owner }
        }
        return Dictionary(
            grouping: models,
            by: { $0.owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        .map { key, models in
            let owner = canonicalOwner[key] ?? key
            // A vendor spanning two config sections may declare the same alias on both --
            // normally CPA would fall back to mixed routing for it -- so collapse it to one
            // row here rather than show the id twice under the one merged group.
            var seenIDs = Set<String>()
            let dedupedModels = models.filter {
                seenIDs.insert($0.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).inserted
            }
            return Group(owner: owner, title: groupTitle(owner), models: dedupedModels)
        }
        .sorted { lhs, rhs in
            let lp = groupPriority(lhs.owner)
            let rp = groupPriority(rhs.owner)
            return lp == rp
                ? lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                : lp < rp
        }
    }

    static func groupTitle(_ owner: String) -> String {
        let normalized = owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "xai", "grok": return "Grok 订阅"
        case "openai", "codex": return "Codex 订阅"
        case "anthropic", "claude": return "Claude Code 订阅"
        case "google", "gemini": return "Gemini 订阅"
        case "unknown", "": return "其他模型"
        default:
            return owner.hasSuffix("Provider") ? owner : "\(owner) API Provider"
        }
    }

    /// Whether the upstream behind `owner` answers `/responses/compact`, i.e. whether Codex's
    /// remote compaction actually works for its models when routed through CPA.
    ///
    /// The Codex executor forwards compaction upstream and the xAI one has its own compaction
    /// base URL; the Claude / Gemini / Antigravity / AIStudio executors all reply 501, and an
    /// arbitrary OpenAI-compatible upstream has no such endpoint to forward to. Codex never
    /// falls back to local compaction, so getting this wrong costs the user their compaction
    /// entirely rather than degrading it.
    static func supportsRemoteCompaction(owner: String) -> Bool {
        switch owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "openai", "codex", "xai", "grok": return true
        default: return false
        }
    }

    /// Catalog ids whose upstream cannot compact remotely — what to warn about before a profile
    /// claims the OpenAI provider identity.
    static func modelsWithoutRemoteCompaction(catalog: [String], known: [Model]) -> [String] {
        var capable = Set<String>()
        var seenOwner = Set<String>()
        for model in known {
            if supportsRemoteCompaction(owner: model.owner) {
                capable.insert(model.id.lowercased())
            }
            seenOwner.insert(model.id.lowercased())
        }
        return catalog.filter { id in
            let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // An id we have never seen listed says nothing either way; only flag known-bad ones.
            return !key.isEmpty && seenOwner.contains(key) && !capable.contains(key)
        }
    }

    static func modelURLs(baseURL: URL) -> [URL] {
        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("models") { return [baseURL] }
        if path.hasSuffix("v1") { return [baseURL.appendingPathComponent("models")] }
        // Claude profiles normally store the bare CPA origin; CPA exposes the unified list at /v1/models.
        return [
            baseURL.appendingPathComponent("v1/models"),
            baseURL.appendingPathComponent("models"),
        ]
    }

    private static func uniquedSorted(_ models: [Model]) -> [Model] {
        var seen = Set<String>()
        return models
            .filter { seen.insert($0.identity).inserted }
            .sorted { lhs, rhs in
                let byID = lhs.id.localizedCaseInsensitiveCompare(rhs.id)
                if byID != .orderedSame { return byID == .orderedAscending }
                return lhs.owner.localizedCaseInsensitiveCompare(rhs.owner) == .orderedAscending
            }
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? NSString {
            let trimmed = (value as String).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let value = value as? [String: Any] { return value }
        if let value = value as? [AnyHashable: Any] {
            var out: [String: Any] = [:]
            for (key, item) in value {
                guard let key = key as? String else { continue }
                out[key] = item
            }
            return out
        }
        if let value = value as? NSDictionary {
            var out: [String: Any] = [:]
            for (key, item) in value {
                guard let key = key as? String else { continue }
                out[key] = item
            }
            return out
        }
        return nil
    }

    private static func arrayOfDictionaries(_ value: Any?) -> [[String: Any]]? {
        if let value = value as? [[String: Any]] { return value }
        if let value = value as? [Any] {
            let mapped = value.compactMap(dictionary)
            return mapped.isEmpty && !value.isEmpty ? nil : mapped
        }
        if let value = value as? NSArray {
            let mapped = value.compactMap { dictionary($0) }
            return mapped.isEmpty && value.count > 0 ? nil : mapped
        }
        return nil
    }

    private static func groupPriority(_ owner: String) -> Int {
        switch owner.lowercased() {
        case "xai", "grok": return 0
        case "openai", "codex": return 1
        case "anthropic", "claude": return 2
        case "google", "gemini": return 3
        default: return 4
        }
    }
}
