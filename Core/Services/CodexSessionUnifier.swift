import Foundation
import SQLite3

/// Unifies Codex session history into the stable `custom` model_provider bucket.
///
/// Safety goals (aligned with cc-switch `codex_history_migration.rs`):
/// - Only rewrite `session_meta.payload.model_provider` when it is exactly `"openai"`.
/// - Prefer a surgical string replace so the rest of the JSONL line bytes stay intact.
/// - Refuse to migrate while `codex` is running (live writers).
/// - Snapshot JSONL mtime/size around backup+write; abort that file on concurrent change.
/// - Backup SQLite via the online backup API (WAL-safe), not a raw file copy.
enum CodexSessionUnifier {
    private static let sourceProvider = "openai"
    private static let targetProvider = CodexStableProvider.id
    /// `SQLITE_TRANSIENT` — SQLite makes its own copy of bound text.
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func migrateOfficialSessionsToCustom() throws -> CodexUnifyResult {
        if isCodexProcessRunning() {
            throw AppError("检测到 Codex 正在运行。请先退出 Codex / Codex Desktop，再迁移会话，以免并发写坏历史。")
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        try AppPaths.ensureBaseDirectories()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupRoot = AppPaths.agentBackupsDirectory
            .appendingPathComponent("codex-unify-\(formatter.string(from: Date()))", isDirectory: true)

        return try migrateOfficialSessionsToCustom(
            sessionsRoot: home.appendingPathComponent(".codex/sessions", isDirectory: true),
            archivedRoot: home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
            stateDB: home.appendingPathComponent(".codex/state_5.sqlite"),
            backupRoot: backupRoot
        )
    }

    /// Whether any `codex-unify-*` migration backup exists (enables the restore checkbox).
    static func hasOfficialUnifyBackup() -> Bool {
        !unifyBackupGenerations().isEmpty
    }

    /// Restore sessions that a previous migrate moved openai→custom, using backup ledgers.
    /// Only touches ids that appear in backups as openai; sessions created while unify was
    /// on stay in `custom` (same product rule as cc-switch).
    static func restoreOfficialSessionsFromBackups() throws -> CodexRestoreResult {
        if isCodexProcessRunning() {
            throw AppError("检测到 Codex 正在运行。请先退出 Codex，再还原会话。")
        }
        let generations = unifyBackupGenerations()
        guard !generations.isEmpty else {
            return CodexRestoreResult(
                jsonlRestored: 0,
                sqliteRestored: 0,
                backupDirectory: nil,
                skippedReason: "no_backup_ledger"
            )
        }

        let ledger = try collectOfficialLedger(from: generations)
        if ledger.sessionIDs.isEmpty, ledger.threadIDs.isEmpty {
            return CodexRestoreResult(
                jsonlRestored: 0,
                sqliteRestored: 0,
                backupDirectory: nil,
                skippedReason: "no_backup_ledger"
            )
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        try AppPaths.ensureBaseDirectories()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let restoreBackupRoot = AppPaths.agentBackupsDirectory
            .appendingPathComponent("codex-unify-restore-\(formatter.string(from: Date()))", isDirectory: true)

        return try restoreOfficialSessionsFromBackups(
            sessionsRoot: home.appendingPathComponent(".codex/sessions", isDirectory: true),
            archivedRoot: home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
            stateDB: home.appendingPathComponent(".codex/state_5.sqlite"),
            restoreBackupRoot: restoreBackupRoot,
            sessionIDs: ledger.sessionIDs,
            threadIDs: ledger.threadIDs
        )
    }

    static func restoreOfficialSessionsFromBackups(
        sessionsRoot: URL,
        archivedRoot: URL,
        stateDB: URL,
        restoreBackupRoot: URL,
        sessionIDs: Set<String>,
        threadIDs: Set<String>
    ) throws -> CodexRestoreResult {
        var restoredFiles = 0
        restoredFiles += try rewriteJSONLTree(
            at: sessionsRoot,
            backupRoot: restoreBackupRoot,
            from: targetProvider,
            to: sourceProvider,
            allowedSessionIDs: sessionIDs
        )
        restoredFiles += try rewriteJSONLTree(
            at: archivedRoot,
            backupRoot: restoreBackupRoot,
            from: targetProvider,
            to: sourceProvider,
            allowedSessionIDs: sessionIDs
        )
        let restoredRows = try restoreStateDatabase(
            at: stateDB,
            backupRoot: restoreBackupRoot,
            threadIDs: threadIDs
        )

        if restoredFiles == 0, restoredRows == 0 {
            try? FileManager.default.removeItem(at: restoreBackupRoot)
            return CodexRestoreResult(
                jsonlRestored: 0,
                sqliteRestored: 0,
                backupDirectory: nil,
                skippedReason: "nothing_to_restore"
            )
        }
        return CodexRestoreResult(
            jsonlRestored: restoredFiles,
            sqliteRestored: restoredRows,
            backupDirectory: restoreBackupRoot.path,
            skippedReason: nil
        )
    }

    /// Testable entry point — operates only on the given roots (never invents `~/.codex`).
    static func migrateOfficialSessionsToCustom(
        sessionsRoot: URL,
        archivedRoot: URL,
        stateDB: URL,
        backupRoot: URL
    ) throws -> CodexUnifyResult {
        var rewritten = 0
        rewritten += try rewriteJSONLTree(
            at: sessionsRoot,
            backupRoot: backupRoot,
            from: sourceProvider,
            to: targetProvider,
            allowedSessionIDs: nil
        )
        rewritten += try rewriteJSONLTree(
            at: archivedRoot,
            backupRoot: backupRoot,
            from: sourceProvider,
            to: targetProvider,
            allowedSessionIDs: nil
        )

        let sqliteUpdated = try updateStateDatabase(at: stateDB, backupRoot: backupRoot)

        if rewritten == 0, sqliteUpdated == 0 {
            try? FileManager.default.removeItem(at: backupRoot)
            return CodexUnifyResult(jsonlRewritten: 0, sqliteUpdated: 0, backupDirectory: nil)
        }

        return CodexUnifyResult(
            jsonlRewritten: rewritten,
            sqliteUpdated: sqliteUpdated,
            backupDirectory: backupRoot.path
        )
    }

    // MARK: - Process guard

    /// Best-effort: refuse migration while the Codex CLI binary is running.
    /// Desktop/app detection is intentionally narrow — concurrent file mtime checks
    /// remain the main guard against writers we cannot name reliably.
    static func isCodexProcessRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "codex"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        guard process.terminationStatus == 0 else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !text.isEmpty
    }

    // MARK: - JSONL

    private static func rewriteJSONLTree(
        at root: URL,
        backupRoot: URL,
        from: String,
        to: String,
        allowedSessionIDs: Set<String>?
    ) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return 0 }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            if try rewriteJSONLFile(
                fileURL,
                backupRoot: backupRoot,
                from: from,
                to: to,
                allowedSessionIDs: allowedSessionIDs
            ) {
                count += 1
            }
        }
        return count
    }

    private static func rewriteJSONLFile(
        _ url: URL,
        backupRoot: URL,
        from: String,
        to: String,
        allowedSessionIDs: Set<String>?
    ) throws -> Bool {
        let fm = FileManager.default
        let attrsBefore = try fm.attributesOfItem(atPath: url.path)
        let mtimeBefore = attrsBefore[.modificationDate] as? Date
        let sizeBefore = attrsBefore[.size] as? NSNumber

        guard let raw = try? String(contentsOf: url, encoding: .utf8), !raw.isEmpty else { return false }

        var changed = false
        var out = String()
        out.reserveCapacity(raw.count)

        // Preserve exact newline layout (including a final newline) via split_inclusive.
        var start = raw.startIndex
        while start < raw.endIndex {
            let nextNewline = raw[start...].firstIndex(of: "\n")
            let lineEnd = nextNewline ?? raw.endIndex
            let line = String(raw[start..<lineEnd])
            let newline = nextNewline.map { _ in "\n" } ?? ""

            if let rewritten = rewriteSessionMetaProvider(
                line,
                from: from,
                to: to,
                allowedSessionIDs: allowedSessionIDs
            ) {
                out.append(rewritten)
                changed = true
            } else {
                out.append(line)
            }
            out.append(newline)

            if let nextNewline {
                start = raw.index(after: nextNewline)
            } else {
                break
            }
        }

        guard changed else { return false }

        try ensureUnchanged(url, mtime: mtimeBefore, size: sizeBefore)

        let relative = relativePath(for: url)
        let backupURL = backupRoot.appendingPathComponent(relative)
        try fm.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: backupURL.path) {
            try fm.removeItem(at: backupURL)
        }
        try fm.copyItem(at: url, to: backupURL)

        try ensureUnchanged(url, mtime: mtimeBefore, size: sizeBefore)
        try out.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// Returns a rewritten line only when this is a `session_meta` whose
    /// `payload.model_provider` matches `from`. Uses a surgical replace so
    /// unrelated JSON bytes (instructions, tools, key order) are preserved.
    /// When `allowedSessionIDs` is non-nil, also requires `payload.id` ∈ set.
    static func rewriteSessionMetaProvider(
        _ line: String,
        from: String = sourceProvider,
        to: String = targetProvider,
        allowedSessionIDs: Set<String>? = nil
    ) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.contains("\"session_meta\""),
              trimmed.contains("\"model_provider\""),
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              (payload["model_provider"] as? String) == from
        else { return nil }

        if let allowedSessionIDs {
            guard let id = payload["id"] as? String, allowedSessionIDs.contains(id) else { return nil }
        }

        let pattern = #""model_provider"\s*:\s*""# + NSRegularExpression.escapedPattern(for: from) + #"""#
        guard let range = line.range(of: pattern, options: .regularExpression) else { return nil }
        let replaced = line[range].replacingOccurrences(of: "\"\(from)\"", with: "\"\(to)\"")
        return line.replacingCharacters(in: range, with: replaced)
    }

    private static func ensureUnchanged(_ url: URL, mtime: Date?, size: NSNumber?) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtimeNow = attrs[.modificationDate] as? Date
        let sizeNow = attrs[.size] as? NSNumber
        if mtimeNow != mtime || sizeNow != size {
            throw AppError("Codex 会话文件在迁移过程中被改动，已中止：\(url.lastPathComponent)")
        }
    }

    private static func relativePath(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path.hasPrefix(home) {
            return String(path.dropFirst(home.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return url.lastPathComponent
    }

    // MARK: - SQLite

    private static func updateStateDatabase(at url: URL, backupRoot: URL) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            throw AppError("无法打开 Codex state_5.sqlite")
        }
        defer { sqlite3_close(db) }

        sqlite3_busy_timeout(db, 5_000)

        guard tableExists(db, "threads"), columnExists(db, table: "threads", column: "model_provider") else {
            return 0
        }

        let pending = scalarInt(db, sql: "SELECT COUNT(*) FROM threads WHERE model_provider = 'openai';")
        guard pending > 0 else { return 0 }

        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let backupURL = backupRoot.appendingPathComponent("state_5.sqlite")
        try backupSQLiteOnline(from: db, to: backupURL)

        let sql = "UPDATE threads SET model_provider = ? WHERE model_provider = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw AppError("Codex 会话库准备更新失败：\(sqliteMessage(db))")
        }
        defer { sqlite3_finalize(stmt) }

        targetProvider.withCString { targetPtr in
            _ = sqlite3_bind_text(stmt, 1, targetPtr, -1, sqliteTransient)
        }
        sourceProvider.withCString { sourcePtr in
            _ = sqlite3_bind_text(stmt, 2, sourcePtr, -1, sqliteTransient)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw AppError("Codex 会话库更新失败：\(sqliteMessage(db))")
        }
        return Int(sqlite3_changes(db))
    }

    private static func restoreStateDatabase(
        at url: URL,
        backupRoot: URL,
        threadIDs: Set<String>
    ) throws -> Int {
        guard !threadIDs.isEmpty else { return 0 }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            throw AppError("无法打开 Codex state_5.sqlite")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)

        guard tableExists(db, "threads"), columnExists(db, table: "threads", column: "model_provider") else {
            return 0
        }

        // Only rewrite rows that are still in the shared custom bucket.
        let candidates = threadIDs.filter { id in
            scalarText(db, sql: "SELECT model_provider FROM threads WHERE id = ?;", bind: id) == targetProvider
        }
        guard !candidates.isEmpty else { return 0 }

        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let backupURL = backupRoot.appendingPathComponent("state_5.sqlite")
        try backupSQLiteOnline(from: db, to: backupURL)

        var changed = 0
        for id in candidates {
            let sql = "UPDATE threads SET model_provider = ? WHERE id = ? AND model_provider = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw AppError("Codex 会话库准备还原失败：\(sqliteMessage(db))")
            }
            defer { sqlite3_finalize(stmt) }
            sourceProvider.withCString { sqlite3_bind_text(stmt, 1, $0, -1, sqliteTransient) }
            id.withCString { sqlite3_bind_text(stmt, 2, $0, -1, sqliteTransient) }
            targetProvider.withCString { sqlite3_bind_text(stmt, 3, $0, -1, sqliteTransient) }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw AppError("Codex 会话库还原失败：\(sqliteMessage(db))")
            }
            changed += Int(sqlite3_changes(db))
        }
        return changed
    }

    // MARK: - Backup ledger

    private struct OfficialLedger {
        var sessionIDs: Set<String> = []
        var threadIDs: Set<String> = []
    }

    private static func unifyBackupGenerations() -> [URL] {
        let root = AppPaths.agentBackupsDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter {
            $0.lastPathComponent.hasPrefix("codex-unify-")
                && !$0.lastPathComponent.hasPrefix("codex-unify-restore-")
                && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func collectOfficialLedger(from generations: [URL]) throws -> OfficialLedger {
        var ledger = OfficialLedger()
        for generation in generations {
            if let enumerator = FileManager.default.enumerator(
                at: generation,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    if fileURL.pathExtension == "jsonl" {
                        ledger.sessionIDs.formUnion(openaiSessionIDs(in: fileURL))
                    } else if fileURL.lastPathComponent == "state_5.sqlite" {
                        ledger.threadIDs.formUnion(openaiThreadIDs(in: fileURL))
                    }
                }
            }
        }
        return ledger
    }

    private static func openaiSessionIDs(in url: URL) -> Set<String> {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var ids: Set<String> = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["type"] as? String) == "session_meta",
                  let payload = obj["payload"] as? [String: Any],
                  (payload["model_provider"] as? String) == sourceProvider,
                  let id = payload["id"] as? String
            else { continue }
            ids.insert(id)
        }
        return ids
    }

    private static func openaiThreadIDs(in url: URL) -> Set<String> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return []
        }
        defer { sqlite3_close(db) }
        guard tableExists(db, "threads"), columnExists(db, table: "threads", column: "model_provider") else {
            return []
        }
        var stmt: OpaquePointer?
        let sql = "SELECT id FROM threads WHERE model_provider = 'openai';"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var ids: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                ids.insert(String(cString: c))
            }
        }
        return ids
    }

    /// WAL-safe snapshot using SQLite's online backup API.
    private static func backupSQLiteOnline(from source: OpaquePointer, to destURL: URL) throws {
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        var dest: OpaquePointer?
        guard sqlite3_open(destURL.path, &dest) == SQLITE_OK, let dest else {
            throw AppError("无法创建 Codex state DB 备份文件")
        }
        defer { sqlite3_close(dest) }

        guard let backup = sqlite3_backup_init(dest, "main", source, "main") else {
            throw AppError("初始化 Codex state DB 备份失败：\(sqliteMessage(source))")
        }
        defer { sqlite3_backup_finish(backup) }

        while true {
            let rc = sqlite3_backup_step(backup, 64)
            if rc == SQLITE_DONE { break }
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
                usleep(25_000)
                continue
            }
            if rc != SQLITE_OK {
                throw AppError("写入 Codex state DB 备份失败（code \(rc)）")
            }
        }
    }

    private static func tableExists(_ db: OpaquePointer, _ name: String) -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        name.withCString { sqlite3_bind_text(stmt, 1, $0, -1, sqliteTransient) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func columnExists(_ db: OpaquePointer, table: String, column: String) -> Bool {
        // PRAGMA table_info does not accept bound parameters for the table name.
        let safeTable = table.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        guard safeTable == table else { return false }
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(\(safeTable));"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cName = sqlite3_column_text(stmt, 1), String(cString: cName) == column {
                return true
            }
        }
        return false
    }

    private static func scalarInt(_ db: OpaquePointer, sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static func scalarText(_ db: OpaquePointer, sql: String, bind: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind.withCString { sqlite3_bind_text(stmt, 1, $0, -1, sqliteTransient) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    private static func sqliteMessage(_ db: OpaquePointer) -> String {
        sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
    }
}
