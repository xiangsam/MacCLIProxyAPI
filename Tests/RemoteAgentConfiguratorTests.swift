import XCTest
@testable import MacCLIProxyAPI

final class RemoteAgentConfiguratorTests: XCTestCase {
    func testEndpointBuilder() {
        XCTAssertEqual(
            RemoteCPAEndpointBuilder.claudeBase(host: "10.0.0.8", port: 8317),
            "http://10.0.0.8:8317"
        )
        XCTAssertEqual(
            RemoteCPAEndpointBuilder.codexBase(host: "10.0.0.8", port: 8317),
            "http://10.0.0.8:8317/v1"
        )
    }

    func testResolveCPAReachableHostPrefersExplicit() throws {
        var host = RemoteSSHHost.makeNew(host: "dev", username: "u")
        host.cpaReachableHost = "192.168.1.50"
        let resolved = try RemoteAgentConfigurator.resolveCPAReachableHost(
            sshHost: host,
            lanIPv4: "10.0.0.1",
            allowLan: false
        )
        XCTAssertEqual(resolved, "192.168.1.50")
    }

    func testResolveCPAReachableHostRequiresLANWhenEmpty() {
        let host = RemoteSSHHost.makeNew(host: "dev", username: "u")
        XCTAssertThrowsError(
            try RemoteAgentConfigurator.resolveCPAReachableHost(
                sshHost: host,
                lanIPv4: nil,
                allowLan: true
            )
        )
        XCTAssertThrowsError(
            try RemoteAgentConfigurator.resolveCPAReachableHost(
                sshHost: host,
                lanIPv4: "10.0.0.1",
                allowLan: false
            )
        )
    }

    func testRemoteLocalCPAProfileAlignsEndpoints() {
        var template = AgentProviderProfile.localCPA(agent: .claude, port: 8317, apiKey: "k")
        template.setModel("claude-sonnet-4", for: .main)
        template.setModel("claude-haiku", for: .haiku)

        let profile = RemoteAgentConfigurator.remoteLocalCPAProfile(
            agent: .claude,
            template: template,
            cpaHost: "10.0.0.8",
            cpaPort: 8317,
            apiKey: "secret"
        )
        XCTAssertEqual(profile.endpoint, "http://10.0.0.8:8317")
        XCTAssertEqual(profile.apiKey, "secret")
        XCTAssertFalse(profile.isLocalCPA)
        XCTAssertEqual(profile.model(for: .main), "claude-sonnet-4")
        XCTAssertEqual(profile.model(for: .haiku), "claude-haiku")

        let codex = RemoteAgentConfigurator.remoteLocalCPAProfile(
            agent: .codex,
            template: nil,
            cpaHost: "10.0.0.8",
            cpaPort: 8317,
            apiKey: "k"
        )
        XCTAssertEqual(codex.endpoint, "http://10.0.0.8:8317/v1")
        XCTAssertFalse(codex.isLocalCPA)
    }

    func testMergeClaudeUsesRemoteEndpoint() throws {
        var profile = AgentProviderProfile.localCPA(agent: .claude, port: 1, apiKey: "tok")
        profile.endpoint = "http://10.0.0.8:8317"
        profile.isLocalCPA = false
        profile.setModel("m", for: .main)
        let data = try AgentLiveConfigWriter.mergeClaude(existingJSON: nil, profile: profile)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let env = try XCTUnwrap(json["env"] as? [String: Any])
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"] as? String, "http://10.0.0.8:8317")
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"] as? String, "tok")
        XCTAssertEqual(env["ANTHROPIC_MODEL"] as? String, "m")
    }

