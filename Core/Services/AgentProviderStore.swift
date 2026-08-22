import Foundation

/// Persists agent provider profiles and settings under Application Support.
enum AgentProviderStore {
    /// Agent kinds no longer managed; strip before decode so one stale entry cannot wipe the list.
    static let removedAgentRawValues: Set<String> = ["grok"]

    static func loadProfiles() -> [AgentProviderProfile] {
        guard let data = try? Data(contentsOf: AppPaths.agentProvidersURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let migrated = migrateRemovingObsoleteAgents(from: data, decoder: decoder) {
            if migrated.dropped {
                try? saveProfiles(migrated.profiles)
                stripObsoleteAgentKeysFromSettings()
            }
            return migrated.profiles
        }

        guard let decoded = try? decoder.decode([AgentProviderProfile].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Filter `"agent":"grok"` (and any future removed kinds) out of a raw providers JSON array.
    /// Returns nil when the payload is not a JSON array of objects.
    static func migrateRemovingObsoleteAgents(
        from data: Data,
        decoder: JSONDecoder
    ) -> (profiles: [AgentProviderProfile], dropped: Bool)? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        let kept = raw.filter { entry in
            guard let agent = entry["agent"] as? String else { return true }
            return !removedAgentRawValues.contains(agent)
        }
        let dropped = kept.count != raw.count
        guard let filteredData = try? JSONSerialization.data(withJSONObject: kept),
              let profiles = try? decoder.decode([AgentProviderProfile].self, from: filteredData)
        else {
            return nil
        }
        return (profiles, dropped)
    }

    private static func stripObsoleteAgentKeysFromSettings() {
        var settings = loadSettings()
        var changed = false
        for key in removedAgentRawValues where settings.currentProviderIDs[key] != nil {
            settings.currentProviderIDs.removeValue(forKey: key)
            changed = true
        }
        if changed {
            try? saveSettings(settings)
        }
    }

    static func saveProfiles(_ profiles: [AgentProviderProfile]) throws {
        try AppPaths.ensureBaseDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profiles)
        try data.write(to: AppPaths.agentProvidersURL, options: .atomic)
        try AppPaths.secureSensitiveFile(AppPaths.agentProvidersURL)
    }

    static func loadSettings() -> AgentSettings {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: AppPaths.agentSettingsURL),
              let decoded = try? decoder.decode(AgentSettings.self, from: data)
        else {
            return .default
        }
        return decoded
    }

    static func saveSettings(_ settings: AgentSettings) throws {
        try AppPaths.ensureBaseDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: AppPaths.agentSettingsURL, options: .atomic)
        try AppPaths.secureSensitiveFile(AppPaths.agentSettingsURL)
    }

    /// Ensure each agent has Local CPA & Official profiles; refresh endpoint/key from GUI.
    @discardableResult
    static func ensureLocalCPAProfiles(port: UInt16, apiKey: String) throws -> [AgentProviderProfile] {
        var profiles = loadProfiles()
        var changed = false
        for agent in AgentKind.allCases {
            // 1. Official Profile
            let off = AgentProviderProfile.official(agent: agent)
            if let idx = profiles.firstIndex(where: { $0.id == off.id || ($0.agent == agent && $0.isOfficial) }) {
                var existing = profiles[idx]
                if !existing.isOfficial || existing.name != off.name || existing.notes != off.notes {
                    existing.isOfficial = true
                    existing.name = off.name
                    existing.notes = off.notes
                    existing.updatedAt = Date()
                    profiles[idx] = existing
                    changed = true
                }
            } else {
                profiles.append(off)
                changed = true
            }

            // 2. Local CPA Profile
            let cpa = AgentProviderProfile.localCPA(agent: agent, port: port, apiKey: apiKey)
            if let idx = profiles.firstIndex(where: { $0.id == cpa.id || ($0.agent == agent && $0.isLocalCPA) }) {
                var existing = profiles[idx]
                if existing.endpoint != cpa.endpoint || existing.apiKey != cpa.apiKey || !existing.isLocalCPA {
                    existing.endpoint = cpa.endpoint
                    existing.apiKey = cpa.apiKey
                    existing.isLocalCPA = true
                    existing.name = cpa.name
                    existing.notes = cpa.notes
                    existing.updatedAt = Date()
                    profiles[idx] = existing
                    changed = true
                }
            } else {
                profiles.append(cpa)
                changed = true
            }
        }
        if changed {
            try saveProfiles(profiles)
        }
        return profiles
    }

    static func upsert(_ profile: AgentProviderProfile) throws -> [AgentProviderProfile] {
        var profiles = loadProfiles()
        var next = profile
        next.updatedAt = Date()
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            next.createdAt = profiles[idx].createdAt
            profiles[idx] = next
        } else {
            if next.createdAt.timeIntervalSince1970 < 1 {
                next.createdAt = Date()
            }
            profiles.append(next)
        }
        try saveProfiles(profiles)
        return profiles
    }

    static func delete(id: String) throws -> [AgentProviderProfile] {
        guard let removed = loadProfiles().first(where: { $0.id == id }) else {
            return loadProfiles()
        }
        guard !removed.isOfficial && !removed.isLocalCPA else {
            return loadProfiles()
        }
        let profiles = loadProfiles().filter { $0.id != id }
        try saveProfiles(profiles)
        var settings = loadSettings()
        for agent in AgentKind.allCases {
            if settings.currentProviderID(for: agent) == id {
                settings.setCurrentProviderID(nil, for: agent)
            }
        }
        try saveSettings(settings)
        if removed.isDefault {
            AgentDefaultSnapshot.remove(agent: removed.agent)
        }
        return profiles
    }

    static func profiles(for agent: AgentKind) -> [AgentProviderProfile] {
        loadProfiles().filter { $0.agent == agent }
            .sorted(by: Self.providerSort)
    }

    static func providerSort(_ lhs: AgentProviderProfile, _ rhs: AgentProviderProfile) -> Bool {
        if lhs.isDefault != rhs.isDefault { return lhs.isDefault && !rhs.isDefault }
        if lhs.isOfficial != rhs.isOfficial { return lhs.isOfficial && !rhs.isOfficial }
        if lhs.isLocalCPA != rhs.isLocalCPA { return lhs.isLocalCPA && !rhs.isLocalCPA }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
