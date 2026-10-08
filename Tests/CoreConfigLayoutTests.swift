import Foundation
import XCTest
@testable import MacCLIProxyAPI

final class CoreConfigLayoutTests: XCTestCase {
    private let legacy = """
    host: 127.0.0.1
    port: 9345
    api-keys: [client-secret]
    remote-management: {secret-key: test-secret, allow-remote: false}
    auth-dir: ../oauth
    proxy-url: http://localhost:7890
    request-retry: 4
    codex: {optimize-multi-agent-v2: true, response-steering: false}
    oauth-excluded-models: {codex: [gpt-custom]}
    payload: {override: [{models: [{name: alias}], params: {reasoning.effort: high}}]}
    codex-api-key:
      - api-key: deepseek-secret
        base-url: https://api.deepseek.com
        priority: 9
        models: [{name: deepseek-v4-flash, alias: deepseek-fast}]
        headers: {X-Custom: keep}
        websockets: false
    openai-compatibility:
      - name: Other
        base-url: https://other.example/v1
        api-key-entries: [{api-key: other-secret, weight: 3}]
        models: [{name: custom}]
    extension-unknown: {nested: [keep-me]}
    """
    private let grouped = """
    config-version: 8
    server: {host: 127.0.0.1, port: 9345}
    access: {api-keys: [client-secret]}
    client: {codex: {optimize-multi-agent-v2: false}}
    api-keys:
      codex:
        - name: DeepSeek Production
          base-url: https://api.deepseek.com
          priority: 9
          models: [{name: deepseek-v4-flash}, {name: gpt-5.6-test}]
          excluded-models: [custom-exclusion]
          keys:
            - api-key: first-key
              weight: 3
              models: null
            - api-key: second-key
              models: [{name: deepseek-v4-flash, alias: fast}]
              excluded-models: []
      openai-compatibility:
        - name: Other
          base-url: https://other.example/v1
          models: [{name: custom}]
          keys: [{api-key: third-key, weight: 2}]
    extension-unknown: {nested: keep-me}
    """

