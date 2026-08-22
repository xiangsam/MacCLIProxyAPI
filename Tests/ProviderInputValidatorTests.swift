import XCTest
@testable import MacCLIProxyAPI

final class ProviderInputValidatorTests: XCTestCase {
    func testValidProviderInput() {
        XCTAssertNoThrow(try ProviderInputValidator.validate(
            name: "local-provider",
            baseURL: "https://api.example.com/v1",
            apiKey: "secret-key",
            requiresName: true
        ))
        XCTAssertNoThrow(try ProviderInputValidator.validate(
            name: nil,
            baseURL: "",
            apiKey: "secret-key",
            requiresName: false
        ))
    }

    func testRejectsInvalidBaseURLAndCredentialsInURL() {
        XCTAssertThrowsError(try ProviderInputValidator.validate(
            name: "provider",
            baseURL: "ftp://example.com",
            apiKey: "secret-key",
            requiresName: true
        ))
        XCTAssertThrowsError(try ProviderInputValidator.validate(
            name: "provider",
            baseURL: "https://user:password@example.com/v1",
            apiKey: "secret-key",
            requiresName: true
        ))
    }

    func testRejectsMissingNameKeyAndControlCharacters() {
        XCTAssertThrowsError(try ProviderInputValidator.validate(
            name: "",
            baseURL: "",
            apiKey: "secret-key",
            requiresName: true
        ))
        XCTAssertThrowsError(try ProviderInputValidator.validate(
            name: nil,
            baseURL: "",
            apiKey: "",
            requiresName: false
        ))
        XCTAssertThrowsError(try ProviderInputValidator.validate(
            name: nil,
            baseURL: "",
            apiKey: "secret\nkey",
            requiresName: false
        ))
    }
}