    func testMergeCodexUsesRemoteEndpoint() {
        var profile = AgentProviderProfile.localCPA(agent: .codex, port: 1, apiKey: "tok")
        profile.endpoint = "http://10.0.0.8:8317/v1"
        profile.isLocalCPA = false
        profile.setModel("gpt", for: .main)
        let text = AgentLiveConfigWriter.mergeCodex(
            existingText: "",
            profile: profile,
            catalogModelIDs: ["gpt", "kimi-k3"],
            catalogDirectory: "/home/dev/.codex"
        )
        XCTAssertTrue(text.contains("base_url = \"http://10.0.0.8:8317/v1\""))
        XCTAssertTrue(text.contains("model_provider = \"custom\""))
        XCTAssertTrue(text.contains("wire_api = \"responses\""))
        XCTAssertTrue(
            text.contains("model_catalog_json = \"/home/dev/.codex/\(CodexModelCatalogWriter.filename)\""),
            text
        )
    }

    /// Codex rejects a bare filename with "AbsolutePathBuf deserialized without a base path".
    func testMergeCodexWritesAbsoluteCatalogPath() {
        var profile = AgentProviderProfile.localCPA(agent: .codex, port: 1, apiKey: "tok")
        profile.setModel("gpt", for: .main)
        let text = AgentLiveConfigWriter.mergeCodex(
            existingText: "",
            profile: profile,
            catalogModelIDs: ["gpt"]
        )
        guard let value = TOMLEdit.value(text, table: nil, key: "model_catalog_json") else {
            return XCTFail("model_catalog_json missing:\n\(text)")
        }
        XCTAssertTrue(value.hasPrefix("/"), value)
        XCTAssertEqual((value as NSString).lastPathComponent, CodexModelCatalogWriter.filename)
    }

    /// A user- or cc-switch-owned catalog pointer must survive; only ours is removed.
    func testMergeCodexRemovesOnlyOwnCatalogPointer() {
        var profile = AgentProviderProfile.localCPA(agent: .codex, port: 1, apiKey: "tok")
        profile.setModel("gpt", for: .main)
        let foreign = "model_catalog_json = \"/home/dev/.codex/cc-switch-model-catalog.json\"\n"
        let kept = AgentLiveConfigWriter.mergeCodex(
            existingText: foreign,
            profile: profile,
            catalogModelIDs: []
        )
        XCTAssertTrue(kept.contains("cc-switch-model-catalog.json"), kept)

        let ours = "model_catalog_json = \"/home/dev/.codex/\(CodexModelCatalogWriter.filename)\"\n"
        let dropped = AgentLiveConfigWriter.mergeCodex(
            existingText: ours,
            profile: profile,
            catalogModelIDs: []
        )
        XCTAssertFalse(dropped.contains("model_catalog_json"), dropped)
    }

    // MARK: - Current-profile matching

    private func codexProfile(id: String, name: String, model: String, isLocalCPA: Bool = false)
        -> AgentProviderProfile
    {
        var profile = AgentProviderProfile.localCPA(agent: .codex, port: 28317, apiKey: "same-key")
        profile.id = id
        profile.name = name
        profile.isLocalCPA = isLocalCPA
        profile.setModel(model, for: .main)
        return profile
    }

    /// Every profile aimed at the local core shares endpoint and key, so without the current id
    /// the marker snaps back to whichever sorts first and enabling anything else looks undone.
    func testMatchKeepsEnabledProfileAmongIdenticalEndpoints() {
        let profiles = [
            codexProfile(id: "local", name: "本机 CPA", model: "gpt-5.6-sol", isLocalCPA: true),
            codexProfile(id: "sub", name: "Codex 订阅", model: "gpt-5.6-terra"),
        ]
        var live = AgentLiveConfigReader.Snapshot()
        live.configExists = true
        live.endpoint = "http://127.0.0.1:28317/v1"
        live.apiKey = "same-key"
        live.model = "gpt-5.6-terra"

        XCTAssertEqual(
            AgentLiveConfigReader.matchProfileID(live: live, agent: .codex, in: profiles, preferring: "sub"),
            "sub"
        )
        // Without a hint the model still disambiguates.
        XCTAssertEqual(
            AgentLiveConfigReader.matchProfileID(live: live, agent: .codex, in: profiles),
            "sub"
        )
    }

