import XCTest
import SQLite3
@testable import MacCLIProxyAPI

final class AgentLiveConfigWriterTests: XCTestCase {
    func testLocalCPAEndpoints() {
        let claude = AgentProviderProfile.localCPA(agent: .claude, port: 8317, apiKey: "k")
        XCTAssertEqual(claude.endpoint, "http://127.0.0.1:8317")
        XCTAssertTrue(claude.isLocalCPA)

        let codex = AgentProviderProfile.localCPA(agent: .codex, port: 8317, apiKey: "k")
        XCTAssertEqual(codex.endpoint, "http://127.0.0.1:8317/v1")
    }

    func testProviderStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCLIProxyAPI-agent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Store uses AppPaths — verify model encode/decode independently.
        let profile = AgentProviderProfile(
            id: "test-1",
            agent: .claude,
            name: "Demo",
            endpoint: "http://127.0.0.1:8317",
            apiKey: "secret",
            model: "claude-sonnet",
            isLocalCPA: false,
            notes: "",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([profile])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([AgentProviderProfile].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].name, "Demo")
        XCTAssertEqual(decoded[0].agent, .claude)
        XCTAssertFalse(decoded[0].isDefault)
    }

    func testDecodeLegacyProfileWithoutIsDefault() throws {
        let json = """
        [{"id":"legacy-1","agent":"codex","name":"Old","endpoint":"http://127.0.0.1:1/v1","apiKey":"k","model":"","isLocalCPA":false,"notes":"","createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([AgentProviderProfile].self, from: Data(json.utf8))
        XCTAssertEqual(decoded[0].id, "legacy-1")
        XCTAssertFalse(decoded[0].isDefault)
    }

    func testDefaultProfileFactoryAndSort() {
        let def = AgentProviderProfile.makeDefault(agent: .codex, endpoint: "", apiKey: "", model: "")
        XCTAssertTrue(def.isDefault)
        XCTAssertEqual(def.id, "default-codex")
        XCTAssertEqual(def.name, "默认")

        let off = AgentProviderProfile.official(agent: .codex)
        XCTAssertTrue(off.isOfficial)
        XCTAssertEqual(off.id, "official-codex")
        XCTAssertEqual(off.name, "OpenAI 官方")

        let cpa = AgentProviderProfile.localCPA(agent: .codex, port: 1, apiKey: "k")
        let custom = AgentProviderProfile(
            id: "x",
            agent: .codex,
            name: "Zeta",
            endpoint: "http://example.com/v1",
            apiKey: "k",
            model: "",
            isLocalCPA: false,
            notes: "",
            createdAt: Date(),
            updatedAt: Date()
        )
        let sorted = [custom, cpa, off, def].sorted(by: AgentProviderStore.providerSort)
        XCTAssertEqual(sorted.map(\.id), [def.id, off.id, cpa.id, custom.id])
    }

    func testMergeClaudeOfficialCleansSettings() throws {
        let initialJSON = """
        {
          "permissions": {"allow": true},
          "effortLevel": "high",
          "env": {
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:8317",
            "ANTHROPIC_AUTH_TOKEN": "secret",
            "ANTHROPIC_MODEL": "claude-sonnet-4-5",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-5",
            "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME": "Claude 3.7 Sonnet",
            "CLAUDE_CODE_EFFORT_LEVEL": "max",
            "CUSTOM_USER_ENV": "preserve_this"
          }
        }
        """
        let officialProfile = AgentProviderProfile.official(agent: .claude)
        let data = try AgentLiveConfigWriter.mergeClaude(
            existingJSON: Data(initialJSON.utf8),
            profile: officialProfile
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(root["permissions"])
        XCTAssertNil(root["effortLevel"])
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        XCTAssertNil(env["ANTHROPIC_BASE_URL"])
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(env["ANTHROPIC_MODEL"])
        XCTAssertNil(env["ANTHROPIC_DEFAULT_SONNET_MODEL"])
        XCTAssertNil(env["ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"])
        XCTAssertNil(env["CLAUDE_CODE_EFFORT_LEVEL"])
        XCTAssertEqual(env["CUSTOM_USER_ENV"] as? String, "preserve_this")
    }

    func testMergeCodexOfficialWithAndWithoutUnify() {
        let initialTOML = """
        model_provider = "custom"
        model = "gpt-5.6-sol"
        model_catalog_json = "maccliproxy-model-catalog.json"
        web_search = "disabled"

        [model_providers.custom]
        name = "Local"
        base_url = "http://127.0.0.1:8317/v1"
        wire_api = "responses"
        requires_openai_auth = true
        experimental_bearer_token = "tok"
        """
        let official = AgentProviderProfile.official(agent: .codex)

        // 1. With Unify = true
        let unifiedText = AgentLiveConfigWriter.mergeCodex(
            existingText: initialTOML,
            profile: official,
            unifySessionHistory: true
        )
        XCTAssertEqual(TOMLEdit.value(unifiedText, table: nil, key: "model_provider"), "custom")
        XCTAssertNil(TOMLEdit.value(unifiedText, table: nil, key: "model_catalog_json"))
        XCTAssertNil(TOMLEdit.value(unifiedText, table: nil, key: "web_search"))
        XCTAssertEqual(TOMLEdit.value(unifiedText, table: "model_providers.custom", key: "name"), "OpenAI")
        XCTAssertNil(TOMLEdit.value(unifiedText, table: "model_providers.custom", key: "base_url"))
        XCTAssertNil(TOMLEdit.value(unifiedText, table: "model_providers.custom", key: "experimental_bearer_token"))
        XCTAssertEqual(TOMLEdit.value(unifiedText, table: "model_providers.custom", key: "wire_api"), "responses")

        // 2. With Unify = false
        let cleanText = AgentLiveConfigWriter.mergeCodex(
            existingText: initialTOML,
            profile: official,
            unifySessionHistory: false
        )
        XCTAssertNil(TOMLEdit.value(cleanText, table: nil, key: "model_provider"))
        XCTAssertNil(TOMLEdit.value(cleanText, table: nil, key: "model_catalog_json"))
        XCTAssertFalse(cleanText.contains("[model_providers.custom]"))
    }

    func testCodexStableProviderID() {
        XCTAssertEqual(CodexStableProvider.id, "custom")
        XCTAssertTrue(CodexStableProvider.reservedIDs.contains("openai"))
    }


    func testTOMLEditKeepsExistingTables() {
        let original = """
        [marketplace]
        default_skills_installs_purged = true

        [ui]
        max_thoughts_width = 120
        fork_secondary_model = "grok-4.5"
        """
        var text = TOMLEdit.setString(original, table: "endpoints", key: "models_base_url", value: "http://127.0.0.1:28317/v1")
        text = TOMLEdit.setString(text, table: "ui", key: "max_thoughts_width", value: "80")

        XCTAssertTrue(text.contains("[marketplace]"))
        XCTAssertTrue(text.contains("fork_secondary_model = \"grok-4.5\""))
        XCTAssertEqual(TOMLEdit.value(text, table: "endpoints", key: "models_base_url"), "http://127.0.0.1:28317/v1")
        XCTAssertEqual(TOMLEdit.value(text, table: "ui", key: "max_thoughts_width"), "80")
        // Tables must not be duplicated — TOML rejects that.
        XCTAssertEqual(text.components(separatedBy: "[ui]").count - 1, 1)
        XCTAssertEqual(text.components(separatedBy: "[endpoints]").count - 1, 1)
    }

    func testTOMLEditUpdatesExistingKeyInPlace() {
        let original = """
        [endpoints]
        models_base_url = "https://old.example.com/v1"
        other = 1
        """
        let text = TOMLEdit.setString(original, table: "endpoints", key: "models_base_url", value: "http://127.0.0.1:1/v1")
        XCTAssertEqual(text.components(separatedBy: "models_base_url").count - 1, 1)
        XCTAssertEqual(TOMLEdit.value(text, table: "endpoints", key: "models_base_url"), "http://127.0.0.1:1/v1")
        XCTAssertTrue(text.contains("other = 1"))
    }

    func testTOMLEditRemoveTableAndSubTableNames() {
        let original = """
        [model."maccliproxy"]
        model = "default"

        [model."grok-4.5"]
        api_key = "k"
        """
        XCTAssertEqual(TOMLEdit.subTableNames(original, parent: "model").sorted(), ["grok-4.5", "maccliproxy"])
        let stripped = TOMLEdit.removeTable(original, name: "model.maccliproxy")
        XCTAssertFalse(stripped.contains("maccliproxy"))
        XCTAssertTrue(stripped.contains("[model.\"grok-4.5\"]"))
        XCTAssertEqual(TOMLEdit.quoteTableComponent("grok-4.5"), "\"grok-4.5\"")
        XCTAssertEqual(TOMLEdit.quoteTableComponent("grok-build"), "grok-build")
    }

    func testModelRolesPerAgent() {
        XCTAssertEqual(AgentKind.claude.modelRoles, [.main, .sonnet, .opus, .haiku, .fable, .subagent])
        XCTAssertEqual(AgentKind.codex.modelRoles, [.main])
        XCTAssertEqual(AgentKind.allCases.count, 2)
        XCTAssertTrue(AgentKind.codex.supportsReasoningEffort)
        XCTAssertEqual(AgentKind.codex.reasoningEffortOptions, ["minimal", "low", "medium", "high", "xhigh"])
        XCTAssertEqual(AgentKind.claude.reasoningEffortOptions, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertTrue(AgentKind.claude.supportsReasoningEffort)

        var profile = AgentProviderProfile.localCPA(agent: .codex, port: 1, apiKey: "k")
        profile.setModel("gpt-5.6", for: .main)
        profile.setModel("legacy-web", for: .webSearch)
        XCTAssertEqual(profile.model(for: .main), "gpt-5.6")
        XCTAssertEqual(profile.model(for: .webSearch), "legacy-web")
        XCTAssertEqual(profile.model(for: .fast), "")

        var claude = AgentProviderProfile.localCPA(agent: .claude, port: 1, apiKey: "k", model: "fallback")
        claude.setModel("sonnet", for: .sonnet)
        claude.setModel("opus", for: .opus)
        claude.setModel("haiku", for: .haiku)
        XCTAssertEqual(claude.model(for: .main), "fallback")
        XCTAssertEqual(claude.model(for: .sonnet), "sonnet")
        XCTAssertEqual(claude.model(for: .opus), "opus")
        XCTAssertEqual(claude.model(for: .haiku), "haiku")
    }

    func testClaudeOneMContextMarker() {
        XCTAssertEqual(ClaudeContextMarker.setOneM("claude-sonnet-4-5", enabled: true), "claude-sonnet-4-5[1M]")
        XCTAssertEqual(ClaudeContextMarker.setOneM("claude-sonnet-4-5[1M]", enabled: true), "claude-sonnet-4-5[1M]")
        XCTAssertEqual(ClaudeContextMarker.setOneM("claude-sonnet-4-5[1M]", enabled: false), "claude-sonnet-4-5")
        XCTAssertEqual(ClaudeContextMarker.setOneM("  ", enabled: true), "")
        XCTAssertTrue(ClaudeContextMarker.hasOneM("model[1m] "))
        XCTAssertFalse(ClaudeContextMarker.hasOneM("model"))
        XCTAssertEqual(ClaudeContextMarker.stripOneM("model"), "model")

        for role in [AgentModelRole.main, .sonnet, .opus, .fable, .subagent] {
            XCTAssertTrue(role.supportsOneMContext(for: .claude), "\(role) should offer 1M")
        }
        XCTAssertFalse(AgentModelRole.haiku.supportsOneMContext(for: .claude))
        XCTAssertFalse(AgentModelRole.main.supportsOneMContext(for: .codex))

        XCTAssertEqual(AgentModelRole.sonnet.claudeDisplayNameKey(for: .claude), "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME")
        XCTAssertNil(AgentModelRole.main.claudeDisplayNameKey(for: .claude))
        XCTAssertNil(AgentModelRole.sonnet.claudeDisplayNameKey(for: .codex))
    }

    func testModelCatalogParsing() throws {
        let openAI = Data(#"""
        {"data":[
          {"id":"grok-4.5","owned_by":"xai"},
          {"id":"gpt-5.6","owned_by":"openai"},
          {"id":"gpt-5.6","owned_by":"openai"},
          {"id":"gpt-5.6","owned_by":"acme"},
          {"id":"deepseek-v4","owned_by":"acme"}
        ]}
        """#.utf8)
        let parsed = try AgentModelCatalogService.parse(openAI)
        // Same id from different providers must both remain; same provider dup is collapsed.
        XCTAssertEqual(
            parsed.map { "\($0.owner):\($0.id)" },
            ["acme:deepseek-v4", "acme:gpt-5.6", "openai:gpt-5.6", "xai:grok-4.5"]
        )
        let groups = AgentModelCatalogService.groups(parsed)
        XCTAssertEqual(
            groups.map(\.title),
            ["Grok 订阅", "Codex 订阅", "acme API Provider"]
        )
        XCTAssertEqual(
            groups.first(where: { $0.title == "acme API Provider" })?.models.map(\.id),
            ["deepseek-v4", "gpt-5.6"]
        )

        let gemini = Data(#"{"models":[{"name":"models/gemini-3"}]}"#.utf8)
        XCTAssertEqual(try AgentModelCatalogService.parse(gemini).map(\.id), ["gemini-3"])

        XCTAssertThrowsError(try AgentModelCatalogService.parse(Data("nope".utf8)))
    }

    /// A vendor's `openai-compatibility` leg (user-typed name, e.g. "DeepSeek") and its
    /// `codex-api-key` leg (host-derived, e.g. "Deepseek") must merge into one picker group even
    /// though the raw owner strings differ only in case -- otherwise the same provider splits into
    /// two "... API Provider" groups, one of them showing just the id(s) unique to that leg.
    func testGroupsMergeOwnersDifferingOnlyByCase() {
        let models = [
            AgentModelCatalogService.Model(id: "deepseek-v4-flash", owner: "DeepSeek"),
            AgentModelCatalogService.Model(id: "deepseek-v4-pro", owner: "DeepSeek"),
            // Same id declared again under the host-derived casing for the native-Responses leg.
            AgentModelCatalogService.Model(id: "deepseek-v4-flash", owner: "Deepseek"),
        ]
        let groups = AgentModelCatalogService.groups(models)
        XCTAssertEqual(groups.map(\.title), ["DeepSeek API Provider"])
        XCTAssertEqual(
            groups[0].models.map(\.id).sorted(),
            ["deepseek-v4-flash", "deepseek-v4-pro"]
        )
    }

    func testOpenAIModelRowsPreservesExistingAliasesOnSync() {
        let models = [
            AgentModelCatalogService.Model(id: "deepseek-chat", owner: "deepseek"),
            AgentModelCatalogService.Model(id: "deepseek-reasoner", owner: "deepseek"),
        ]
        let rows = AgentModelCatalogService.openAIModelRows(
            from: models,
            existingRows: [
                [
                    "name": "deepseek-chat",
                    "alias": "chat",
                    "display-name": "Chat",
                ],
            ]
        )
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["name"] as? String, "deepseek-chat")
        XCTAssertEqual(rows[0]["alias"] as? String, "chat")
        XCTAssertEqual(rows[0]["display-name"] as? String, "Chat")
        XCTAssertEqual(rows[1]["name"] as? String, "deepseek-reasoner")
        XCTAssertEqual(rows[1]["alias"] as? String, "deepseek-reasoner")
    }

    /// A brand-new row colliding with a *different* provider's already-configured alias gets
    /// `-<ownerName slug>` appended, so picking this id later pins the request to this provider
    /// instead of CPA treating both providers' rows as interchangeable. A model already present in
    /// `existingRows` is untouched (preserves any alias the user already set by hand), and a model
    /// with no collision keeps its bare id.
    func testOpenAIModelRowsSuffixesAliasOnCrossProviderCollision() {
        let models = [
            AgentModelCatalogService.Model(id: "gpt-5.6-sol", owner: "acme"),
            AgentModelCatalogService.Model(id: "deepseek-v4", owner: "acme"),
        ]
        let rows = AgentModelCatalogService.openAIModelRows(
            from: models,
            existingRows: [],
            ownerName: "Acme API",
            otherProviderAliases: ["gpt-5.6-sol"]
        )
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["name"] as? String, "gpt-5.6-sol")
        XCTAssertEqual(rows[0]["alias"] as? String, "gpt-5.6-sol-acme-api")
        XCTAssertEqual(rows[1]["name"] as? String, "deepseek-v4")
        XCTAssertEqual(rows[1]["alias"] as? String, "deepseek-v4")
    }

    func testMergePreservesSameIDAcrossProvidersFromLocalConfig() throws {
        let remote = try AgentModelCatalogService.parse(Data(#"""
        {"data":[
          {"id":"gpt-5.4","owned_by":"openai"},
          {"id":"gpt-5.3-codex","owned_by":"acme"},
          {"id":"claude-sonnet-5","owned_by":"acme"}
        ]}
        """#.utf8))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maccliproxy-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("config.yaml")
        try """
        openai-compatibility:
          - name: acme
            models:
              - alias: gpt-5.4
                name: gpt-5.4
              - alias: gpt-5.5
                name: gpt-5.5
              - alias: gpt-5.3-codex
                name: gpt-5.3-codex
        """.write(to: config, atomically: true, encoding: .utf8)

        let local = AgentModelCatalogService.loadOpenAICompatibilityModels(from: config)
        let merged = AgentModelCatalogService.mergePreservingOwners(remote, with: local)
        let acmeGPT = merged
            .filter { $0.owner == "acme" && $0.id.hasPrefix("gpt-") }
            .map(\.id)
            .sorted()
        XCTAssertEqual(acmeGPT, ["gpt-5.3-codex", "gpt-5.4", "gpt-5.5"])
        XCTAssertTrue(merged.contains { $0.owner == "openai" && $0.id == "gpt-5.4" })
    }

    /// A vendor can span two config sections; the picker must show models from both, with the
    /// `codex-api-key` leg keyed by its own base-url host since those rows carry no `name`.
    func testLoadLocalProviderModelsMergesNativeResponsesLeg() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maccliproxy-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("config.yaml")
        try """
        openai-compatibility:
          - name: acme
            base-url: https://api.acme.example/v2
            models:
              - alias: deepseek-v4-flash-ioa
                name: deepseek-v4-flash-ioa
        codex-api-key:
          - base-url: https://gpt.acme.example
            priority: 10
            models:
              - alias: gpt-5.6-sol
                name: ep-gpt56solioa
          - base-url: https://api.openai.com/v1
            models:
              - alias: gpt-5.4
                name: gpt-5.4
        """.write(to: config, atomically: true, encoding: .utf8)

        let local = AgentModelCatalogService.loadLocalProviderModels(from: config)
        let byID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0.owner) })
        XCTAssertEqual(byID["deepseek-v4-flash-ioa"], "acme")
        // GPT lives under codex-api-key, attributed by its own base-url host -- not the
        // openai-compatibility provider's name, even though it is the same vendor.
        XCTAssertEqual(byID["gpt-5.6-sol"], "Gpt")
        XCTAssertEqual(AgentModelCatalogService.groupTitle(byID["gpt-5.6-sol"] ?? ""), "Gpt API Provider")
        // A codex-api-key row pointed at a different host gets its own, different attribution.
        XCTAssertEqual(byID["gpt-5.4"], "Openai")
        XCTAssertTrue(AgentModelCatalogService.loadOpenAICompatibilityModels(from: config)
            .allSatisfy { $0.id == "deepseek-v4-flash-ioa" })
    }

    /// The same model id declared under both sections with *different* priorities is not
    /// actually ambiguous: CPA's fill-first routing sends all traffic to the higher-priority
    /// candidate, so this must resolve deterministically to that one leg, not report "uncertain".
    func testMixedRoutingResolvesDeterministicallyByPriority() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maccliproxy-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("config.yaml")
        try """
        openai-compatibility:
          - name: acme
            base-url: https://api.acme.example/v2
            priority: 5
            models:
              - alias: deepseek-v4-flash
                name: deepseek-v4-flash
        codex-api-key:
          - base-url: https://api.acme.example
            priority: 10
            models:
              - alias: deepseek-v4-flash
                name: deepseek-v4-flash
        """.write(to: config, atomically: true, encoding: .utf8)

        let resolutions = AgentModelCatalogService.routingResolutions(from: config)
        guard case .resolvedByPriority(let winner, let winnerOwner, let winnerPriority, let loserOwner, let loserPriority)? =
            resolutions["deepseek-v4-flash"]
        else {
            return XCTFail("expected a priority-resolved outcome, got \(String(describing: resolutions["deepseek-v4-flash"]))")
        }
        XCTAssertEqual(winner, .codexAPIKeyNative(baseURL: "https://api.acme.example"))
        XCTAssertEqual(winnerOwner, "Acme")
        XCTAssertEqual(winnerPriority, 10)
        XCTAssertEqual(loserOwner, "acme")
        XCTAssertEqual(loserPriority, 5)

        let label = AgentModelCatalogService.protocolLabel(modelID: "deepseek-v4-flash", resolutions: resolutions)
        XCTAssertEqual(label?.short, "Responses")
        XCTAssertNotNil(label?.detail)
        XCTAssertEqual(
            AgentModelCatalogService.menuRowLabel(modelID: "deepseek-v4-flash", resolutions: resolutions),
            "deepseek-v4-flash  ·  Responses"
        )
    }

    /// Equal priority on both legs is the one case that is genuinely unpredictable -- CPA spreads
    /// traffic between the two candidates -- so this must name both providers and the shared
    /// priority explicitly, with concrete next steps, rather than a bare "uncertain" label.
    func testMixedRoutingFlagsGenuineTieWithActionableDetail() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maccliproxy-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("config.yaml")
        try """
        openai-compatibility:
          - name: acme
            base-url: https://api.acme.example/v2
            models:
              - alias: deepseek-v4-flash
                name: deepseek-v4-flash
        codex-api-key:
          - base-url: https://api.acme.example
            models:
              - alias: deepseek-v4-flash
                name: deepseek-v4-flash
        """.write(to: config, atomically: true, encoding: .utf8)

        let resolutions = AgentModelCatalogService.routingResolutions(from: config)
        guard case .tiedPriority(let priority, let compatOwner, let nativeOwner)? = resolutions["deepseek-v4-flash"] else {
            return XCTFail("expected a tie, got \(String(describing: resolutions["deepseek-v4-flash"]))")
        }
        XCTAssertEqual(priority, 0)
        XCTAssertEqual(compatOwner, "acme")
        XCTAssertEqual(nativeOwner, "Acme")

        let label = AgentModelCatalogService.protocolLabel(modelID: "deepseek-v4-flash", resolutions: resolutions)
        XCTAssertEqual(label?.short, "Chat + Responses")
        XCTAssertTrue(label?.detail?.contains("acme") == true)
        XCTAssertTrue(label?.detail?.contains("Acme") == true)
        XCTAssertTrue(label?.detail?.contains("P0") == true)
    }

    /// Only one API provider configured: CPA still labels GPT as owned_by=openai; picker must
    /// keep the provider's own group and drop the false Codex 订阅 duplicate.
    func testSuppressMisattributedCodexWhenNoOAuthKeepsProviderGroup() throws {
        let remote = try AgentModelCatalogService.parse(Data(#"""
        {"data":[
          {"id":"gpt-5.6-sol","owned_by":"openai"},
          {"id":"deepseek-v4","owned_by":"acme"}
        ]}
        """#.utf8))
        let local = [
            AgentModelCatalogService.Model(id: "gpt-5.6-sol", owner: "acme"),
            AgentModelCatalogService.Model(id: "deepseek-v4", owner: "acme"),
        ]
        let filtered = AgentModelCatalogService.suppressMisattributedCodexModels(
            remote: remote,
            local: local,
            codexSubscriptionPresent: false
        )
        let merged = AgentModelCatalogService.mergePreservingOwners(filtered, with: local)
        let groups = AgentModelCatalogService.groups(merged)
        XCTAssertEqual(groups.map(\.title), ["acme API Provider"])
        XCTAssertEqual(
            groups.first?.models.map(\.id).sorted(),
            ["deepseek-v4", "gpt-5.6-sol"]
        )
        XCTAssertFalse(merged.contains { $0.owner == "openai" && $0.id == "gpt-5.6-sol" })
        XCTAssertTrue(merged.contains { $0.owner == "acme" && $0.id == "gpt-5.6-sol" })
    }

    /// Codex OAuth + an API provider: both groups stay (CPA collapses; local re-adds the provider).
    func testSuppressMisattributedCodexKeepsBothGroupsWhenOAuthPresent() throws {
        let remote = try AgentModelCatalogService.parse(Data(#"""
        {"data":[
          {"id":"gpt-5.6-sol","owned_by":"openai"}
        ]}
        """#.utf8))
        let local = [AgentModelCatalogService.Model(id: "gpt-5.6-sol", owner: "acme")]
        let filtered = AgentModelCatalogService.suppressMisattributedCodexModels(
            remote: remote,
            local: local,
            codexSubscriptionPresent: true
        )
        let merged = AgentModelCatalogService.mergePreservingOwners(filtered, with: local)
        let groups = AgentModelCatalogService.groups(merged)
        XCTAssertEqual(groups.map(\.title), ["Codex 订阅", "acme API Provider"])
        XCTAssertTrue(merged.contains { $0.owner == "openai" && $0.id == "gpt-5.6-sol" })
        XCTAssertTrue(merged.contains { $0.owner == "acme" && $0.id == "gpt-5.6-sol" })
    }

    /// A remote mislabel sharing an id with a local native-Responses provider is only kept as a
    /// separate "Codex 订阅" destination when the id is one the subscription is genuinely known to
    /// serve (`CodexSubscriptionIsolation.patterns`). Regression: `deepseek-v4-flash` -- never
    /// servable by the subscription -- used to stay under "Codex 订阅" whenever ANY subscription
    /// was present, duplicating the correctly-owned local "acme" entry under the wrong group.
    func testSuppressMisattributedCodexDropsNonOverlappingIDsEvenWithOAuth() throws {
        let remote = try AgentModelCatalogService.parse(Data(#"""
        {"data":[
          {"id":"gpt-5.6-sol","owned_by":"openai"},
          {"id":"deepseek-v4-flash","owned_by":"openai"}
        ]}
        """#.utf8))
        let local = [
            AgentModelCatalogService.Model(id: "gpt-5.6-sol", owner: "acme"),
            AgentModelCatalogService.Model(id: "deepseek-v4-flash", owner: "acme"),
        ]
        let filtered = AgentModelCatalogService.suppressMisattributedCodexModels(
            remote: remote,
            local: local,
            codexSubscriptionPresent: true
        )
        XCTAssertTrue(filtered.contains { $0.owner == "openai" && $0.id == "gpt-5.6-sol" })
        XCTAssertFalse(filtered.contains { $0.owner == "openai" && $0.id == "deepseek-v4-flash" })

        let merged = AgentModelCatalogService.mergePreservingOwners(filtered, with: local)
        let groups = AgentModelCatalogService.groups(merged)
        XCTAssertEqual(
            groups.first(where: { $0.title == "acme API Provider" })?.models.map(\.id).sorted(),
            ["deepseek-v4-flash", "gpt-5.6-sol"]
        )
        XCTAssertEqual(
            groups.first(where: { $0.title == "Codex 订阅" })?.models.map(\.id),
            ["gpt-5.6-sol"]
        )
    }

    /// Unrelated openai ids must still appear under Codex 订阅 even without OAuth.
    func testSuppressMisattributedCodexLeavesUnrelatedOpenAIModels() throws {
        let remote = try AgentModelCatalogService.parse(Data(#"""
        {"data":[
          {"id":"gpt-5.6-sol","owned_by":"openai"},
          {"id":"gpt-image-1.5","owned_by":"openai"}
        ]}
        """#.utf8))
        let local = [AgentModelCatalogService.Model(id: "gpt-5.6-sol", owner: "acme")]
        let filtered = AgentModelCatalogService.suppressMisattributedCodexModels(
            remote: remote,
            local: local,
            codexSubscriptionPresent: false
        )
        let merged = AgentModelCatalogService.mergePreservingOwners(filtered, with: local)
        XCTAssertTrue(merged.contains { $0.owner == "acme" && $0.id == "gpt-5.6-sol" })
        XCTAssertFalse(merged.contains { $0.owner == "openai" && $0.id == "gpt-5.6-sol" })
        XCTAssertTrue(merged.contains { $0.owner == "openai" && $0.id == "gpt-image-1.5" })
        XCTAssertEqual(
            AgentModelCatalogService.groups(merged).map(\.title),
            ["Codex 订阅", "acme API Provider"]
        )
    }

    func testHasCodexOAuthSubscriptionDetectsEnabledTokenFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maccliproxy-oauth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertFalse(AgentModelCatalogService.hasCodexOAuthSubscription(authDir: dir))

        try Data(#"{"type":"codex","access_token":"tok","disabled":false}"#.utf8)
            .write(to: dir.appendingPathComponent("codex-user.json"))
        XCTAssertTrue(AgentModelCatalogService.hasCodexOAuthSubscription(authDir: dir))

        try Data(#"{"type":"codex","access_token":"tok","disabled":true}"#.utf8)
            .write(to: dir.appendingPathComponent("codex-user.json"), options: .atomic)
        XCTAssertFalse(AgentModelCatalogService.hasCodexOAuthSubscription(authDir: dir))
    }

    func testClaudeModelCatalogUsesUnifiedV1Path() {
        let bare = URL(string: "http://127.0.0.1:8317")!
        XCTAssertEqual(
            AgentModelCatalogService.modelURLs(baseURL: bare).map(\.absoluteString),
            ["http://127.0.0.1:8317/v1/models", "http://127.0.0.1:8317/models"]
        )
        let v1 = URL(string: "http://127.0.0.1:8317/v1")!
        XCTAssertEqual(
            AgentModelCatalogService.modelURLs(baseURL: v1).map(\.absoluteString),
            ["http://127.0.0.1:8317/v1/models"]
        )
    }

    func testLoadProfilesStripsRemovedGrokAgentEntries() throws {
        let json = """
        [
          {"id":"c1","agent":"claude","name":"C","endpoint":"http://127.0.0.1:1","apiKey":"k","model":"m","isLocalCPA":false,"notes":"","createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"},
          {"id":"g1","agent":"grok","name":"G","endpoint":"http://127.0.0.1:1/v1","apiKey":"k","model":"grok-4.5","isLocalCPA":true,"notes":"","createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"},
          {"id":"x1","agent":"codex","name":"X","endpoint":"http://127.0.0.1:1/v1","apiKey":"k","model":"gpt","isLocalCPA":false,"notes":"","createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"}
        ]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let migrated = try XCTUnwrap(
            AgentProviderStore.migrateRemovingObsoleteAgents(from: Data(json.utf8), decoder: decoder)
        )
        XCTAssertTrue(migrated.dropped)
        XCTAssertEqual(migrated.profiles.map(\.id), ["c1", "x1"])
        XCTAssertEqual(Set(migrated.profiles.map(\.agent)), Set([.claude, .codex]))
    }

    func testReasoningEffortMatrixMatchesTTSwitch() {
        XCTAssertEqual(
            AgentReasoningEffort.options(agent: .codex, modelID: "gpt-5.6-sol"),
            ["low", "medium", "high", "xhigh", "max"]
        )
        XCTAssertEqual(
            AgentReasoningEffort.options(agent: .codex, modelID: "gpt-5.5"),
            ["none", "low", "medium", "high", "xhigh"]
        )
        XCTAssertEqual(
            AgentReasoningEffort.options(agent: .claude, modelID: "claude-sonnet-5"),
            ["low", "medium", "high", "xhigh", "max"]
        )
        XCTAssertEqual(
            AgentReasoningEffort.options(agent: .claude, modelID: "claude-opus-4.6"),
            ["low", "medium", "high", "max"]
        )
        XCTAssertEqual(
            AgentReasoningEffort.options(agent: .claude, modelID: "claude-haiku-4.5"),
            []
        )
        XCTAssertFalse(AgentReasoningEffort.isSupported(agent: .claude, modelID: "claude-haiku-4.5"))
        XCTAssertEqual(
            AgentReasoningEffort.sanitized("max", agent: .codex, modelID: "gpt-5.5"),
            ""
        )
        XCTAssertEqual(
            AgentReasoningEffort.sanitized("xhigh", agent: .codex, modelID: "gpt-5.5"),
            "xhigh"
        )
        // DeepSeek V4 Responses API: none…max (official create-response docs).
        XCTAssertEqual(
            AgentReasoningEffort.options(agent: .codex, modelID: "deepseek-v4-flash"),
            ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        )
        XCTAssertEqual(
            AgentReasoningEffort.options(agent: .codex, modelID: "deepseek-v4-flash-ioa"),
            ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        )
        XCTAssertEqual(
            AgentReasoningEffort.options(agent: .codex, modelID: "deepseek-v4-pro-ioa"),
            ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        )
        XCTAssertEqual(AgentReasoningEffort.knownContextWindow(for: "deepseek-v4-flash"), 1_000_000)
        XCTAssertEqual(
            AgentReasoningEffort.options(
                agent: .codex,
                modelID: "deepseek-v4-flash",
                override: ["low", "max"]
            ),
            ["low", "max"]
        )
    }

    func testClaudeEffortWritesTTSwitchShape() throws {
        var profile = AgentProviderProfile.localCPA(agent: .claude, port: 8317, apiKey: "k")
        profile.reasoningEffort = "xhigh"
        let data = try AgentLiveConfigWriter.mergeClaude(existingJSON: nil, profile: profile)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["effortLevel"] as? String, "xhigh")
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        XCTAssertNil(env["CLAUDE_CODE_EFFORT_LEVEL"])

        profile.reasoningEffort = "max"
        let maxData = try AgentLiveConfigWriter.mergeClaude(existingJSON: data, profile: profile)
        let maxRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: maxData) as? [String: Any])
        XCTAssertNil(maxRoot["effortLevel"])
        let maxEnv = try XCTUnwrap(maxRoot["env"] as? [String: Any])
        XCTAssertEqual(maxEnv["CLAUDE_CODE_EFFORT_LEVEL"] as? String, "max")
        XCTAssertEqual(AgentLiveConfigWriter.readClaudeEffort(from: maxRoot), "max")

        profile.reasoningEffort = ""
        let cleared = try AgentLiveConfigWriter.mergeClaude(existingJSON: maxData, profile: profile)
        let clearedRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: cleared) as? [String: Any])
        // Empty profile effort must not wipe Claude-side effort.
        XCTAssertEqual(AgentLiveConfigWriter.readClaudeEffort(from: clearedRoot), "max")
    }

    func testCodexCatalogLevelsIncludeMaxForGPT56() throws {
        let data = try CodexModelCatalogWriter.buildCatalogJSON(modelIDs: ["gpt-5.6-sol", "gpt-5.5"])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(root["models"] as? [[String: Any]])
        let sol = try XCTUnwrap(models.first { ($0["slug"] as? String) == "gpt-5.6-sol" })
        let levels = try XCTUnwrap(sol["supported_reasoning_levels"] as? [[String: Any]])
        XCTAssertEqual(levels.compactMap { $0["effort"] as? String }, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(sol["context_window"] as? Int, 1_000_000)
        let gpt55 = try XCTUnwrap(models.first { ($0["slug"] as? String) == "gpt-5.5" })
        let levels55 = try XCTUnwrap(gpt55["supported_reasoning_levels"] as? [[String: Any]])
        XCTAssertEqual(levels55.compactMap { $0["effort"] as? String }, ["none", "low", "medium", "high", "xhigh"])
    }

    func testCodexCatalogPerModelOverridesAndDeepSeek() throws {
        let overrides: [String: AgentModelOverride] = [
            "deepseek-v4-flash-ioa": AgentModelOverride(
                contextWindow: 384_000,
                reasoningLevels: ["high", "max"]
            ),
        ]
        let data = try CodexModelCatalogWriter.buildCatalogJSON(
            modelIDs: ["deepseek-v4-flash-ioa", "kimi-k2"],
            overrides: overrides
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(root["models"] as? [[String: Any]])
        let flash = try XCTUnwrap(models.first { ($0["slug"] as? String) == "deepseek-v4-flash-ioa" })
        XCTAssertEqual(flash["context_window"] as? Int, 384_000)
        let flashLevels = try XCTUnwrap(flash["supported_reasoning_levels"] as? [[String: Any]])
        XCTAssertEqual(flashLevels.compactMap { $0["effort"] as? String }, ["high", "max"])

        let auto = try CodexModelCatalogWriter.buildCatalogJSON(modelIDs: ["deepseek-v4-flash"])
        let autoRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: auto) as? [String: Any])
        let autoModels = try XCTUnwrap(autoRoot["models"] as? [[String: Any]])
        let autoFlash = try XCTUnwrap(autoModels.first)
        XCTAssertEqual(autoFlash["context_window"] as? Int, 1_000_000)
        let autoLevels = try XCTUnwrap(autoFlash["supported_reasoning_levels"] as? [[String: Any]])
        XCTAssertEqual(
            autoLevels.compactMap { $0["effort"] as? String },
            ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        )
    }

    func testCodexCatalogStripsCodeModeAndCustomToolsOnNativeResponsesLeg() throws {
        // Non-vendor native leg (a codex-api-key GPT provider): strip tool_mode,
        // apply_patch_tool_type, web_search_tool_type -- these make Codex try protocol
        // features gateways without a CPA-side translator don't implement.
        let data = try CodexModelCatalogWriter.buildCatalogJSON(
            modelIDs: ["gpt-5.6-sol"],
            routingLegs: ["gpt-5.6-sol": .codexAPIKeyNative(baseURL: "https://gpt.acme.example")]
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(root["models"] as? [[String: Any]])
        let entry = try XCTUnwrap(models.first)
        XCTAssertNil(entry["tool_mode"])
        XCTAssertNil(entry["apply_patch_tool_type"])
        XCTAssertNil(entry["web_search_tool_type"])
        XCTAssertEqual(entry["shell_type"] as? String, "shell_command")
    }

    func testCodexCatalogUsesDeepSeekOfficialTemplateOnNativeResponsesLeg() throws {
        // DeepSeek's own official Codex catalog is authoritative on the native leg: it
        // deliberately KEEPS apply_patch_tool_type (DeepSeek's real backend supports it) but
        // carries no tool_mode. This pins the actual bug: a `deepseek-v4-flash` catalog entry
        // with `tool_mode: code_mode_only` (inherited from a GPT template) is what made DeepSeek
        // emit garbled "<|DSML|tool_calls>" text instead of a real tool call when Codex tried a
        // code-mode/custom tool over this leg -- DeepSeek's backend only whitelists `apply_patch`
        // as a custom tool and rejects any other by name.
        let data = try CodexModelCatalogWriter.buildCatalogJSON(
            modelIDs: ["deepseek-v4-flash"],
            routingLegs: ["deepseek-v4-flash": .codexAPIKeyNative(baseURL: "https://api.deepseek.com")]
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(root["models"] as? [[String: Any]])
        let entry = try XCTUnwrap(models.first)
        // The vendor JSON spells this an explicit `"tool_mode": null`, not an absent key, so
        // the round trip through JSONSerialization keeps it present as NSNull -- only its
        // *value* matters to Codex's parser (both are Option::None), so assert on that instead
        // of key presence.
        XCTAssertNotEqual(entry["tool_mode"] as? String, "code_mode_only")
        XCTAssertEqual(entry["apply_patch_tool_type"] as? String, "freeform")
        XCTAssertEqual(entry["input_modalities"] as? [String], ["text"])
    }

    func testCodexCatalogKeepsCustomToolsOnProxyChatLeg() throws {
        // openai-compatibility: CPA translates Responses<->Chat itself, so the generic template
        // is trusted as-is (no stripping) -- this is the leg that has always worked for DeepSeek.
        let data = try CodexModelCatalogWriter.buildCatalogJSON(
            modelIDs: ["deepseek-v4-flash"],
            routingLegs: ["deepseek-v4-flash": .openAICompatibility]
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(root["models"] as? [[String: Any]])
        let entry = try XCTUnwrap(models.first)
        XCTAssertEqual(entry["apply_patch_tool_type"] as? String, "freeform")
    }

    func testCatalogRoundTripKeepsOnlyRealOverrides() throws {
        let overrides: [String: AgentModelOverride] = [
            "deepseek-v4-flash-ioa": AgentModelOverride(
                contextWindow: 384_000,
                reasoningLevels: ["high", "max"]
            ),
        ]
        let data = try CodexModelCatalogWriter.buildCatalogJSON(
            modelIDs: ["deepseek-v4-flash-ioa", "gpt-5.6-sol"],
            overrides: overrides
        )
        let parsed = CodexModelCatalogWriter.parseCatalog(data)
        XCTAssertEqual(parsed.modelIDs, ["deepseek-v4-flash-ioa", "gpt-5.6-sol"])
        XCTAssertEqual(parsed.overrides["deepseek-v4-flash-ioa"]?.contextWindow, 384_000)
        XCTAssertEqual(parsed.overrides["deepseek-v4-flash-ioa"]?.reasoningLevels, ["high", "max"])
        // gpt-5.6-sol was written from its auto-resolved defaults, so it must not become an override.
        XCTAssertNil(parsed.overrides["gpt-5.6-sol"])
    }

    func testReadCatalogResolvesRelativePathLikeCodex() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = try CodexModelCatalogWriter.buildCatalogJSON(modelIDs: ["kimi-k2"])
        try data.write(to: dir.appendingPathComponent(CodexModelCatalogWriter.filename))

        let parsed = CodexModelCatalogWriter.readCatalog(
            pathFromConfig: CodexModelCatalogWriter.filename,
            configDirectory: dir
        )
        XCTAssertEqual(parsed?.modelIDs, ["kimi-k2"])
        XCTAssertNil(
            CodexModelCatalogWriter.readCatalog(pathFromConfig: "missing.json", configDirectory: dir)
        )
    }

    func testAgentSettingsDecodesFilesWrittenBeforeRestoreFlagExisted() throws {
        let legacy = """
        {"currentProviderIDs":{"codex":"abc"},"unifyCodexSessionHistory":true,\
        "migrateCodexSessionsOnUnify":true}
        """
        let settings = try JSONDecoder().decode(AgentSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.currentProviderID(for: .codex), "abc")
        XCTAssertTrue(settings.migrateCodexSessionsOnUnify)
        XCTAssertTrue(settings.restoreCodexSessionsOnDisableUnify)
    }

    func testCapabilityEditorOnlyOffersFieldsThatReachDisk() {
        XCTAssertTrue(AgentModelCapabilityEditor.supportsContextWindow(.codex))
        XCTAssertTrue(AgentModelCapabilityEditor.supportsReasoningLevels(.codex))
        // settings.json has no per-model capability schema at all.
        XCTAssertFalse(AgentModelCapabilityEditor.hasEditableCapabilities(.claude))
    }

    func testContextWindowFormatKAndM() {
        XCTAssertEqual(ContextWindowFormat.display(1_000_000), "1M")
        XCTAssertEqual(ContextWindowFormat.display(272_000), "272K")
        XCTAssertEqual(ContextWindowFormat.display(128_000), "128K")
        XCTAssertEqual(ContextWindowFormat.display(500), "500")
        XCTAssertEqual(ContextWindowFormat.parse("1M"), 1_000_000)
        XCTAssertEqual(ContextWindowFormat.parse("1m"), 1_000_000)
        XCTAssertEqual(ContextWindowFormat.parse("272K"), 272_000)
        XCTAssertEqual(ContextWindowFormat.parse("384k"), 384_000)
        XCTAssertEqual(ContextWindowFormat.parse("1.5M"), 1_500_000)
        XCTAssertEqual(ContextWindowFormat.parse("1,000,000"), 1_000_000)
        XCTAssertNil(ContextWindowFormat.parse(""))
        XCTAssertNil(ContextWindowFormat.parse("abc"))
    }

    func testNormalizeComparableEndpoint() {
        XCTAssertEqual(
            AgentLiveConfigReader.normalizeComparableEndpoint("http://127.0.0.1:8317/", agent: .claude),
            "http://127.0.0.1:8317"
        )
        XCTAssertEqual(
            AgentLiveConfigReader.normalizeComparableEndpoint("http://127.0.0.1:8317", agent: .codex),
            "http://127.0.0.1:8317/v1"
        )
        XCTAssertEqual(
            AgentLiveConfigReader.normalizeComparableEndpoint("http://127.0.0.1:8317/v1/", agent: .codex),
            "http://127.0.0.1:8317/v1"
        )
        XCTAssertTrue(
            AgentLiveConfigReader.endpointsMatch(
                "http://127.0.0.1:28317/v1",
                "http://127.0.0.1:28317/v1/",
                agent: .codex
            )
        )
        XCTAssertFalse(
            AgentLiveConfigReader.endpointsMatch(
                "http://127.0.0.1:28317/v1",
                "http://127.0.0.1:38317/v1",
                agent: .codex
            )
        )
        XCTAssertEqual(
            AgentProviderProfile.localCPA(agent: .codex, port: 28317, apiKey: "k").endpoint,
            "http://127.0.0.1:28317/v1"
        )
    }

    func testCodexUnifyRewritesOnlyOpenAIProviderSurgically() {
        let line = #"{"timestamp":"t","type":"session_meta","payload":{"id":"s1","model_provider":"openai","cwd":"/tmp","note":"keep \"openai\" text"}}"#
        let rewritten = CodexSessionUnifier.rewriteSessionMetaProvider(line)
        XCTAssertEqual(
            rewritten,
            #"{"timestamp":"t","type":"session_meta","payload":{"id":"s1","model_provider":"custom","cwd":"/tmp","note":"keep \"openai\" text"}}"#
        )
        // Already custom — no-op.
        XCTAssertNil(CodexSessionUnifier.rewriteSessionMetaProvider(rewritten!))
        // Non session_meta — no-op.
        XCTAssertNil(CodexSessionUnifier.rewriteSessionMetaProvider(#"{"type":"event","payload":{"model_provider":"openai"}}"#))
        // Spaced JSON still works; only the provider token changes.
        let spaced = #"{ "type" : "session_meta" , "payload" : { "model_provider" : "openai", "id":"x" } }"#
        let spacedOut = CodexSessionUnifier.rewriteSessionMetaProvider(spaced)
        XCTAssertEqual(spacedOut, #"{ "type" : "session_meta" , "payload" : { "model_provider" : "custom", "id":"x" } }"#)
    }

    func testCodexUnifyMigrationRoundTripOnTempRoots() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("codex-unify-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions/2026/08/03", isDirectory: true)
        let archived = root.appendingPathComponent("archived_sessions", isDirectory: true)
        let backup = root.appendingPathComponent("backup", isDirectory: true)
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        try fm.createDirectory(at: archived, withIntermediateDirectories: true)

        let openaiFile = sessions.appendingPathComponent("rollout-openai.jsonl")
        let customFile = sessions.appendingPathComponent("rollout-custom.jsonl")
        let openaiBody = """
        {"type":"session_meta","payload":{"id":"a","model_provider":"openai","marker":"KEEP"}}
        {"type":"event","payload":{"text":"hello openai"}}
        """
        let customBody = """
        {"type":"session_meta","payload":{"id":"b","model_provider":"custom"}}
        {"type":"event","payload":{"text":"noop"}}
        """
        try openaiBody.write(to: openaiFile, atomically: true, encoding: .utf8)
        try customBody.write(to: customFile, atomically: true, encoding: .utf8)

        let dbURL = root.appendingPathComponent("state_5.sqlite")
        try createTempCodexStateDB(at: dbURL, providers: ["openai", "openai", "custom"])

        let result = try CodexSessionUnifier.migrateOfficialSessionsToCustom(
            sessionsRoot: root.appendingPathComponent("sessions"),
            archivedRoot: archived,
            stateDB: dbURL,
            backupRoot: backup
        )
        XCTAssertEqual(result.jsonlRewritten, 1)
        XCTAssertEqual(result.sqliteUpdated, 2)
        XCTAssertNotNil(result.backupDirectory)

        let migrated = try String(contentsOf: openaiFile, encoding: .utf8)
        XCTAssertTrue(migrated.contains(#""model_provider":"custom""#))
        XCTAssertTrue(migrated.contains(#""marker":"KEEP""#))
        XCTAssertTrue(migrated.contains(#""text":"hello openai""#))
        XCTAssertFalse(migrated.contains(#""model_provider":"openai""#))

        let untouched = try String(contentsOf: customFile, encoding: .utf8)
        XCTAssertEqual(untouched, customBody)

        // Backup retains the pre-migration openai line.
        let backupFile = backup.appendingPathComponent(
            openaiFile.path.replacingOccurrences(of: fm.homeDirectoryForCurrentUser.path + "/", with: "")
        )
        // relativePath falls back to lastPathComponent when outside home — accept either layout.
        let backupCandidates = [
            backup.appendingPathComponent(openaiFile.lastPathComponent),
            backupFile,
        ]
        let backupHit = backupCandidates.first { fm.fileExists(atPath: $0.path) }
            ?? fm.enumerator(at: backup, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .first { $0.lastPathComponent == openaiFile.lastPathComponent }
        XCTAssertNotNil(backupHit)
        let backupText = try String(contentsOf: backupHit!, encoding: .utf8)
        XCTAssertTrue(backupText.contains(#""model_provider":"openai""#))

        // Idempotent second pass.
        let again = try CodexSessionUnifier.migrateOfficialSessionsToCustom(
            sessionsRoot: root.appendingPathComponent("sessions"),
            archivedRoot: archived,
            stateDB: dbURL,
            backupRoot: root.appendingPathComponent("backup2")
        )
        XCTAssertEqual(again.jsonlRewritten, 0)
        XCTAssertEqual(again.sqliteUpdated, 0)

        // Restore only ledger sessions (id=a / first two openai rows → now custom).
        // Simulate a post-unify new session that must stay in custom.
        let onPeriod = sessions.appendingPathComponent("rollout-on-period.jsonl")
        try """
        {"type":"session_meta","payload":{"id":"new","model_provider":"custom"}}
        """.write(to: onPeriod, atomically: true, encoding: .utf8)

        // Build a fake ledger generation under a temp AppPaths-like layout is hard;
        // exercise the testable restore entry with explicit id sets instead.
        let restoreBackup = root.appendingPathComponent("restore-backup", isDirectory: true)
        let restored = try CodexSessionUnifier.restoreOfficialSessionsFromBackups(
            sessionsRoot: root.appendingPathComponent("sessions"),
            archivedRoot: archived,
            stateDB: dbURL,
            restoreBackupRoot: restoreBackup,
            sessionIDs: ["a"],
            threadIDs: ["1", "2"]
        )
        XCTAssertEqual(restored.jsonlRestored, 1)
        XCTAssertNil(restored.skippedReason)

        let afterRestore = try String(contentsOf: openaiFile, encoding: .utf8)
        XCTAssertTrue(afterRestore.contains(#""model_provider":"openai""#))
        let onPeriodText = try String(contentsOf: onPeriod, encoding: .utf8)
        XCTAssertTrue(onPeriodText.contains(#""model_provider":"custom""#))
    }

    private func createTempCodexStateDB(at url: URL, providers: [String]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        // Match Codex: id is TEXT so restore can bind session/thread ids as strings.
        XCTAssertEqual(
            sqlite3_exec(
                db,
                "CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT);",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        for (index, provider) in providers.enumerated() {
            let id = "\(index + 1)"
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO threads(id, model_provider) VALUES (?, ?);", -1, &stmt, nil)
            id.withCString { sqlite3_bind_text(stmt, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            provider.withCString { sqlite3_bind_text(stmt, 2, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Codex CPA auth.json placeholder

    func testCodexCPAAuthIdentifiesOnlyThePlaceholder() {
        XCTAssertTrue(CodexCPAAuthFile.isCreatedByCPA(CodexCPAAuthFile.payloadData()))
        XCTAssertTrue(CodexCPAAuthFile.isCreatedByCPA(text: #"{"OPENAI_API_KEY":"cpa","auth_mode":"apikey"}"#))
        XCTAssertFalse(CodexCPAAuthFile.isCreatedByCPA(text: #"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-real"}"#))
        XCTAssertFalse(CodexCPAAuthFile.isCreatedByCPA(text: #"{"auth_mode":"chatgpt","tokens":{"access_token":"t"}}"#))
        XCTAssertFalse(
            CodexCPAAuthFile.isCreatedByCPA(
                text: #"{"auth_mode":"apikey","OPENAI_API_KEY":"cpa","tokens":{"access_token":"t"}}"#
            )
        )
        XCTAssertFalse(CodexCPAAuthFile.isCreatedByCPA(text: "not-json"))
    }

    func testCodexCPAAuthCreatesOnlyWhenMissingAndRemovesOnlyPlaceholder() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            "codex-cpa-auth-\(UUID().uuidString)",
            isDirectory: true
        )
        let url = dir.appendingPathComponent("auth.json")
        defer { try? fm.removeItem(at: dir) }

        try CodexCPAAuthFile.sync(url: url, enableCPA: true)
        XCTAssertTrue(fm.fileExists(atPath: url.path))
        let created = try Data(contentsOf: url)
        XCTAssertTrue(CodexCPAAuthFile.isCreatedByCPA(created))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: created) as? [String: Any])
        XCTAssertEqual(parsed["auth_mode"] as? String, "apikey")
        XCTAssertEqual(parsed["OPENAI_API_KEY"] as? String, "cpa")

        // Second enable must not clobber a file that already exists, even ours.
        let marker = Data("leave-me".utf8)
        try marker.write(to: url)
        try CodexCPAAuthFile.sync(url: url, enableCPA: true)
        XCTAssertEqual(try Data(contentsOf: url), marker)

        // Foreign content is never deleted on switch-away.
        try CodexCPAAuthFile.sync(url: url, enableCPA: false)
        XCTAssertTrue(fm.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url), marker)

        try CodexCPAAuthFile.payloadData().write(to: url)
        try CodexCPAAuthFile.sync(url: url, enableCPA: false)
        XCTAssertFalse(fm.fileExists(atPath: url.path))

        // Missing file is a no-op both ways.
        try CodexCPAAuthFile.sync(url: url, enableCPA: false)
        try CodexCPAAuthFile.sync(url: url, enableCPA: true)
        XCTAssertTrue(fm.fileExists(atPath: url.path))
    }

    func testCodexCPAAuthRepairDesktopCustomModelsForceDeletesThenWritesPlaceholder() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            "codex-cpa-repair-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let auth = dir.appendingPathComponent("auth.json")
        let state = dir.appendingPathComponent(".codex-global-state.json")
        let backup = dir.appendingPathComponent(".codex-global-state.json.back")
        try Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"keep-me-not"}}"#.utf8)
            .write(to: auth)
        try Data("state".utf8).write(to: state)
        try Data("backup".utf8).write(to: backup)

        let result = try CodexCPAAuthFile.repairDesktopCustomModels(codexDirectory: dir)
        XCTAssertEqual(
            Set(result.removed),
            ["auth.json", ".codex-global-state.json", ".codex-global-state.json.back"]
        )
        XCTAssertFalse(fm.fileExists(atPath: state.path))
        XCTAssertFalse(fm.fileExists(atPath: backup.path))
        XCTAssertTrue(CodexCPAAuthFile.isCreatedByCPA(try Data(contentsOf: auth)))

        // Missing files are fine; auth.json is still rewritten.
        try fm.removeItem(at: auth)
        let again = try CodexCPAAuthFile.repairDesktopCustomModels(codexDirectory: dir)
        XCTAssertTrue(again.removed.isEmpty)
        XCTAssertTrue(CodexCPAAuthFile.isCreatedByCPA(try Data(contentsOf: auth)))
    }
}
