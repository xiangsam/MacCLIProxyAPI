import XCTest
@testable import MacCLIProxyAPI

final class ProviderConnectionTesterTests: XCTestCase {
    func testOpenAIRequestAvoidsDuplicateV1Path() throws {
        let provider = ProviderConfig(raw: [
            "name": "demo",
            "base-url": "https://api.example.com/v1",
            "api-key": "secret",
        ], index: 0)
        let request = try ProviderConnectionTester.makeRequest(kind: .openai, provider: provider)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    func testGeminiRequestUsesQueryKey() throws {
        let provider = ProviderConfig(raw: [
            "base-url": "https://generativelanguage.googleapis.com",
            "api-key": "secret",
        ], index: 0)
        let request = try ProviderConnectionTester.makeRequest(kind: .gemini, provider: provider)
        XCTAssertTrue(request.url?.absoluteString.contains("v1beta/models") == true)
        XCTAssertTrue(request.url?.absoluteString.contains("key=secret") == true)
    }
}
