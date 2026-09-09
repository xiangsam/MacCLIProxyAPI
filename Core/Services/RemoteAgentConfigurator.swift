import Foundation

/// Apply Local-CPA-aligned agent live configs onto a remote machine over SSH.
enum RemoteAgentConfigurator {
    /// Resolve the host the remote machine should use to reach this Mac's CPA.
    static func resolveCPAReachableHost(
        sshHost: RemoteSSHHost,
        lanIPv4: String?,
        allowLan: Bool
    ) throws -> String {
        let explicit = sshHost.cpaReachableHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        guard allowLan else {
            throw AppError("请填写「远程访问 CPA 地址」，或在配置页开启局域网访问并确保本机有局域网 IP。")
        }
        guard let lan = lanIPv4?.trimmingCharacters(in: .whitespacesAndNewlines), !lan.isEmpty else {
            throw AppError("未检测到局域网 IP。请手动填写远程机器访问本机 CPA 的地址（或开启局域网访问）。")
        }
        return lan
    }

    /// Catalog endpoint on *this Mac* (for「获取模型」).
    static func localCatalogEndpoint(agent: AgentKind, cpaPort: UInt16) -> String {
        switch agent {
        case .claude:
            return "http://127.0.0.1:\(cpaPort)"
        case .codex:
            return "http://127.0.0.1:\(cpaPort)/v1"
        }
    }