    /// A hand-edited config must still move the marker; the hint is not allowed to pin a profile
    /// the file no longer describes.
    func testMatchDropsStaleCurrentWhenConfigChanged() {
        let profiles = [
            codexProfile(id: "local", name: "本机 CPA", model: "gpt-5.6-sol", isLocalCPA: true),
            codexProfile(id: "sub", name: "Codex 订阅", model: "gpt-5.6-terra"),
        ]
        var live = AgentLiveConfigReader.Snapshot()
        live.configExists = true
        live.endpoint = "https://api.example.com/v1"
        live.apiKey = "other-key"

        XCTAssertNil(
            AgentLiveConfigReader.matchProfileID(live: live, agent: .codex, in: profiles, preferring: "sub")
        )
    }

    // MARK: - Remote compaction

    /// Codex reads the provider name, not the base URL, to decide it may compact remotely.
    func testMergeCodexNamesProviderOpenAIOnlyWhenClaimed() {
        var profile = AgentProviderProfile.localCPA(agent: .codex, port: 1, apiKey: "tok")
        profile.name = "本机 CPA"
        profile.setModel("gpt", for: .main)

        let plain = AgentLiveConfigWriter.mergeCodex(existingText: "", profile: profile)
        XCTAssertEqual(TOMLEdit.value(plain, table: "model_providers.custom", key: "name"), "本机 CPA")

        profile.claimsOpenAIProvider = true
        let claimed = AgentLiveConfigWriter.mergeCodex(existingText: "", profile: profile)
        XCTAssertEqual(TOMLEdit.value(claimed, table: "model_providers.custom", key: "name"), "OpenAI")
        // The bucket must not move, or the claim would fragment session history.
        XCTAssertEqual(TOMLEdit.value(claimed, table: nil, key: "model_provider"), "custom")
    }

    /// Saving the same provider twice must not change the file beyond the rev stamp. Rewriting
    /// the provider table re-appends it behind a blank separator while the stamp moves back above
    /// it, so an orphaned blank line used to survive every save and the config grew forever.
    func testMergeCodexDoesNotGrowConfigOnRepeatedSaves() {
        var profile = AgentProviderProfile.localCPA(agent: .codex, port: 1, apiKey: "tok")
        profile.name = "本机 CPA"
        profile.setModel("gpt", for: .main)
        profile.claimsOpenAIProvider = true

        // Keys after the provider table would be swallowed by the rewrite, so the realistic
        // shape is unrelated tables first and ours pinned at the end.
        let existing = """
        model = "gpt"

        [mcp_servers.thing]
        enabled = false

        """

        var text = AgentLiveConfigWriter.mergeCodex(existingText: existing, profile: profile)
        let first = text
        for _ in 0..<5 {
            text = AgentLiveConfigWriter.mergeCodex(existingText: text, profile: profile)
        }

        let normalize: (String) -> String = { $0.replacingOccurrences(
            of: #"(?m)^# maccliproxy-catalog-rev = \d+$"#,
            with: "# rev",
            options: .regularExpression
        ) }
        XCTAssertEqual(normalize(text), normalize(first))
        XCTAssertFalse(text.contains("\n\n\n"), "空行在累积：\n\(text)")
        XCTAssertTrue(text.contains("[mcp_servers.thing]"), "无关表被吃掉了：\n\(text)")
    }

