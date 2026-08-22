import Foundation
import XCTest
@testable import MacCLIProxyAPI

final class DiagnosticServiceTests: XCTestCase {
    func testFileCheckReportsPrivatePermissions() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("test".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let check = DiagnosticService.fileCheck(
            id: "test",
            title: "Test",
            url: url,
            permissions: 0o600
        )
        XCTAssertEqual(check.level, .pass)
    }
}
