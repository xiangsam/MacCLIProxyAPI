import Foundation
import XCTest
@testable import MacCLIProxyAPI

@MainActor
final class GuiConfigStoreTests: XCTestCase {
    func testFirstRunGeneratesNonDefaultSecretsAndPrivateFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCLIProxyAPI-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.toml")
        let keysURL = root.appendingPathComponent("api-keys.json")
        let store = GuiConfigStore(fileURL: configURL, apiKeysURL: keysURL)
        let config = store.snapshot()

        XCTAssertEqual(config.apiKeys.count, 1)
        XCTAssertTrue(config.apiKeys[0].apiKey.hasPrefix("sk-"))
        XCTAssertNotEqual(config.apiKeys[0].apiKey, AppPaths.defaultAPIKey)
        XCTAssertGreaterThanOrEqual(config.apiKeys[0].apiKey.count, 35)
        XCTAssertNotEqual(config.managementSecretKey, AppPaths.defaultManagementSecret)
        XCTAssertGreaterThanOrEqual(config.managementSecretKey.count, 32)

        XCTAssertEqual(try permissions(configURL), 0o600)
        XCTAssertEqual(try permissions(keysURL), 0o600)
        XCTAssertEqual(try permissions(root), 0o700)
    }

    func testExistingConfigurationKeepsItsSecrets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCLIProxyAPI-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let configURL = root.appendingPathComponent("config.toml")
        let keysURL = root.appendingPathComponent("api-keys.json")
        try """
        port = 8317
        management-secret-key = "existing-secret"
        api-keys = ["existing-key"]
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let keyData = try JSONSerialization.data(
            withJSONObject: [["apiKey": "existing-key", "remark": "existing"]],
            options: []
        )
        try keyData.write(to: keysURL)

        let config = GuiConfigStore(fileURL: configURL, apiKeysURL: keysURL).snapshot()
        XCTAssertEqual(config.managementSecretKey, "existing-secret")
        XCTAssertEqual(config.apiKeys, [GuiApiKey(apiKey: "existing-key", remark: "existing")])
        XCTAssertEqual(try permissions(configURL), 0o600)
        XCTAssertEqual(try permissions(keysURL), 0o600)
    }

    func testNormalizeSessionAffinityTTL() {
        XCTAssertEqual(CoreConfigStore.normalizeSessionAffinityTTL(""), "1h")
        XCTAssertEqual(CoreConfigStore.normalizeSessionAffinityTTL("30"), "30s")
        XCTAssertEqual(CoreConfigStore.normalizeSessionAffinityTTL(" 3600 "), "3600s")
        XCTAssertEqual(CoreConfigStore.normalizeSessionAffinityTTL("30m"), "30m")
        XCTAssertEqual(CoreConfigStore.normalizeSessionAffinityTTL("1h"), "1h")
    }

    func testOptimizeCodexMultiAgentV2DefaultsOn() {
        XCTAssertTrue(GuiConfigFile().optimizeCodexMultiAgentV2)
        XCTAssertTrue(GuiConfigFile().coreConfigSettings.optimizeCodexMultiAgentV2)
    }

    func testOptimizeCodexMultiAgentV2RoundTripsThroughTOML() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCLIProxyAPI-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let configURL = root.appendingPathComponent("config.toml")
        let keysURL = root.appendingPathComponent("api-keys.json")
        try """
        port = 8317
        management-secret-key = "existing-secret"
        optimize-codex-multi-agent-v2 = false
        api-keys = ["existing-key"]
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let keyData = try JSONSerialization.data(
            withJSONObject: [["apiKey": "existing-key", "remark": ""]],
            options: []
        )
        try keyData.write(to: keysURL)

        let store = GuiConfigStore(fileURL: configURL, apiKeysURL: keysURL)
        XCTAssertFalse(store.snapshot().optimizeCodexMultiAgentV2)

        _ = try store.update { $0.optimizeCodexMultiAgentV2 = true }
        let reloaded = GuiConfigStore(fileURL: configURL, apiKeysURL: keysURL).snapshot()
        XCTAssertTrue(reloaded.optimizeCodexMultiAgentV2)
        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("optimize-codex-multi-agent-v2 = true"))
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }
}