    /// Build a profile shaped like Local CPA, but with endpoints reachable from the remote host.
    static func remoteLocalCPAProfile(
        agent: AgentKind,
        template: AgentProviderProfile?,
        cpaHost: String,
        cpaPort: UInt16,
        apiKey: String
    ) -> AgentProviderProfile {
        let endpoint: String
        switch agent {
        case .claude:
            endpoint = RemoteCPAEndpointBuilder.claudeBase(host: cpaHost, port: cpaPort)
        case .codex:
            endpoint = RemoteCPAEndpointBuilder.codexBase(host: cpaHost, port: cpaPort)
        }

        var profile = AgentProviderProfile.localCPA(agent: agent, port: cpaPort, apiKey: apiKey)
        profile.endpoint = endpoint
        profile.apiKey = apiKey
        profile.name = "本机 CPA（远程）"
        // Remote write must not re-resolve localhost on the Mac filesystem.
        profile.isLocalCPA = false
        if let template {
            for role in agent.modelRoles {
                let value = template.model(for: role)
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    profile.setModel(value, for: role)
                }
            }
            profile.reasoningEffort = template.reasoningEffort
            // Per-model context window and thinking levels live here. Rebuilding the profile
            // field by field silently dropped them, so the catalog we pushed always carried the
            // auto-derived context instead of what the user typed.
            profile.modelOverrides = template.modelOverrides
            if agent == .codex {
                profile.catalogModels = template.resolvedCodexCatalogModels
                // The remote agent talks to the same core over the LAN, so its provider
                // identity has to match the template's or the two disagree about compaction.
                profile.claimsOpenAIProvider = template.claimsOpenAIProvider
                profile.codexSubscriptionOnly = template.codexSubscriptionOnly
            }
        }
        return profile
    }

    static func apply(
        agent: AgentKind,
        sshHost: RemoteSSHHost,
        template: AgentProviderProfile?,
        cpaPort: UInt16,
        apiKey: String,
        lanIPv4: String?,
        allowLan: Bool,
        catalogModels: [String]? = nil
    ) throws -> RemoteAgentApplyResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AppError("请先在配置页添加 API Key") }
        let cpaHost = try resolveCPAReachableHost(sshHost: sshHost, lanIPv4: lanIPv4, allowLan: allowLan)
        let profile = remoteLocalCPAProfile(
            agent: agent,
            template: template,
            cpaHost: cpaHost,
            cpaPort: cpaPort,
            apiKey: key
        )

        let capture = try RemoteAgentDefaultSnapshot.captureIfNeeded(sshHost: sshHost, agent: agent)
        let suffix = capture.captured
            ? (capture.files.isEmpty ? "（已建立空「默认」快照）" : "（已保存启用前配置为「默认」）")
            : ""

        switch agent {
        case .claude:
            return try applyClaude(sshHost: sshHost, profile: profile, messageSuffix: suffix)
        case .codex:
            let result = try applyCodex(
                sshHost: sshHost,
                profile: profile,
                messageSuffix: suffix,
                catalogModels: catalogModels
            )
            try syncCodexCPAAuth(sshHost: sshHost, enableCPA: true)
            return result
        }
    }

    /// Restore the host's pre-app config.
    ///
    /// `unifyCodexSessionHistory` re-pins the shared bucket afterwards: a snapshot captured
    /// before we ever touched the host names no provider, so Codex would fall back to its
    /// built-in `openai` bucket and sessions started from 「默认」 would leave the unified
    /// history the user asked for.
    static func restoreDefault(
        agent: AgentKind,
        sshHost: RemoteSSHHost,
        unifyCodexSessionHistory: Bool = false
    ) throws -> RemoteAgentApplyResult {
        try RemoteAgentDefaultSnapshot.restore(sshHost: sshHost, agent: agent)
        let path: String
        switch agent {
        case .claude: path = "~/.claude/settings.json"
        case .codex: path = "~/.codex/config.toml"
        }
        var suffix = ""
        if agent == .codex, unifyCodexSessionHistory,
           try repinOfficialCodexBucket(sshHost: sshHost)
        {
            suffix = "（已重新固定 model_provider=custom）"
        }
        // Restoring swaps the catalog back too, so a running daemon is just as stale here.
        let staleDaemon = agent == .codex && codexAppServerIsRunning(sshHost: sshHost)
        let reloadHint = staleDaemon ? "；远程 Codex 服务仍在用旧的模型列表，需重启后生效" : ""
        if agent == .codex {
            try syncCodexCPAAuth(sshHost: sshHost, enableCPA: false)
        }
        return RemoteAgentApplyResult(
            agent: agent,
            remotePath: path,
            message: "已恢复远程「默认」配置\(suffix)\(reloadHint)",
            codexAppServerHoldsStaleCatalog: staleDaemon
        )
    }

    /// Enable a remote provider (list → enable), matching local Agents UX.
    /// 「默认」restores the first-capture snapshot; others write live config after capture-if-needed.
    static func enable(
        profile: AgentProviderProfile,
        sshHost: RemoteSSHHost,
        cpaPort: UInt16,
        apiKey: String,
        lanIPv4: String?,
        allowLan: Bool,
        unifyCodexSessionHistory: Bool = false
    ) throws -> RemoteAgentApplyResult {
        if profile.isDefault {
            return try restoreDefault(
                agent: profile.agent,
                sshHost: sshHost,
                unifyCodexSessionHistory: unifyCodexSessionHistory
            )
        }

        let agent = profile.agent
        let writeProfile: AgentProviderProfile
        if profile.isLocalCPA {
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw AppError("请先在配置页添加 API Key") }
            let cpaHost = try resolveCPAReachableHost(sshHost: sshHost, lanIPv4: lanIPv4, allowLan: allowLan)
            writeProfile = remoteLocalCPAProfile(
                agent: agent,
                template: profile,
                cpaHost: cpaHost,
                cpaPort: cpaPort,
                apiKey: key
            )
        } else if profile.isOfficial {
            writeProfile = profile
        } else {
            let endpoint = profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !endpoint.isEmpty else {
                throw AppError("Provider「\(profile.name)」缺少 Endpoint")
            }
            writeProfile = profile
        }

        let capture = try RemoteAgentDefaultSnapshot.captureIfNeeded(sshHost: sshHost, agent: agent)
        let suffix = capture.captured
            ? (capture.files.isEmpty ? "（已建立空「默认」快照）" : "（已保存启用前配置为「默认」）")
            : ""

        switch agent {
        case .claude:
            return try applyClaude(sshHost: sshHost, profile: writeProfile, messageSuffix: suffix)
        case .codex:
            let result = try applyCodex(
                sshHost: sshHost,
                profile: writeProfile,
                messageSuffix: suffix,
                catalogModels: writeProfile.resolvedCodexCatalogModels,
                unifyCodexSessionHistory: unifyCodexSessionHistory
            )
            try syncCodexCPAAuth(sshHost: sshHost, enableCPA: profile.isLocalCPA)
            return result
        }
    }

    static func applyAll(
        sshHost: RemoteSSHHost,
        templates: [AgentKind: AgentProviderProfile],
        cpaPort: UInt16,
        apiKey: String,
        lanIPv4: String?,
        allowLan: Bool,
        catalogModelsByAgent: [AgentKind: [String]] = [:]
    ) throws -> [RemoteAgentApplyResult] {
        try AgentKind.allCases.map { agent in
            try apply(
                agent: agent,
                sshHost: sshHost,
                template: templates[agent],
                cpaPort: cpaPort,
                apiKey: apiKey,
                lanIPv4: lanIPv4,
                allowLan: allowLan,
                catalogModels: catalogModelsByAgent[agent]
            )
        }
    }

    // MARK: - Per agent

    private static func applyClaude(
        sshHost: RemoteSSHHost,
        profile: AgentProviderProfile,
        messageSuffix: String
    ) throws -> RemoteAgentApplyResult {
        let relative = ".claude/settings.json"
        let remotePath = homePath(relative)
        let existing = try RemoteSSHClient.readRemoteFile(sshHost, path: remotePath)
        let data = try AgentLiveConfigWriter.mergeClaude(
            existingJSON: existing?.data(using: .utf8),
            profile: profile
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppError("无法编码 Claude settings.json")
        }
        try backupRemoteIfPresent(sshHost, path: remotePath, stamp: "claude")
        try RemoteSSHClient.writeRemoteFile(sshHost, path: remotePath, contents: text, mode: "600")
        return RemoteAgentApplyResult(
            agent: .claude,
            remotePath: "~/\(relative)",
            message: "已写入 Claude Code 配置\(messageSuffix)"
        )
    }

    private static func applyCodex(
        sshHost: RemoteSSHHost,
        profile: AgentProviderProfile,
        messageSuffix: String,
        catalogModels: [String]? = nil,
        unifyCodexSessionHistory: Bool = false
    ) throws -> RemoteAgentApplyResult {
        let relative = ".codex/config.toml"
        let remotePath = homePath(relative)
        let existing = try RemoteSSHClient.readRemoteFile(sshHost, path: remotePath) ?? ""
        let modelIDs = CodexModelCatalogWriter.resolveModelIDs(profile: profile, explicit: catalogModels)
        let text = AgentLiveConfigWriter.mergeCodex(
            existingText: existing,
            profile: profile,
            catalogModelIDs: modelIDs,
            catalogDirectory: try resolveRemoteHome(sshHost) + "/.codex",
            unifySessionHistory: unifyCodexSessionHistory
        )
        try backupRemoteIfPresent(sshHost, path: remotePath, stamp: "codex")
        try RemoteSSHClient.writeRemoteFile(sshHost, path: remotePath, contents: text, mode: "600")

        let catalogRemote = homePath(".codex/\(CodexModelCatalogWriter.filename)")
        if profile.isOfficial || modelIDs.isEmpty {
            let quoted = shellQuoteHomePath(catalogRemote)
            _ = try? RemoteSSHClient.runRemote(sshHost, command: "rm -f \(quoted)")
        } else {
            let data = try CodexModelCatalogWriter.buildCatalogJSON(
                modelIDs: modelIDs,
                overrides: profile.modelOverrides
            )
            guard let catalogText = String(data: data, encoding: .utf8) else {
                throw AppError("无法编码 Codex model catalog")
            }
            try backupRemoteIfPresent(sshHost, path: catalogRemote, stamp: "codex-catalog")
            try RemoteSSHClient.writeRemoteFile(sshHost, path: catalogRemote, contents: catalogText, mode: "600")
        }

        let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelPart = model.isEmpty ? "" : " · model=\(model)"
        let catalogPart = modelIDs.isEmpty ? "" : " · catalog \(modelIDs.count) models"
        // The daemon reads the catalog once at startup and survives reconnects, so a new catalog
        // means nothing to `/model` until the process itself goes away.
        let staleDaemon = !modelIDs.isEmpty && codexAppServerIsRunning(sshHost: sshHost)
        let reloadHint = staleDaemon ? "；远程 Codex 服务仍在用旧的模型列表，需重启后生效" : ""
        return RemoteAgentApplyResult(
            agent: .codex,
            remotePath: "~/\(relative)",
            message: "已写入 Codex 配置（model_provider=custom\(modelPart)\(catalogPart)）\(messageSuffix)\(reloadHint)",
            codexAppServerHoldsStaleCatalog: staleDaemon
        )
    }

    /// `model_provider` in the remote Codex config, or nil when unset.
    ///
    /// Used to verify a remote write actually landed before telling the user it did.
    static func remoteCodexProviderID(sshHost: RemoteSSHHost) throws -> String? {
        let text = try RemoteSSHClient.readRemoteFile(sshHost, path: homePath(".codex/config.toml")) ?? ""
        return TOMLEdit.value(text, table: nil, key: "model_provider")
    }

    /// Point the remote Codex config at the shared `custom` bucket.
    ///
    /// Remote counterpart of `AgentLiveConfigWriter.repinOfficialCodexBucket()`, with the same
    /// restraint: only a config on the official backend is moved, and a config naming a
    /// third-party provider is left alone. Returns true when the host's file was rewritten.
    @discardableResult
    static func repinOfficialCodexBucket(sshHost: RemoteSSHHost) throws -> Bool {
        let remotePath = homePath(".codex/config.toml")
        let existing = try RemoteSSHClient.readRemoteFile(sshHost, path: remotePath) ?? ""
        guard let repinned = AgentLiveConfigWriter.repinningOfficialCodexBucket(in: existing) else {
            return false
        }
        try backupRemoteIfPresent(sshHost, path: remotePath, stamp: "codex")
        try RemoteSSHClient.writeRemoteFile(sshHost, path: remotePath, contents: repinned, mode: "600")
        return true
    }

    /// Matches the remote `codex app-server` daemon and its launcher shell.
    ///
    /// The `[a]pp` spelling keeps the pattern from matching the very shell that carries it:
    /// the regex needs three literal characters `app`, and the command line spells them `[a]pp`.
    /// Without it `pkill -f` kills our own SSH session before it reaches the daemon.
    static let codexAppServerPattern = "codex.*[a]pp-server"

    /// Whether a `codex app-server` is holding an older copy of the host's model catalog.
    ///
    /// The daemon parses `model_catalog_json` once at startup and is detached with `nohup`, so
    /// reopening a desktop session leaves it in place and `/model` keeps listing whichever
    /// profile was active when it booted.
    static func codexAppServerIsRunning(sshHost: RemoteSSHHost) -> Bool {
        let command = "pgrep -u \"$(id -u)\" -f '\(codexAppServerPattern)' >/dev/null"
        return (try? RemoteSSHClient.runRemote(sshHost, command: command))?.succeeded == true
    }

    /// Stop the remote `codex app-server` so the next connection boots one that re-reads the catalog.
    ///
    /// Stopping is all we do: starting it is the desktop integration's job, and it does so on
    /// connect. Returns true when a daemon was actually running.
    @discardableResult
    static func stopCodexAppServer(sshHost: RemoteSSHHost) throws -> Bool {
        guard codexAppServerIsRunning(sshHost: sshHost) else { return false }
        let command = "pkill -u \"$(id -u)\" -f '\(codexAppServerPattern)'"
        _ = try RemoteSSHClient.runRemote(sshHost, command: command)
        return true
    }

    /// Mirror of local `CodexCPAAuthFile.sync`: create the dummy only when missing, delete
    /// it only when the remote file is still the CPA placeholder.
    private static func syncCodexCPAAuth(sshHost: RemoteSSHHost, enableCPA: Bool) throws {
        let remotePath = homePath(".codex/auth.json")
        if enableCPA {
            if try RemoteSSHClient.readRemoteFile(sshHost, path: remotePath) != nil { return }
            try RemoteSSHClient.writeRemoteFile(
                sshHost,
                path: remotePath,
                contents: CodexCPAAuthFile.payloadText,
                mode: "600"
            )
            return
        }
        guard let existing = try RemoteSSHClient.readRemoteFile(sshHost, path: remotePath),
              CodexCPAAuthFile.isCreatedByCPA(text: existing)
        else { return }
        let quoted = shellQuoteHomePath(remotePath)
        _ = try? RemoteSSHClient.runRemote(sshHost, command: "rm -f \(quoted)")
    }

    private static func homePath(_ relative: String) -> String {
        "$HOME/\(relative)"
    }

    /// Remote home as a literal path.
    ///
    /// Shell-expanded `$HOME` is fine for commands we run ourselves, but values written *into*
    /// a config file are read literally by the agent, so those need the resolved path.
    static func resolveRemoteHome(_ host: RemoteSSHHost) throws -> String {
        let result = try RemoteSSHClient.runRemote(host, command: "printf %s \"$HOME\"")
        let home = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, home.hasPrefix("/") else {
            throw AppError("无法解析远程主机的 HOME 目录")
        }
        return home
    }

    private static func backupRemoteIfPresent(_ host: RemoteSSHHost, path: String, stamp: String) throws {
        let stampSafe = stamp.replacingOccurrences(of: "'", with: "")
        let quoted = shellQuoteHomePath(path)
        let script = """
        if [ -f \(quoted) ]; then
          mkdir -p "$HOME/.maccliproxy-agent-backups" && \
          cp \(quoted) "$HOME/.maccliproxy-agent-backups/\(stampSafe)-$(date +%Y%m%d-%H%M%S)"
        fi
        """
        _ = try? RemoteSSHClient.runRemote(host, command: script)
    }

    private static func shellQuoteHomePath(_ value: String) -> String {
        if value.hasPrefix("$HOME/") {
            let rest = String(value.dropFirst("$HOME/".count))
            return "\"$HOME/\(rest.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
