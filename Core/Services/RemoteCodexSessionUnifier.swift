import Foundation

/// Pull remote Codex session trees over SSH, run local unify migrate, push back.
enum RemoteCodexSessionUnifier {
    /// Rewrite remote `openai` → `custom` session labels (jsonl + state_5.sqlite).
    /// Backups stay on this Mac under `agents/backups/codex-unify-remote-*`.
    static func migrateOfficialSessionsToCustom(sshHost: RemoteSSHHost) throws -> CodexUnifyResult {
        if try isRemoteCodexProcessRunning(sshHost) {
            throw AppError("远程检测到 Codex 正在运行。请先退出远程 Codex / Codex Desktop，再迁移会话。")
        }

        try AppPaths.ensureBaseDirectories()
        let fm = FileManager.default
        let workRoot = fm.temporaryDirectory
            .appendingPathComponent("maccliproxy-remote-codex-unify-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workRoot) }

        let remoteTar = "/tmp/maccliproxy-codex-unify-\(UUID().uuidString).tgz"
        let pack = try RemoteSSHClient.runRemote(sshHost, command: """
        set -e
        if [ ! -d "$HOME/.codex" ]; then
          echo "NO_CODEX_DIR"
          exit 0
        fi
        cd "$HOME/.codex"
        items=""
        [ -d sessions ] && items="$items sessions"
        [ -d archived_sessions ] && items="$items archived_sessions"
        [ -f state_5.sqlite ] && items="$items state_5.sqlite"
        [ -f state_5.sqlite-wal ] && items="$items state_5.sqlite-wal"
        [ -f state_5.sqlite-shm ] && items="$items state_5.sqlite-shm"
        if [ -z "$items" ]; then
          echo "EMPTY"
          exit 0
        fi
        tar czf \(shellSingleQuote(remoteTar)) $items
        echo "PACKED"
        """)
        guard pack.succeeded else {
            throw AppError("打包远程 Codex 会话失败：\(pack.combinedOutput)")
        }
        let packOut = pack.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if packOut.contains("NO_CODEX_DIR") || packOut.contains("EMPTY") {
            return CodexUnifyResult(jsonlRewritten: 0, sqliteUpdated: 0, backupDirectory: nil)
        }

        let localTar = workRoot.appendingPathComponent("remote-codex.tgz")
        try RemoteSSHClient.downloadRemoteFile(
            sshHost,
            remotePath: remoteTar,
            localPath: localTar.path
        )
        _ = try? RemoteSSHClient.runRemote(sshHost, command: "rm -f \(shellSingleQuote(remoteTar))")

        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        extract.arguments = ["-xzf", localTar.path, "-C", workRoot.path]
        try extract.run()
        extract.waitUntilExit()
        guard extract.terminationStatus == 0 else {
            throw AppError("解压远程 Codex 会话失败")
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupRoot = AppPaths.agentBackupsDirectory
            .appendingPathComponent(
                "codex-unify-remote-\(sshHost.id)-\(formatter.string(from: Date()))",
                isDirectory: true
            )

        let result = try CodexSessionUnifier.migrateOfficialSessionsToCustom(
            sessionsRoot: workRoot.appendingPathComponent("sessions", isDirectory: true),
            archivedRoot: workRoot.appendingPathComponent("archived_sessions", isDirectory: true),
            stateDB: workRoot.appendingPathComponent("state_5.sqlite"),
            backupRoot: backupRoot
        )

        if result.jsonlRewritten == 0, result.sqliteUpdated == 0 {
            return result
        }

        // Push migrated trees back.
        let pushTar = workRoot.appendingPathComponent("push-codex.tgz")
        let push = Process()
        push.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        push.currentDirectoryURL = workRoot
        var args = ["-czf", pushTar.path]
        if fm.fileExists(atPath: workRoot.appendingPathComponent("sessions").path) {
            args.append("sessions")
        }
        if fm.fileExists(atPath: workRoot.appendingPathComponent("archived_sessions").path) {
            args.append("archived_sessions")
        }
        if fm.fileExists(atPath: workRoot.appendingPathComponent("state_5.sqlite").path) {
            args.append("state_5.sqlite")
        }
        push.arguments = args
        try push.run()
        push.waitUntilExit()
        guard push.terminationStatus == 0 else {
            throw AppError("打包迁移后的会话失败")
        }

        let remotePush = "/tmp/maccliproxy-codex-unify-push-\(UUID().uuidString).tgz"
        try RemoteSSHClient.uploadLocalFile(sshHost, localPath: pushTar.path, remotePath: remotePush)
        let apply = try RemoteSSHClient.runRemote(sshHost, command: """
        set -e
        mkdir -p "$HOME/.codex"
        # Checkpoint WAL before replace when possible.
        if command -v sqlite3 >/dev/null 2>&1 && [ -f "$HOME/.codex/state_5.sqlite" ]; then
          sqlite3 "$HOME/.codex/state_5.sqlite" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
        fi
        tar xzf \(shellSingleQuote(remotePush)) -C "$HOME/.codex"
        rm -f \(shellSingleQuote(remotePush))
        """)
        guard apply.succeeded else {
            throw AppError("写回远程 Codex 会话失败：\(apply.combinedOutput)")
        }

        return result
    }

    static func isRemoteCodexProcessRunning(_ host: RemoteSSHHost) throws -> Bool {
        let result = try RemoteSSHClient.runRemote(host, command: "pgrep -x codex >/dev/null && echo YES || echo NO")
        guard result.succeeded else {
            // If pgrep missing / SSH oddity, be conservative and refuse.
            throw AppError("无法检测远程 Codex 进程：\(result.combinedOutput)")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).contains("YES")
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