    func testLegacyMigrationPreservesEffectiveSettingsAndIsIdempotent() throws {
        let migrated = try CoreConfigLayout.migrate(legacy, to: "8.0.21-mac.1")
        try migrated.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("maccli-v8-migrated-fixture.yaml"), atomically: true, encoding: .utf8)
        let root = try CoreConfigLayout.parse(migrated)
        XCTAssertNil(root["port"])
        XCTAssertEqual(CoreConfigLayout.value(root, "server.port") as? Int, 9345)
        XCTAssertEqual(CoreConfigLayout.value(root, "access.api-keys") as? [String], ["client-secret"])
        XCTAssertEqual(CoreConfigLayout.value(root, "client.codex.optimize-multi-agent-v2") as? Bool, true)
        XCTAssertEqual(CoreConfigLayout.value(root, "upstream.codex.response-steering") as? Bool, false)
        XCTAssertEqual(CoreConfigLayout.value(root, "extension-unknown.nested") as? [String], ["keep-me"])
        let effective = try CoreConfigLayout.readLegacy(migrated)
        XCTAssertTrue(NSDictionary(dictionary: effective).isEqual(to: try CoreConfigLayout.parse(legacy)))
        XCTAssertTrue(NSDictionary(dictionary: root).isEqual(to: try CoreConfigLayout.parse(CoreConfigLayout.migrate(migrated, to: "8.0.21"))))
    }

    func testEarlyV8RetainsSupportedPathsUntilUpgrade() throws {
        let early = """
        config-version: 8
        server: {port: 8317}
        oauth:
          providers:
            codex: {optimize-multi-agent-v2: false, response-steering: true}
        """
        let edited = try CoreConfigLayout.mutate(early) {
            CoreConfigStore.applyCodexOptimizeMultiAgentV2(to: &$0, enabled: true)
        }
        let editedRoot = try CoreConfigLayout.parse(edited)
        XCTAssertNil(editedRoot["client"])
        XCTAssertNil(editedRoot["upstream"])
        XCTAssertEqual(CoreConfigLayout.value(editedRoot, "oauth.providers.codex.optimize-multi-agent-v2") as? Bool, true)
        XCTAssertEqual(CoreConfigLayout.value(editedRoot, "oauth.providers.codex.response-steering") as? Bool, true)
        let upgraded = try CoreConfigLayout.parse(CoreConfigLayout.migrate(edited, to: "8.0.21-mac.1"))
        XCTAssertEqual(CoreConfigLayout.value(upgraded, "client.codex.optimize-multi-agent-v2") as? Bool, true)
        XCTAssertEqual(CoreConfigLayout.value(upgraded, "upstream.codex.response-steering") as? Bool, true)
        let oldTarget = try CoreConfigLayout.parse(CoreConfigLayout.migrate(legacy, to: "8.0.0"))
        XCTAssertNil(oldTarget["client"])
        XCTAssertEqual(CoreConfigLayout.value(oldTarget, "oauth.providers.codex.optimize-multi-agent-v2") as? Bool, true)
        XCTAssertThrowsError(try CoreConfigLayout.migrate(grouped, to: "8.0.0"))
    }

    func testNullLegacyRoutingCanMigrateAndReceiveGUISettings() throws {
        let yaml = "routing: null\nrequest-retry: 0\nport: 8317\n"
        let migrated = try CoreConfigLayout.migrate(yaml, to: "8.0.21")
        XCTAssertEqual(CoreConfigLayout.value(try CoreConfigLayout.parse(migrated), "routing.retry.request-retry") as? Int, 0)
        XCTAssertNoThrow(try CoreConfigStore.applyGUIManagedSettings(to: migrated, gui: GuiConfigFile()))
    }

    func testMigrationBackupIsPrivateAndKeepsExactOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(("# Original comment\n" + legacy).utf8)
        try CoreConfigStore.backupBeforeMigration(data, directory: directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: files[0]), data)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? Int, 0o600)
    }

    func testEmptyV8ClientKeysDoNotResurrectFallbackKeys() throws {
        var fallback = GuiConfigFile()
        fallback.apiKeys = [GuiApiKey(apiKey: "stale", remark: "")]
        let settings = try CoreConfigStore.parseCoreSettings(from: "config-version: 8\naccess: {api-keys: []}", fallback: fallback)
        XCTAssertTrue(settings.apiKeys.isEmpty)
    }

    func testCanonicalFalseAndEmptyValuesWinMixedConfiguration() throws {
        let yaml = legacy + "\nserver: {port: 9456}\naccess: {api-keys: []}\nclient: {codex: {optimize-multi-agent-v2: false}}\napi-keys-unused: []\n"
        let root = try CoreConfigLayout.readLegacy(yaml)
        XCTAssertEqual(root["port"] as? Int, 9456)
        XCTAssertEqual(root["api-keys"] as? [String], [])
        XCTAssertEqual(CoreConfigLayout.value(root, "codex.optimize-multi-agent-v2") as? Bool, false)
    }

    func testClientKeyEditsDoNotOverwriteUpstreamGroups() throws {
        let original = try CoreConfigLayout.parse(grouped)
        let changed = try CoreConfigLayout.parse(CoreConfigStore.patchAPIKeys(in: grouped, keys: []))
        XCTAssertEqual(CoreConfigLayout.value(changed, "access.api-keys") as? [String], [])
        XCTAssertTrue(NSDictionary(dictionary: changed["api-keys"] as! [String: Any]).isEqual(to: original["api-keys"] as! [String: Any]))
        XCTAssertEqual(CoreConfigLayout.value(changed, "extension-unknown.nested") as? String, "keep-me")
    }

    func testGroupedCredentialInheritanceAndPolicyEditsPreserveOverrides() throws {
        let initial = try CoreConfigLayout.readLegacy(grouped)["codex-api-key"] as! [[String: Any]]
        XCTAssertEqual((initial[0]["models"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(initial[1]["excluded-models"] as? [String], [])
        let changed = try CoreConfigLayout.mutate(grouped) {
            CoreConfigStore.applyOverlappingModelPolicy(.subscriptionOnly, to: &$0)
        }
        let root = try CoreConfigLayout.parse(changed)
        let groups = CoreConfigLayout.value(root, "api-keys.codex") as! [[String: Any]]
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0]["name"] as? String, "DeepSeek Production")
        let keys = groups[0]["keys"] as! [[String: Any]]
        XCTAssertEqual(keys[0]["weight"] as? Int, 3)
        XCTAssertTrue(keys[0]["models"] is NSNull)
        XCTAssertEqual(keys[1]["excluded-models"] as? [String], [])
        XCTAssertEqual(keys[0]["excluded-models"] as? [String], ["custom-exclusion", "gpt-5.6*"])
        let restored = try CoreConfigLayout.mutate(changed) {
            CoreConfigStore.applyOverlappingModelPolicy(.automatic, to: &$0)
        }
        let rows = try CoreConfigLayout.readLegacy(restored)["codex-api-key"] as! [[String: Any]]
        XCTAssertEqual(rows[0]["excluded-models"] as? [String], ["custom-exclusion"])
    }

    func testGUISettingsAndNewCodexOptionWriteCanonicalPaths() throws {
        var gui = GuiConfigFile()
        gui.port = 9123
        gui.apiKeys = [GuiApiKey(apiKey: "replacement", remark: "")]
        gui.optimizeCodexMultiAgentV2 = true
        let changed = try CoreConfigStore.applyGUIManagedSettings(to: grouped, gui: gui)
        let root = try CoreConfigLayout.parse(changed)
        XCTAssertEqual(CoreConfigLayout.value(root, "server.port") as? Int, 9123)
        XCTAssertEqual(CoreConfigLayout.value(root, "client.codex.optimize-multi-agent-v2") as? Bool, true)
        XCTAssertNil(root["codex"])
        XCTAssertNil(root["port"])
        let settings = try CoreConfigStore.parseCoreSettings(from: changed, fallback: gui)
        XCTAssertEqual(settings.port, 9123)
        let minimal = try CoreConfigLayout.mutate("config-version: 8\nserver: {port: 8317}") {
            CoreConfigStore.applyCodexOptimizeMultiAgentV2(to: &$0, enabled: true)
        }
        XCTAssertEqual(CoreConfigLayout.value(try CoreConfigLayout.parse(minimal), "oauth.providers.codex.optimize-multi-agent-v2") as? Bool, true)
    }

    func testUpgradeDoesNotMergeExampleDefaultsOverUserSettings() throws {
        let template = "config-version: 8\nserver: {port: 8317}\naccess: {api-keys: [example-key]}\nrouting: {retry: {request-retry: 0}}\n"
        let output = try CoreConfigStore.mergeYAML(template: template, current: legacy, gui: GuiConfigFile())
        XCTAssertEqual(CoreConfigLayout.value(try CoreConfigLayout.parse(output), "routing.retry.request-retry") as? Int, 4)
        XCTAssertThrowsError(try CoreConfigStore.mergeYAML(template: template, current: "[invalid]", gui: GuiConfigFile()))
        XCTAssertThrowsError(try CoreConfigLayout.migrate(grouped, to: "7.2.109"))
        XCTAssertThrowsError(try CoreConfigLayout.migrate(legacy, to: "9.0.0"))
        XCTAssertThrowsError(try CoreConfigLayout.migrate("api-keys: {codex: [{keys: invalid}]}", to: "8.0.21"))
    }

    func testV8CatalogReadsNativeResponsesModelsWithProviderAttribution() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try grouped.write(to: url, atomically: true, encoding: .utf8)
        let models = AgentModelCatalogService.loadLocalProviderModels(from: url)
        XCTAssertTrue(models.contains { $0.id == "deepseek-v4-flash" && $0.owner.lowercased() == "deepseek" })
        XCTAssertTrue(models.contains { $0.id == "fast" && $0.owner.lowercased() == "deepseek" })
        XCTAssertEqual(AgentModelCatalogService.coreRoutingLegs(from: url)["fast"], .codexAPIKeyNative(baseURL: "https://api.deepseek.com"))
    }
}
