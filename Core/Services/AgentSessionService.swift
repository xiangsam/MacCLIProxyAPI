import AppKit
import Foundation

/// Scans / resumes / deletes local coding-agent sessions.
enum AgentSessionService {
    static func listSessions(agents: [AgentKind] = AgentKind.allCases, limit: Int = 400) -> [AgentSessionRecord] {
        var records: [AgentSessionRecord] = []
        for agent in agents {
            switch agent {
            case .claude:
                records.append(contentsOf: scanClaude())
            case .codex:
                records.append(contentsOf: scanCodex())
            }
        }
        records.sort { $0.updatedAt > $1.updatedAt }
        if records.count > limit {
            return Array(records.prefix(limit))
        }
        return records
    }

    static func delete(_ session: AgentSessionRecord) throws {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: session.filePath)
        switch session.agent {
        case .claude, .codex:
            guard fm.fileExists(atPath: url.path) else {
                throw AppError("会话文件不存在")
            }
            try fm.removeItem(at: url)
        }
    }

    static func resume(_ session: AgentSessionRecord) throws {
        guard let command = session.resumeCommand, !command.isEmpty else {
            throw AppError("该会话没有可用的恢复命令")
        }
        let cwd = session.projectPath ?? FileManager.default.homeDirectoryForCurrentUser.path
        openTerminal(command: command, directory: cwd)
    }

    /// Open a fresh CLI session for the agent in Terminal.
    static func launch(_ agent: AgentKind, directory: String? = nil) throws {
        let cwd = directory ?? FileManager.default.homeDirectoryForCurrentUser.path
        let command: String
        switch agent {
        case .claude:
            guard which("claude") != nil else { throw AppError("未找到 claude 命令") }
            command = "claude"
        case .codex:
            guard which("codex") != nil else { throw AppError("未找到 codex 命令") }
            command = "codex"
        }
        openTerminal(command: command, directory: cwd)
    }

    private static func which(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    // MARK: - Claude

    private static func scanClaude() -> [AgentSessionRecord] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        var out: [AgentSessionRecord] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            let updated = values?.contentModificationDate ?? Date.distantPast
            let projectEncoded = fileURL.deletingLastPathComponent().lastPathComponent
            let projectPath = decodeClaudeProjectPath(projectEncoded)
            let sessionID = fileURL.deletingPathExtension().lastPathComponent
            let title = firstUserSnippet(in: fileURL) ?? sessionID
            out.append(
                AgentSessionRecord(
                    id: "claude:\(sessionID)",
                    agent: .claude,
                    title: title,
                    projectPath: projectPath,
                    filePath: fileURL.path,
                    updatedAt: updated,
                    modelProvider: nil,
                    resumeCommand: "claude --resume \(shellQuote(sessionID))"
                )
            )
        }
        return out
    }

    private static func decodeClaudeProjectPath(_ encoded: String) -> String? {
        // Claude encodes absolute paths as `-Users-foo-bar`
        guard encoded.hasPrefix("-") else { return nil }
        let parts = encoded.split(separator: "-").filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return "/" + parts.joined(separator: "/")
    }

    private static func firstUserSnippet(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 64 * 1024)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (obj["type"] as? String) == "user"
            else { continue }
            if let message = obj["message"] as? [String: Any] {
                if let content = message["content"] as? String {
                    return truncate(content)
                }
                if let parts = message["content"] as? [[String: Any]] {
                    for part in parts {
                        if let t = part["text"] as? String { return truncate(t) }
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Codex

    private static func scanCodex() -> [AgentSessionRecord] {
        let roots = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
        ]
        let fm = FileManager.default
        var out: [AgentSessionRecord] = []
        for root in roots {
            guard fm.fileExists(atPath: root.path),
                  let enumerator = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                  )
            else { continue }
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jsonl",
                      fileURL.lastPathComponent.hasPrefix("rollout-")
                else { continue }
                let meta = readCodexMeta(fileURL)
                let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                let updated = values?.contentModificationDate ?? Date.distantPast
                let sessionID = meta.id ?? fileURL.deletingPathExtension().lastPathComponent
                let title = meta.title?.nilIfEmpty ?? sessionID
                out.append(
                    AgentSessionRecord(
                        id: "codex:\(sessionID)",
                        agent: .codex,
                        title: title,
                        projectPath: meta.cwd,
                        filePath: fileURL.path,
                        updatedAt: updated,
                        modelProvider: meta.provider,
                        resumeCommand: "codex resume \(shellQuote(sessionID))"
                    )
                )
            }
        }
        return out
    }

    private struct CodexMeta {
        var id: String?
        var cwd: String?
        var provider: String?
        var title: String?
    }

    private static func readCodexMeta(_ url: URL) -> CodexMeta {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return CodexMeta() }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 8 * 1024)
        guard let text = String(data: data, encoding: .utf8),
              let first = text.split(separator: "\n", omittingEmptySubsequences: true).first,
              let d = first.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let payload = obj["payload"] as? [String: Any]
        else { return CodexMeta() }
        return CodexMeta(
            id: payload["id"] as? String,
            cwd: payload["cwd"] as? String,
            provider: payload["model_provider"] as? String,
            title: nil
        )
    }

    // MARK: - Terminal

    private static func openTerminal(command: String, directory: String) {
        let cd = "cd \(shellQuote(directory))"
        let full = "\(cd) && \(command)"
        let escaped = full
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
          activate
          do script "\(escaped)"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func truncate(_ text: String, limit: Int = 80) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count <= limit { return cleaned }
        return String(cleaned.prefix(limit - 1)) + "…"
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