    /// A snapshot taken before we ever touched Codex names no provider, so restoring 「默认」
    /// silently drops out of the unified bucket.
    func testRepinRestoredOfficialCodexBucket() {
        let restored = "model = \"gpt-5.6-sol\"\n"
        let repinned = AgentLiveConfigWriter.repinningOfficialCodexBucket(in: restored)
        let text = try? XCTUnwrap(repinned)
        XCTAssertEqual(TOMLEdit.value(text ?? "", table: nil, key: "model_provider"), "custom")
        XCTAssertEqual(TOMLEdit.value(text ?? "", table: "model_providers.custom", key: "name"), "OpenAI")
        XCTAssertEqual(
            TOMLEdit.value(text ?? "", table: "model_providers.custom", key: "requires_openai_auth"),
            "true"
        )
        XCTAssertTrue((text ?? "").contains("model = \"gpt-5.6-sol\""), text ?? "")

        // An explicit `openai` is the same official backend and gets re-pinned too.
        XCTAssertNotNil(AgentLiveConfigWriter.repinningOfficialCodexBucket(in: "model_provider = \"openai\"\n"))
    }

    /// Rehoming a third-party provider would point its traffic at a bucket it never wrote to.
    func testRepinLeavesThirdPartyProviderAlone() {
        let text = "model_provider = \"packycode\"\n"
        XCTAssertNil(AgentLiveConfigWriter.repinningOfficialCodexBucket(in: text))
    }

    /// The daemon pattern must not match the shell that carries it.
    ///
    /// `pkill -f` matches against whole command lines, so a plain `app-server` pattern also
    /// matches the SSH command doing the killing — which kills the connection before the daemon.
    func testAppServerPatternSpareOwnCommandLine() throws {
        let pattern = RemoteAgentConfigurator.codexAppServerPattern
        let regex = try NSRegularExpression(pattern: pattern)
        func matches(_ line: String) -> Bool {
            regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }

        XCTAssertTrue(matches("node /usr/local/bin/codex -c x=true app-server --listen unix://"))
        XCTAssertTrue(matches("/bin/sh -c nohup codex app-server --listen unix:// &"))
        XCTAssertFalse(matches("pkill -u \"$(id -u)\" -f '\(pattern)'"))
        XCTAssertFalse(matches("pgrep -u \"$(id -u)\" -f '\(pattern)' >/dev/null"))

        // Unrelated Codex-family processes on the same host must survive.
        XCTAssertFalse(matches("node /usr/local/bin/tcodex"))
        XCTAssertFalse(matches("/data/home/me/.local/share/zed/.../codex-acp"))
    }

    func testRemoteCompactionCapabilityByOwner() {
        XCTAssertTrue(AgentModelCatalogService.supportsRemoteCompaction(owner: "openai"))
        XCTAssertTrue(AgentModelCatalogService.supportsRemoteCompaction(owner: "xAI"))
        XCTAssertFalse(AgentModelCatalogService.supportsRemoteCompaction(owner: "acme"))
        XCTAssertFalse(AgentModelCatalogService.supportsRemoteCompaction(owner: "anthropic"))
    }

    /// Only flag models we have actually seen listed; an unknown id says nothing either way.
    func testModelsWithoutRemoteCompaction() {
        let known = [
            AgentModelCatalogService.Model(id: "gpt-5.6-sol", owner: "openai"),
            AgentModelCatalogService.Model(id: "kimi-k3", owner: "acme"),
        ]
        let flagged = AgentModelCatalogService.modelsWithoutRemoteCompaction(
            catalog: ["gpt-5.6-sol", "kimi-k3", "never-listed"],
            known: known
        )
        XCTAssertEqual(flagged, ["kimi-k3"])
    }

    // MARK: - Subscription isolation

