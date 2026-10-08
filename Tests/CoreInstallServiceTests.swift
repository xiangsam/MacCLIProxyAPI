import Foundation
import XCTest
@testable import MacCLIProxyAPI

final class CoreInstallServiceTests: XCTestCase {
    func testPatchedAndOfficialArchivesHaveSeparateDistributionChannels() throws {
        let patched = try XCTUnwrap(CoreInstallService.downloadURL(version: "8.0.21-mac.1", assetName: "core.tar.gz"))
        XCTAssertEqual(patched.path, "/xiangsam/MacCLIProxyAPI/releases/download/cpa-v8.0.21-mac.1/core.tar.gz")
        let official = try XCTUnwrap(CoreInstallService.downloadURL(version: "7.2.119", assetName: "core.tar.gz"))
        XCTAssertEqual(official.path, "/router-for-me/CLIProxyAPI/releases/download/v7.2.119/core.tar.gz")
    }

    func testArchiveFileNameValidation() {
        XCTAssertNoThrow(try CoreInstallService.validateArchiveFileName("CLIProxyAPI_1.0_darwin_aarch64.tar.gz"))
        XCTAssertNoThrow(try CoreInstallService.validateArchiveFileName("core.tgz"))
        XCTAssertThrowsError(try CoreInstallService.validateArchiveFileName("core.zip"))
        XCTAssertThrowsError(try CoreInstallService.validateArchiveFileName("core.tar"))
    }

    func testArchiveEntryValidationAcceptsNormalArchive() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try "binary".write(
            to: payload.appendingPathComponent("cli-proxy-api"),
            atomically: true,
            encoding: .utf8
        )
        let archive = root.appendingPathComponent("core.tar.gz")
        try createArchive(sourceDirectory: payload, archive: archive)

        XCTAssertNoThrow(try CoreInstallService.validateArchiveEntries(archive))
    }

    func testStagedCoreRejectsWrongArchitectureOrNonMachO() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent(AppPaths.coreBinaryName)
        try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        XCTAssertThrowsError(try CoreInstallService.validateStagedCore(in: root, expectedArch: "arm64"))
    }

    func testInstallMigratesBeforeReplacementAndPreservesNestedOAuth() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try prepareInstall(root)
        let original = try Data(contentsOf: paths.install.appendingPathComponent("config.yaml"))
        _ = try await CoreInstallService().finalizeInstall(version: "8.0.21-mac.1", assetName: "test.tar.gz",
            staging: paths.staging, install: paths.install, backup: paths.backup, migrationBackups: paths.snapshots)
        let yaml = try String(contentsOf: paths.install.appendingPathComponent("config.yaml"))
        XCTAssertEqual(CoreConfigLayout.value(try CoreConfigLayout.parse(yaml), "server.port") as? Int, 9345)
        XCTAssertEqual(try Data(contentsOf: paths.install.appendingPathComponent("auth/account.json")), Data("{}".utf8))
        XCTAssertEqual(try Data(contentsOf: paths.backup.appendingPathComponent("config.yaml")), original)
        let snapshots = try FileManager.default.contentsOfDirectory(at: paths.snapshots, includingPropertiesForKeys: nil)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(try Data(contentsOf: snapshots[0]), original)
    }

    func testInvalidConfigDoesNotReplaceInstallOrDeletePriorBackup() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try prepareInstall(root)
        try "[bad]".write(to: paths.install.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: paths.backup, withIntermediateDirectories: true)
        try "keep".write(to: paths.backup.appendingPathComponent("sentinel"), atomically: true, encoding: .utf8)
        do {
            _ = try await CoreInstallService().finalizeInstall(version: "8.0.21", assetName: "test.tar.gz",
                staging: paths.staging, install: paths.install, backup: paths.backup, migrationBackups: paths.snapshots)
            XCTFail("Invalid configuration should abort installation")
        } catch { }
        XCTAssertEqual(try String(contentsOf: paths.install.appendingPathComponent(AppPaths.coreBinaryName)), "old")
        XCTAssertEqual(try String(contentsOf: paths.backup.appendingPathComponent("sentinel")), "keep")
    }

    func testFailedInstallRestoresOldBinaryConfigAndOAuth() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try prepareInstall(root)
        // Force metadata write failure after the new binary/config have been moved in.
        try FileManager.default.createDirectory(at: paths.staging.appendingPathComponent(AppPaths.coreMetadataFile), withIntermediateDirectories: true)
        do {
            _ = try await CoreInstallService().finalizeInstall(version: "8.0.21", assetName: "test.tar.gz",
                staging: paths.staging, install: paths.install, backup: paths.backup, migrationBackups: paths.snapshots)
            XCTFail("Metadata write should fail")
        } catch { }
        XCTAssertEqual(try String(contentsOf: paths.install.appendingPathComponent(AppPaths.coreBinaryName)), "old")
        let yaml = try String(contentsOf: paths.install.appendingPathComponent("config.yaml"))
        XCTAssertFalse(CoreConfigLayout.isV8(try CoreConfigLayout.parse(yaml)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.install.appendingPathComponent("auth/account.json").path))
    }

    private func prepareInstall(_ root: URL) throws -> (install: URL, staging: URL, backup: URL, snapshots: URL) {
        let install = root.appendingPathComponent("install")
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: install.appendingPathComponent("auth"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try "old".write(to: install.appendingPathComponent(AppPaths.coreBinaryName), atomically: true, encoding: .utf8)
        try "new".write(to: staging.appendingPathComponent(AppPaths.coreBinaryName), atomically: true, encoding: .utf8)
        try "port: 9345\nauth-dir: auth\napi-keys: [test-key]\n".write(to: install.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        try "{}".write(to: install.appendingPathComponent("auth/account.json"), atomically: true, encoding: .utf8)
        return (install, staging, root.appendingPathComponent("backup"), root.appendingPathComponent("snapshots"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacCLIProxyAPI-install-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createArchive(sourceDirectory: URL, archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", archive.path, "-C", sourceDirectory.path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
