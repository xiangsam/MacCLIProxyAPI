import Foundation

/// Captures live agent config files as a cc-switch-style "默认" provider before first takeover.
enum AgentDefaultSnapshot {
    static func directory(for agent: AgentKind) -> URL {
        AppPaths.agentBackupsDirectory
            .appendingPathComponent("default-\(agent.rawValue)", isDirectory: true)
    }

    /// Capture current live files once (skip if default already exists, or live is already our managed write).
    @discardableResult
    static func captureIfNeeded(agent: AgentKind) throws -> AgentProviderProfile? {
        let id = AgentProviderProfile.defaultID(for: agent)
        if AgentProviderStore.loadProfiles().contains(where: { $0.id == id || ($0.agent == agent && $0.isDefault) }) {
            return nil
        }
        if isAlreadyManaged(agent: agent) {
            return nil
        }

        try AppPaths.ensureBaseDirectories()
        let dir = directory(for: agent)
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var copied: [String] = []
        for file in liveFiles(for: agent) {
            guard fm.fileExists(atPath: file.url.path) else { continue }
            let dest = dir.appendingPathComponent(file.name)
            try fm.copyItem(at: file.url, to: dest)
            copied.append(file.name)
        }

        let manifest = Manifest(files: copied)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)

        let live = AgentLiveConfigReader.read(agent: agent)
        let profile = AgentProviderProfile.makeDefault(
            agent: agent,
            endpoint: live.endpoint ?? "",
            apiKey: live.apiKey ?? "",
            model: live.model ?? "",
            fastModel: live.fastModel ?? "",
            webSearchModel: live.webSearchModel ?? "",
            modelMappings: live.modelMappings,
            reasoningEffort: live.reasoningEffort ?? ""
        )
        _ = try AgentProviderStore.upsert(profile)
        return profile
    }

    static func restore(agent: AgentKind) throws {
        let dir = directory(for: agent)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else {
            throw AppError("未找到「默认」配置快照，无法恢复启用前状态")
        }

        let manifestURL = dir.appendingPathComponent("manifest.json")
        let copiedNames: Set<String>
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        {
            copiedNames = Set(manifest.files)
        } else {
            // Legacy/partial: treat every file present in the snapshot dir (except manifest) as captured.
            let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            copiedNames = Set(contents.filter { $0 != "manifest.json" })
        }

        for file in liveFiles(for: agent) {
            let snap = dir.appendingPathComponent(file.name)
            if copiedNames.contains(file.name), fm.fileExists(atPath: snap.path) {
                try fm.createDirectory(
                    at: file.url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fm.fileExists(atPath: file.url.path) {
                    try fm.removeItem(at: file.url)
                }
                try fm.copyItem(at: snap, to: file.url)
                if file.name == "auth.json" || file.name.hasSuffix(".env") {
                    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
                }
            } else if file.removableIfAbsentFromSnapshot, fm.fileExists(atPath: file.url.path) {
                try fm.removeItem(at: file.url)
            }
        }
    }

    static func remove(agent: AgentKind) {
        let dir = directory(for: agent)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Internals

    private struct Manifest: Codable {
        var files: [String]
    }

    private struct LiveFile {
        var name: String
        var url: URL
        /// Side-effect files we created; delete on restore if not in snapshot.
        var removableIfAbsentFromSnapshot: Bool
    }

    private static func liveFiles(for agent: AgentKind) -> [LiveFile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch agent {
        case .claude:
            return [
                LiveFile(
                    name: "settings.json",
                    url: home.appendingPathComponent(".claude/settings.json"),
                    removableIfAbsentFromSnapshot: false
                )
            ]
        case .codex:
            let root = home.appendingPathComponent(".codex")
            return [
                LiveFile(name: "config.toml", url: root.appendingPathComponent("config.toml"), removableIfAbsentFromSnapshot: false),
                LiveFile(name: "auth.json", url: root.appendingPathComponent("auth.json"), removableIfAbsentFromSnapshot: false),
                LiveFile(
                    name: CodexModelCatalogWriter.filename,
                    url: root.appendingPathComponent(CodexModelCatalogWriter.filename),
                    removableIfAbsentFromSnapshot: true
                ),
            ]
        }
    }

    private static func isAlreadyManaged(agent: AgentKind) -> Bool {
        switch agent {
        case .claude:
            let live = AgentLiveConfigReader.read(agent: .claude)
            guard let endpoint = live.endpoint, !endpoint.isEmpty else { return false }
            let normalized = AgentLiveConfigReader.normalizeComparableEndpoint(endpoint, agent: .claude)
            return AgentProviderStore.loadProfiles().contains {
                $0.agent == .claude
                    && $0.isLocalCPA
                    && AgentLiveConfigReader.normalizeComparableEndpoint($0.endpoint, agent: .claude) == normalized
            }
        case .codex:
            let live = AgentLiveConfigReader.read(agent: agent)
            guard let endpoint = live.endpoint, !endpoint.isEmpty else { return false }
            let normalized = AgentLiveConfigReader.normalizeComparableEndpoint(endpoint, agent: agent)
            return AgentProviderStore.loadProfiles().contains {
                $0.agent == agent
                    && $0.isLocalCPA
                    && AgentLiveConfigReader.normalizeComparableEndpoint($0.endpoint, agent: agent) == normalized
            }
        }
    }
}
