import Foundation

/// Per-host remote agent providers — same mental model as local Agents (list → enable).
enum RemoteAgentProviderStore {
    struct State: Equatable, Codable, Sendable {
        var profiles: [AgentProviderProfile]
        /// agent.rawValue → provider id
        var currentProviderIDs: [String: String]
        /// Remote Codex: keep new sessions in `custom` bucket (already written by enable).
        var unifyCodexSessionHistory: Bool
        /// When enabling unify, also migrate remote openai-tagged sessions → custom.
        var migrateCodexSessionsOnUnify: Bool

        static let empty = State(
            profiles: [],
            currentProviderIDs: [:],
            unifyCodexSessionHistory: true,
            migrateCodexSessionsOnUnify: false
        )

        enum CodingKeys: String, CodingKey {
            case profiles
            case currentProviderIDs
            case unifyCodexSessionHistory
            case migrateCodexSessionsOnUnify
        }

        init(
            profiles: [AgentProviderProfile],
            currentProviderIDs: [String: String],
            unifyCodexSessionHistory: Bool = true,
            migrateCodexSessionsOnUnify: Bool = false
        ) {
            self.profiles = profiles
            self.currentProviderIDs = currentProviderIDs
            self.unifyCodexSessionHistory = unifyCodexSessionHistory
            self.migrateCodexSessionsOnUnify = migrateCodexSessionsOnUnify
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            profiles = try c.decodeIfPresent([AgentProviderProfile].self, forKey: .profiles) ?? []
            currentProviderIDs = try c.decodeIfPresent([String: String].self, forKey: .currentProviderIDs) ?? [:]
            unifyCodexSessionHistory = try c.decodeIfPresent(Bool.self, forKey: .unifyCodexSessionHistory) ?? true
            migrateCodexSessionsOnUnify = try c.decodeIfPresent(Bool.self, forKey: .migrateCodexSessionsOnUnify) ?? false
        }

        func currentProviderID(for agent: AgentKind) -> String? {
            currentProviderIDs[agent.rawValue]
        }

        mutating func setCurrentProviderID(_ id: String?, for agent: AgentKind) {
            if let id {
                currentProviderIDs[agent.rawValue] = id
            } else {
                currentProviderIDs.removeValue(forKey: agent.rawValue)
            }
        }
    }

    static func localCPAID(hostID: String, agent: AgentKind) -> String {
        "remote-\(hostID)-cpa-\(agent.rawValue)"
    }

    static func defaultID(hostID: String, agent: AgentKind) -> String {
        "remote-\(hostID)-default-\(agent.rawValue)"
    }

    static func officialID(hostID: String, agent: AgentKind) -> String {
        "remote-\(hostID)-official-\(agent.rawValue)"
    }

    static func remoteOfficialProfile(hostID: String, agent: AgentKind) -> AgentProviderProfile {
        var profile = AgentProviderProfile.official(agent: agent)
        profile.id = officialID(hostID: hostID, agent: agent)
        profile.name = agent == .claude ? "Claude 官方" : "OpenAI 官方"
        return profile
    }

    static func load(hostID: String) -> State {
        let url = AppPaths.remoteSSHProvidersURL(hostID: hostID)
        guard let data = try? Data(contentsOf: url) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let migrated = migrateRemovingObsoleteAgents(from: data, decoder: decoder) {
            if migrated.dropped {
                try? save(hostID: hostID, state: migrated.state)
            }
            return migrated.state
        }

        guard let decoded = try? decoder.decode(State.self, from: data) else { return .empty }
        return decoded
    }

    /// Strip removed agent kinds from a remote providers document before decode.
    static func migrateRemovingObsoleteAgents(
        from data: Data,
        decoder: JSONDecoder
    ) -> (state: State, dropped: Bool)? {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var dropped = false

        if let profiles = root["profiles"] as? [[String: Any]] {
            let kept = profiles.filter { entry in
                guard let agent = entry["agent"] as? String else { return true }
                return !AgentProviderStore.removedAgentRawValues.contains(agent)
            }
            if kept.count != profiles.count {
                dropped = true
                root["profiles"] = kept
            }
        }

        if var ids = root["currentProviderIDs"] as? [String: String] {
            for key in AgentProviderStore.removedAgentRawValues where ids[key] != nil {
                ids.removeValue(forKey: key)
                dropped = true
            }
            root["currentProviderIDs"] = ids
        }

        guard let filteredData = try? JSONSerialization.data(withJSONObject: root),
              let state = try? decoder.decode(State.self, from: filteredData)
        else {
            return nil
        }
        return (state, dropped)
    }

    static func save(hostID: String, state: State) throws {
        try AppPaths.ensureBaseDirectories()
        try AppPaths.ensurePrivateDirectory(AppPaths.remoteSSHProvidersDirectory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: AppPaths.remoteSSHProvidersURL(hostID: hostID), options: .atomic)
        try AppPaths.secureSensitiveFile(AppPaths.remoteSSHProvidersURL(hostID: hostID))
    }

