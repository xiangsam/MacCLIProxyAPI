import Foundation

/// Captures remote agent live files as a per-host 「默认」 snapshot before first takeover
/// (mirrors local `AgentDefaultSnapshot`, but files live under App Support and are pulled/pushed via SSH).
enum RemoteAgentDefaultSnapshot {
    struct CaptureResult: Equatable, Sendable {
        var captured: Bool
        var files: [String]
    }

    static func hasSnapshot(hostID: String, agent: AgentKind) -> Bool {
        let dir = AppPaths.remoteSSHDefaultDirectory(hostID: hostID, agent: agent)
        let manifest = dir.appendingPathComponent("manifest.json")
        return FileManager.default.fileExists(atPath: manifest.path)
    }

    /// Pull remote live files once. Skips if a snapshot already exists for this host+agent.
    @discardableResult
    static func captureIfNeeded(sshHost: RemoteSSHHost, agent: AgentKind) throws -> CaptureResult {
        if hasSnapshot(hostID: sshHost.id, agent: agent) {
            return CaptureResult(captured: false, files: [])
        }

        try AppPaths.ensureBaseDirectories()
        let dir = AppPaths.remoteSSHDefaultDirectory(hostID: sshHost.id, agent: agent)
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var copied: [String] = []
        for file in liveFiles(for: agent) {
            guard let contents = try RemoteSSHClient.readRemoteFile(sshHost, path: file.remotePath) else {
                continue
            }
            let dest = dir.appendingPathComponent(file.name)
            try contents.write(to: dest, atomically: true, encoding: .utf8)
            copied.append(file.name)
        }

        let manifest = Manifest(files: copied, capturedAt: Date(), remoteTarget: sshHost.displayTarget)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)

        // Even if remote had no files yet, keep an empty snapshot so we don't re-capture after we write.
        _ = try? RemoteAgentProviderStore.ensureDefaultProfile(hostID: sshHost.id, agent: agent)
        return CaptureResult(captured: true, files: copied)
    }

    /// Push the 「默认」 snapshot back onto the remote host.
    static func restore(sshHost: RemoteSSHHost, agent: AgentKind) throws {
        let dir = AppPaths.remoteSSHDefaultDirectory(hostID: sshHost.id, agent: agent)
        let fm = FileManager.default
        guard hasSnapshot(hostID: sshHost.id, agent: agent) else {
            throw AppError("未找到远程「默认」配置快照，无法恢复启用前状态")
        }

        let names = loadCopiedNames(dir: dir, fm: fm)
        for file in liveFiles(for: agent) {
            let snap = dir.appendingPathComponent(file.name)
            if names.contains(file.name), let text = try? String(contentsOf: snap, encoding: .utf8) {
                try RemoteSSHClient.writeRemoteFile(sshHost, path: file.remotePath, contents: text, mode: "600")
            } else if file.removableIfAbsentFromSnapshot {
                let quoted = shellQuoteHomePath(file.remotePath)
                _ = try? RemoteSSHClient.runRemote(sshHost, command: "rm -f \(quoted)")
            }
        }
    }

    static func remove(hostID: String, agent: AgentKind) {
        let dir = AppPaths.remoteSSHDefaultDirectory(hostID: hostID, agent: agent)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Internals

    private struct Manifest: Codable {
        var files: [String]
        var capturedAt: Date?
        var remoteTarget: String?
    }

    private struct LiveFile {
        var name: String
        var remotePath: String
        var removableIfAbsentFromSnapshot: Bool
    }

    private static func liveFiles(for agent: AgentKind) -> [LiveFile] {
        switch agent {
        case .claude:
            return [
                LiveFile(name: "settings.json", remotePath: "$HOME/.claude/settings.json", removableIfAbsentFromSnapshot: false)
            ]
        case .codex:
            return [
                LiveFile(name: "config.toml", remotePath: "$HOME/.codex/config.toml", removableIfAbsentFromSnapshot: false),
                LiveFile(name: "auth.json", remotePath: "$HOME/.codex/auth.json", removableIfAbsentFromSnapshot: false),
                LiveFile(
                    name: CodexModelCatalogWriter.filename,
                    remotePath: "$HOME/.codex/\(CodexModelCatalogWriter.filename)",
                    removableIfAbsentFromSnapshot: true
                ),
            ]
        }
    }

    private static func loadCopiedNames(dir: URL, fm: FileManager) -> Set<String> {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? decoder.decode(Manifest.self, from: data)
        {
            return Set(manifest.files)
        }
        let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(contents.filter { $0 != "manifest.json" })
    }

    private static func shellQuoteHomePath(_ value: String) -> String {
        if value.hasPrefix("$HOME/") {
            let rest = String(value.dropFirst("$HOME/".count))
            return "\"$HOME/\(rest.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
