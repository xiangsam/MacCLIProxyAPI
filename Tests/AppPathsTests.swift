import XCTest
@testable import MacCLIProxyAPI

// Note: test host loads app sources; these are lightweight pure tests.

final class AppPathsTests: XCTestCase {
    func testNormalizeVersion() {
        XCTAssertEqual(AppPaths.normalizeVersion("v7.2.101"), "7.2.101")
        XCTAssertEqual(AppPaths.normalizeVersion("7.2.101"), "7.2.101")
        XCTAssertEqual(AppPaths.normalizeVersion(" V1.0 "), "1.0")
    }

    func testDefaultAuthDirResolvesToOAuth() {
        let resolved = AppPaths.resolveAuthDirectory(authDir: "../oauth")
        XCTAssertEqual(resolved.lastPathComponent, "oauth")
    }

    func testManagementURLPathSanity() {
        let client = ManagementClient(port: 8317, secretKey: "123456")
        XCTAssertEqual(client.port, 8317)
        XCTAssertEqual(client.secretKey, "123456")
    }

    func testAppPageGate() {
        XCTAssertFalse(AppPage.home.requiresCoreRunning)
        XCTAssertFalse(AppPage.config.requiresCoreRunning)
        XCTAssertTrue(AppPage.oauth.requiresCoreRunning)
        XCTAssertFalse(AppPage.agents.requiresCoreRunning)
        XCTAssertFalse(AppPage.remoteSSH.requiresCoreRunning)
        // Usage history lives in local SQLite, so it stays readable with the kernel stopped.
        XCTAssertFalse(AppPage.usageRecords.requiresCoreRunning)
    }

    func testProcessCommandMustMatchOwnedBinaryAndConfig() {
        let binary = "/Users/test/Library/Application Support/com.maccliproxyapi/cpa-core/cli-proxy-api"
        let config = "/Users/test/Library/Application Support/com.maccliproxyapi/cpa-core/config.yaml"

        XCTAssertTrue(CoreProcessService.commandLineBelongsToApp(
            "\(binary) -config \(config)",
            binaryPath: binary,
            configPath: config
        ))
        XCTAssertFalse(CoreProcessService.commandLineBelongsToApp(
            "/opt/homebrew/bin/cli-proxy-api -config /tmp/config.yaml",
            binaryPath: binary,
            configPath: config
        ))
    }
}
