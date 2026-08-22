import XCTest
@testable import MacCLIProxyAPI

final class OAuthServiceTests: XCTestCase {
    func testOAuthStatusClassification() {
        XCTAssertEqual(OAuthService.classifyStatus("success"), .success)
        XCTAssertEqual(OAuthService.classifyStatus("AUTHORIZED"), .success)
        XCTAssertEqual(OAuthService.classifyStatus("pending"), .pending)
        XCTAssertEqual(OAuthService.classifyStatus("cancelled"), .failure)
        XCTAssertEqual(OAuthService.classifyStatus("unsuccessful"), .unknown)
    }
}
