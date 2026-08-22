import Foundation
import XCTest
@testable import MacCLIProxyAPI

final class CoreInstallServiceTests: XCTestCase {
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
