import XCTest
@testable import MacCLIProxyAPI

final class RemoteAgentProviderStoreTests: XCTestCase {
    private var hostID: String!

    override func setUp() {
        super.setUp()
        hostID = "test-host-\(UUID().uuidString)"
        RemoteAgentProviderStore.deleteHostData(hostID: hostID)
    }

    override func tearDown() {
        RemoteAgentProviderStore.deleteHostData(hostID: hostID)
        super.tearDown()
    }

    func testEnsureLocalCPAAndDefaultThenSetCurrent() throws {
        let state = try RemoteAgentProviderStore.ensureLocalCPAProfiles(
            hostID: hostID,
            cpaHost: "192.168.1.10",
            cpaPort: 8317,
            apiKey: "sk-test"
        )
        XCTAssertEqual(state.profiles.filter(\.isLocalCPA).count, AgentKind.allCases.count)
        XCTAssertEqual(state.profiles.filter(\.isOfficial).count, AgentKind.allCases.count)

        let codexCPA = try XCTUnwrap(state.profiles.first {
            $0.agent == .codex && $0.isLocalCPA
        })
        XCTAssertTrue(codexCPA.endpoint.contains("192.168.1.10"))

        let codexOfficial = try XCTUnwrap(state.profiles.first {
            $0.agent == .codex && $0.isOfficial
        })
        XCTAssertEqual(codexOfficial.id, RemoteAgentProviderStore.officialID(hostID: hostID, agent: .codex))

        // Deleting official or local CPA is prevented
        let afterDelete = try RemoteAgentProviderStore.delete(hostID: hostID, id: codexOfficial.id)
        XCTAssertTrue(afterDelete.profiles.contains { $0.id == codexOfficial.id })

        _ = try RemoteAgentProviderStore.ensureDefaultProfile(hostID: hostID, agent: .codex)
        let withDefault = RemoteAgentProviderStore.load(hostID: hostID)
        XCTAssertTrue(withDefault.profiles.contains { $0.agent == .codex && $0.isDefault })

        let current = try RemoteAgentProviderStore.setCurrent(
            hostID: hostID,
            agent: .codex,
            providerID: codexCPA.id
        )
        XCTAssertEqual(current.currentProviderID(for: .codex), codexCPA.id)

        let defaultID = RemoteAgentProviderStore.defaultID(hostID: hostID, agent: .codex)
        let restored = try RemoteAgentProviderStore.setCurrent(
            hostID: hostID,
            agent: .codex,
            providerID: defaultID
        )
        XCTAssertEqual(restored.currentProviderID(for: .codex), defaultID)
    }

    func testDeleteHostDataRemovesProvidersFile() throws {
        _ = try RemoteAgentProviderStore.ensureLocalCPAProfiles(
            hostID: hostID,
            cpaHost: "10.0.0.1",
            cpaPort: 8317,
            apiKey: "k"
        )
        XCTAssertFalse(RemoteAgentProviderStore.load(hostID: hostID).profiles.isEmpty)
        RemoteAgentProviderStore.deleteHostData(hostID: hostID)
        XCTAssertTrue(RemoteAgentProviderStore.load(hostID: hostID).profiles.isEmpty)
    }
}
