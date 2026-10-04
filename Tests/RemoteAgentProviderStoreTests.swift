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
    func testLocalSyncPreservesSourceAndTracksPendingChanges() throws {
        var local = AgentProviderProfile.localCPA(agent: .codex, port: 8317, apiKey: "k", model: "gpt-5.6-sol")
        var state = RemoteAgentProviderStore.importingLocalProfiles(
            [local], into: .empty, hostID: hostID, cpaHost: "192.168.1.10", cpaPort: 8317, apiKey: "k"
        )
        let remote = try XCTUnwrap(state.profiles.first)
        XCTAssertEqual(remote.endpoint, "http://192.168.1.10:8317/v1")
        XCTAssertEqual(state.sourceProfileIDs[remote.id], local.id)
        XCTAssertTrue(state.needsSync(remote))
        try RemoteAgentProviderStore.save(hostID: hostID, state: state)
        state = try RemoteAgentProviderStore.setCurrent(hostID: hostID, agent: .codex, providerID: remote.id)
        XCTAssertFalse(state.needsSync(remote))
        local.model = "gpt-5.5"
        state = RemoteAgentProviderStore.importingLocalProfiles(
            [local], into: state, hostID: hostID, cpaHost: "192.168.1.10", cpaPort: 8317, apiKey: "k"
        )
        let changed = try XCTUnwrap(state.profiles.first)
        XCTAssertTrue(state.needsSync(changed))
        XCTAssertEqual(state.appliedProfiles["codex"]?.model, "gpt-5.6-sol")
        XCTAssertEqual(state.currentProviderID(for: .codex), remote.id)
        try RemoteAgentProviderStore.save(hostID: hostID, state: state)
        XCTAssertTrue(RemoteAgentProviderStore.load(hostID: hostID).needsSync(changed))
    }

    func testDirectLocalSourceKeepsEndpointAndSnapshotIsNotShared() throws {
        var local = AgentProviderProfile.localCPA(agent: .codex, port: 8317, apiKey: "upstream-key")
        local.id = "direct"
        local.isLocalCPA = false
        local.endpoint = "https://example.com/v1"
        let state = RemoteAgentProviderStore.importingLocalProfiles(
            [local, .makeDefault(agent: .codex)], into: .empty,
            hostID: hostID, cpaHost: nil, cpaPort: 8317, apiKey: "cpa-key"
        )
        XCTAssertEqual(state.profiles.count, 1)
        XCTAssertEqual(state.profiles.first?.endpoint, local.endpoint)
        XCTAssertEqual(state.profiles.first?.apiKey, "upstream-key")
    }

    func testLegacyRemoteStateDoesNotClaimVerifiedWrite() throws {
        let data = Data(#"{"profiles":[],"currentProviderIDs":{"codex":"old"}}"#.utf8)
        let state = try JSONDecoder().decode(RemoteAgentProviderStore.State.self, from: data)
        XCTAssertTrue(state.appliedProfiles.isEmpty)
        XCTAssertTrue(state.needsSync(.official(agent: .codex)))
    }

}