    /// Ensure each agent has Local-CPA and Official remote profiles; refresh endpoint/key, keep model mapping.
    @discardableResult
    static func ensureLocalCPAProfiles(
        hostID: String,
        cpaHost: String,
        cpaPort: UInt16,
        apiKey: String
    ) throws -> State {
        var state = load(hostID: hostID)
        var changed = false
        for agent in AgentKind.allCases {
            // 1. Official Profile
            let offID = officialID(hostID: hostID, agent: agent)
            let off = remoteOfficialProfile(hostID: hostID, agent: agent)
            if let idx = state.profiles.firstIndex(where: { $0.id == offID || ($0.agent == agent && $0.isOfficial) }) {
                var existing = state.profiles[idx]
                if !existing.isOfficial || existing.name != off.name || existing.notes != off.notes {
                    existing.isOfficial = true
                    existing.name = off.name
                    existing.notes = off.notes
                    existing.updatedAt = Date()
                    state.profiles[idx] = existing
                    changed = true
                }
            } else {
                state.profiles.append(off)
                changed = true
            }

            // 2. Local CPA Profile
            let id = localCPAID(hostID: hostID, agent: agent)
            let template = state.profiles.first(where: { $0.id == id })
            var profile = RemoteAgentConfigurator.remoteLocalCPAProfile(
                agent: agent,
                template: template,
                cpaHost: cpaHost,
                cpaPort: cpaPort,
                apiKey: apiKey
            )
            profile.id = id
            profile.isLocalCPA = true
            profile.name = "本机 CPA（远程）"
            if let idx = state.profiles.firstIndex(where: { $0.id == id }) {
                let existing = state.profiles[idx]
                if existing.endpoint != profile.endpoint
                    || existing.apiKey != profile.apiKey
                    || !existing.isLocalCPA
                    || existing.name != profile.name
                {
                    var next = existing
                    next.endpoint = profile.endpoint
                    next.apiKey = profile.apiKey
                    next.isLocalCPA = true
                    next.name = profile.name
                    next.updatedAt = Date()
                    state.profiles[idx] = next
                    changed = true
                }
            } else {
                state.profiles.append(profile)
                changed = true
            }
        }
        if changed {
            try save(hostID: hostID, state: state)
        }
        return load(hostID: hostID)
    }

    /// Ensure official profiles exist for host (called even when Local CPA info is absent).
    @discardableResult
    static func ensureOfficialProfiles(hostID: String) throws -> State {
        var state = load(hostID: hostID)
        var changed = false
        for agent in AgentKind.allCases {
            let offID = officialID(hostID: hostID, agent: agent)
            let off = remoteOfficialProfile(hostID: hostID, agent: agent)
            if let idx = state.profiles.firstIndex(where: { $0.id == offID || ($0.agent == agent && $0.isOfficial) }) {
                var existing = state.profiles[idx]
                if !existing.isOfficial || existing.name != off.name || existing.notes != off.notes {
                    existing.isOfficial = true
                    existing.name = off.name
                    existing.notes = off.notes
                    existing.updatedAt = Date()
                    state.profiles[idx] = existing
                    changed = true
                }
            } else {
                state.profiles.append(off)
                changed = true
            }
        }
        if changed {
            try save(hostID: hostID, state: state)
        }
        return load(hostID: hostID)
    }

    static func upsert(hostID: String, profile: AgentProviderProfile) throws -> State {
        var state = load(hostID: hostID)
        var next = profile
        next.updatedAt = Date()
        if let idx = state.profiles.firstIndex(where: { $0.id == profile.id }) {
            state.profiles[idx] = next
        } else {
            state.profiles.insert(next, at: 0)
        }
        try save(hostID: hostID, state: state)
        return state
    }

    static func delete(hostID: String, id: String) throws -> State {
        var state = load(hostID: hostID)
        guard let removed = state.profiles.first(where: { $0.id == id }) else { return state }
        guard !removed.isOfficial && !removed.isLocalCPA else { return state }
        state.profiles.removeAll { $0.id == id }
        for agent in AgentKind.allCases where state.currentProviderID(for: agent) == id {
            state.setCurrentProviderID(nil, for: agent)
        }
        try save(hostID: hostID, state: state)
        if removed.isDefault {
            RemoteAgentDefaultSnapshot.remove(hostID: hostID, agent: removed.agent)
        }
        return state
    }

    static func setCurrent(hostID: String, agent: AgentKind, providerID: String) throws -> State {
        var state = load(hostID: hostID)
        state.setCurrentProviderID(providerID, for: agent)
        try save(hostID: hostID, state: state)
        return state
    }

    static func updateCodexHistorySettings(
        hostID: String,
        unify: Bool,
        migrate: Bool
    ) throws -> State {
        var state = load(hostID: hostID)
        state.unifyCodexSessionHistory = unify
        state.migrateCodexSessionsOnUnify = migrate
        try save(hostID: hostID, state: state)
        return state
    }

    /// Register 「默认」profile after first remote capture (idempotent).
    @discardableResult
    static func ensureDefaultProfile(hostID: String, agent: AgentKind) throws -> State {
        let id = defaultID(hostID: hostID, agent: agent)
        var state = load(hostID: hostID)
        if state.profiles.contains(where: { $0.id == id || ($0.agent == agent && $0.isDefault) }) {
            return state
        }
        var profile = AgentProviderProfile.makeDefault(agent: agent)
        profile.id = id
        profile.name = "默认"
        profile.notes = "启用前的远程配置快照，可随时切回"
        state.profiles.insert(profile, at: 0)
        try save(hostID: hostID, state: state)
        return state
    }

    static func deleteHostData(hostID: String) {
        try? FileManager.default.removeItem(at: AppPaths.remoteSSHProvidersURL(hostID: hostID))
        for agent in AgentKind.allCases {
            RemoteAgentDefaultSnapshot.remove(hostID: hostID, agent: agent)
        }
    }
}