    /// Enabling touches every API-key credential that declares an overlapping id, not just one.
    func testIsolationExcludesOverlapAcrossAllCredentials() {
        var root: [String: Any] = [
            "codex-api-key": [
                ["api-key": "t", "models": [["name": "gpt-5.6-sol"], ["name": "gpt-5.5"]]],
            ],
            "openai-compatibility": [
                ["name": "other", "models": [["name": "internal-gpt", "alias": "gpt-5.4"]]],
                ["name": "claude-only", "models": [["name": "claude-sonnet-5"]]],
            ],
        ]

        XCTAssertTrue(CodexSubscriptionIsolation.apply(enabled: true, to: &root))

        let codexRows = root["codex-api-key"] as? [[String: Any]]
        XCTAssertEqual(codexRows?[0]["excluded-models"] as? [String], ["gpt-5.6*", "gpt-5.5"])

        let compatRows = root["openai-compatibility"] as? [[String: Any]]
        // Matched by the row's alias, which is the id CPA actually serves.
        XCTAssertEqual(compatRows?[0]["excluded-models"] as? [String], ["gpt-5.4"])
        // No overlapping id, so no pointless key.
        XCTAssertNil(compatRows?[1]["excluded-models"])

        XCTAssertFalse(CodexSubscriptionIsolation.apply(enabled: true, to: &root), "should be idempotent")
    }

    /// Turning the switch off has to put the other providers back, without eating user entries.
    func testIsolationRevertKeepsUserExclusions() {
        var root: [String: Any] = [
            "codex-api-key": [
                [
                    "api-key": "t",
                    "models": [["name": "gpt-5.6-sol"]],
                    "excluded-models": ["gpt-4o-mini"],
                ],
            ],
        ]

        XCTAssertTrue(CodexSubscriptionIsolation.apply(enabled: true, to: &root))
        var rows = root["codex-api-key"] as? [[String: Any]]
        XCTAssertEqual(rows?[0]["excluded-models"] as? [String], ["gpt-4o-mini", "gpt-5.6*"])

        XCTAssertTrue(CodexSubscriptionIsolation.apply(enabled: false, to: &root))
        rows = root["codex-api-key"] as? [[String: Any]]
        XCTAssertEqual(rows?[0]["excluded-models"] as? [String], ["gpt-4o-mini"])
    }

    /// The remote flow carries these fields to the host, so a remote profile must move the local
    /// core's routing exactly like a local one — the remote agent hits the same core over the LAN.
    func testRemoteApplyCarriesCompactionFields() {
        var template = AgentProviderProfile.localCPA(agent: .codex, port: 28317, apiKey: "k")
        template.claimsOpenAIProvider = true
        template.codexSubscriptionOnly = true
        template.setModel("gpt-5.6-sol", for: .main)

        let remote = RemoteAgentConfigurator.remoteLocalCPAProfile(
            agent: .codex,
            template: template,
            cpaHost: "10.0.0.8",
            cpaPort: 28317,
            apiKey: "k"
        )
        XCTAssertTrue(remote.claimsOpenAIProvider)
        XCTAssertTrue(remote.codexSubscriptionOnly)

        let text = AgentLiveConfigWriter.mergeCodex(existingText: "", profile: remote)
        XCTAssertEqual(TOMLEdit.value(text, table: "model_providers.custom", key: "name"), "OpenAI")
    }

    func testIsolationWildcardMirrorsCore() {
        XCTAssertTrue(CodexSubscriptionIsolation.matches(pattern: "gpt-5.6*", value: "gpt-5.6-terra"))
        XCTAssertTrue(CodexSubscriptionIsolation.matches(pattern: "gpt-5.5", value: "gpt-5.5"))
        XCTAssertFalse(CodexSubscriptionIsolation.matches(pattern: "gpt-5.6*", value: "gpt-5.5"))
        XCTAssertFalse(CodexSubscriptionIsolation.matches(pattern: "gpt-5.5", value: "gpt-5.5-turbo"))
    }

