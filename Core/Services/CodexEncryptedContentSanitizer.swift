import Foundation

/// Strip account-bound encrypted reasoning from Codex session JSONL so history can
/// continue against CPA after unify (`thinking_signature_invalid` fix).
enum CodexEncryptedContentSanitizer {
    struct Result: Equatable, Sendable {
        var filesTouched: Int
        var linesRemoved: Int
        var backupDirectory: String?
    }

    /// Local `~/.codex/sessions` (+ archived). Refuses while `codex` is running.
    static func sanitizeLocalSessions() throws -> Result {
        if CodexSessionUnifier.isCodexProcessRunning() {
            throw AppError("检测到 Codex 正在运行。请先退出 Codex / Codex Desktop，再清理加密思考。")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        try AppPaths.ensureBaseDirectories()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupRoot = AppPaths.agentBackupsDirectory
            .appendingPathComponent("codex-strip-encrypted-\(formatter.string(from: Date()))", isDirectory: true)
        return try sanitizeSessionTrees(
            sessionsRoot: home.appendingPathComponent(".codex/sessions", isDirectory: true),
            archivedRoot: home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
            backupRoot: backupRoot
        )
    }

    static func sanitizeSessionTrees(
        sessionsRoot: URL,
        archivedRoot: URL,
        backupRoot: URL
    ) throws -> Result {
        var files = 0
        var lines = 0
        files += try sanitizeTree(at: sessionsRoot, backupRoot: backupRoot, linesRemoved: &lines)
        files += try sanitizeTree(at: archivedRoot, backupRoot: backupRoot, linesRemoved: &lines)
        if files == 0 {
            try? FileManager.default.removeItem(at: backupRoot)
            return Result(filesTouched: 0, linesRemoved: 0, backupDirectory: nil)
        }
        return Result(filesTouched: files, linesRemoved: lines, backupDirectory: backupRoot.path)
    }

    /// Returns rewritten text + removed line count. `nil` when unchanged.
    static func rewriteJSONLText(_ raw: String) -> (text: String, removed: Int)? {
        guard !raw.isEmpty else { return nil }
        var out = String()
        out.reserveCapacity(raw.count)
        var removed = 0
        var start = raw.startIndex
        while start < raw.endIndex {
            let end = raw[start...].firstIndex(of: "\n").map { raw.index(after: $0) } ?? raw.endIndex
            let line = String(raw[start..<end])
            let core = line.trimmingCharacters(in: CharacterSet.newlines)
            if shouldDropLine(core) {
                removed += 1
            } else {
                out.append(line)
            }
            start = end
        }
        guard removed > 0 else { return nil }
        return (out, removed)
    }

    // MARK: - Private

    private static func sanitizeTree(at root: URL, backupRoot: URL, linesRemoved: inout Int) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return 0 }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var files = 0
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            if try sanitizeFile(fileURL, backupRoot: backupRoot, linesRemoved: &linesRemoved) {
                files += 1
            }
        }
        return files
    }

    private static func sanitizeFile(_ url: URL, backupRoot: URL, linesRemoved: inout Int) throws -> Bool {
        let fm = FileManager.default
        let attrsBefore = try fm.attributesOfItem(atPath: url.path)
        let mtimeBefore = attrsBefore[.modificationDate] as? Date
        let sizeBefore = attrsBefore[.size] as? NSNumber

        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let rewritten = rewriteJSONLText(raw)
        else { return false }

        try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        // Preserve relative path under sessions/archived for restore.
        let homeCodex = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let relative: String
        if url.path.hasPrefix(homeCodex.path + "/") {
            relative = String(url.path.dropFirst(homeCodex.path.count + 1))
        } else {
            relative = url.lastPathComponent
        }
        let backupURL = backupRoot.appendingPathComponent(relative)
        try fm.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: url, to: backupURL)

        try rewritten.text.write(to: url, atomically: true, encoding: .utf8)

        let attrsAfter = try fm.attributesOfItem(atPath: url.path)
        let mtimeAfter = attrsAfter[.modificationDate] as? Date
        // If someone else wrote during our window, surface it (best-effort).
        if let mtimeBefore, let mtimeAfter, mtimeAfter < mtimeBefore {
            throw AppError("会话文件在清理过程中被外部修改：\(url.lastPathComponent)")
        }
        _ = sizeBefore
        linesRemoved += rewritten.removed
        return true
    }

    private static func shouldDropLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return false }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        // Common Codex shapes:
        // 1) {"type":"response_item","payload":{"type":"reasoning","encrypted_content":"..."}}
        // 2) payload directly as event with encrypted_content
        if let payload = obj["payload"] as? [String: Any] {
            return payloadHasEncryptedReasoning(payload)
        }
        return payloadHasEncryptedReasoning(obj)
    }

    private static func payloadHasEncryptedReasoning(_ payload: [String: Any]) -> Bool {
        let type = ((payload["type"] as? String) ?? "").lowercased()
        guard type == "reasoning" || type == "compaction" else { return false }
        if let encrypted = payload["encrypted_content"] as? String,
           !encrypted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return true
        }
        return false
    }
}