    /// Per-model capabilities have to survive the rebuild too, otherwise the catalog pushed to the
    /// host carries the auto-derived context window and the user's setting silently does nothing.
    func testRemoteApplyCarriesModelOverrides() throws {
        var template = AgentProviderProfile.localCPA(agent: .codex, port: 28317, apiKey: "k")
        template.setModel("gpt-5.6-sol", for: .main)
        template.catalogModels = ["gpt-5.6-sol"]
        template.modelOverrides = [
            "gpt-5.6-sol": AgentModelOverride(contextWindow: 272_000, reasoningLevels: ["low", "high"])
        ]

        let remote = RemoteAgentConfigurator.remoteLocalCPAProfile(
            agent: .codex,
            template: template,
            cpaHost: "10.0.0.8",
            cpaPort: 28317,
            apiKey: "k"
        )
        XCTAssertEqual(remote.modelOverrides["gpt-5.6-sol"]?.contextWindow, 272_000)

        let data = try CodexModelCatalogWriter.buildCatalogJSON(
            modelIDs: remote.resolvedCodexCatalogModels,
            overrides: remote.modelOverrides
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(root["models"] as? [[String: Any]])
        XCTAssertEqual(models.first?["context_window"] as? Int, 272_000)
        XCTAssertEqual(models.first?["max_context_window"] as? Int, 272_000)
        let levels = try XCTUnwrap(models.first?["supported_reasoning_levels"] as? [[String: Any]])
        XCTAssertEqual(levels.compactMap { $0["effort"] as? String }, ["low", "high"])
    }

    func testCodexModelCatalogJSONShape() throws {
        let data = try CodexModelCatalogWriter.buildCatalogJSON(modelIDs: ["kimi-k3-ioa", "gpt-test"])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(root["models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0]["slug"] as? String, "kimi-k3-ioa")
        XCTAssertEqual(models[0]["display_name"] as? String, "kimi-k3-ioa")
        XCTAssertNotNil(models[0]["base_instructions"])
        XCTAssertNotNil(models[0]["supports_reasoning_summaries"])
        XCTAssertEqual(models[0]["shell_type"] as? String, "shell_command")
        XCTAssertEqual(models[0]["visibility"] as? String, "list")
        let levels = try XCTUnwrap(models[0]["supported_reasoning_levels"] as? [[String: Any]])
        XCTAssertFalse(levels.isEmpty)
        XCTAssertNotNil(levels[0]["effort"])
    }

    func testResolvedCodexCatalogModelsKeepsCatalogOrder() {
        var profile = AgentProviderProfile.localCPA(agent: .codex, port: 1, apiKey: "k")
        profile.model = "default-model"
        profile.catalogModels = ["b", "default-model", "a", ""]
        XCTAssertEqual(profile.resolvedCodexCatalogModels, ["b", "default-model", "a"])
        XCTAssertEqual(
            CodexModelCatalogWriter.resolveModelIDs(profile: profile),
            ["b", "default-model", "a"]
        )

        profile.catalogModels = ["b", "a"]
        XCTAssertEqual(profile.resolvedCodexCatalogModels, ["b", "a", "default-model"])
    }

    func testDecodeProfileWithoutCatalogModels() throws {
        let json = """
        [{"id":"c1","agent":"codex","name":"Old","endpoint":"http://127.0.0.1:1/v1","apiKey":"k","model":"m1","isLocalCPA":true,"notes":"","createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([AgentProviderProfile].self, from: Data(json.utf8))
        XCTAssertEqual(decoded[0].catalogModels, [])
        XCTAssertEqual(decoded[0].resolvedCodexCatalogModels, ["m1"])
    }

    func testLocalCatalogEndpoints() {
        XCTAssertEqual(
            RemoteAgentConfigurator.localCatalogEndpoint(agent: .claude, cpaPort: 8317),
            "http://127.0.0.1:8317"
        )
        XCTAssertEqual(
            RemoteAgentConfigurator.localCatalogEndpoint(agent: .codex, cpaPort: 8317),
            "http://127.0.0.1:8317/v1"
        )
    }

    func testRemoteDefaultSnapshotDirectory() {
        let url = AppPaths.remoteSSHDefaultDirectory(hostID: "host-1", agent: .codex)
        XCTAssertTrue(url.path.hasSuffix("defaults/host-1/codex"))
        XCTAssertFalse(RemoteAgentDefaultSnapshot.hasSnapshot(hostID: "missing-\(UUID().uuidString)", agent: .codex))
    }
}
