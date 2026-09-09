import Foundation

/// Placeholder `~/.codex/auth.json` written while the Codex 本机 CPA profile is enabled.
///
/// Codex still consults `auth.json` when `requires_openai_auth` is set. A missing file
/// triggers ChatGPT login even though the live config already carries
/// `experimental_bearer_token`. The dummy key is not the GUI API key — the real key lives
/// in `config.toml`.
///
/// Created only when the file is absent. Removed only when the file still matches this
/// exact payload, so a ChatGPT OAuth `auth.json` is never deleted.
enum CodexCPAAuthFile {
    static let authMode = "apikey"
    static let apiKey = "cpa"

    /// Exact body requested for the CPA placeholder (trailing newline for a text file).
    static let payloadText = """
    {
      "auth_mode": "apikey",
      "OPENAI_API_KEY": "cpa"
    }
    """

    static let authFilename = "auth.json"
    static let globalStateFilename = ".codex-global-state.json"
    static let globalStateBackupFilename = ".codex-global-state.json.back"

    /// Files Codex Desktop caches login/model gating in. The repair action deletes each
    /// if present, then rewrites the CPA placeholder `auth.json`.
    static var desktopStateFilenames: [String] {
        [authFilename, globalStateFilename, globalStateBackupFilename]
    }

    static var liveDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static var liveURL: URL {
        liveDirectory.appendingPathComponent(authFilename)
    }

    static func payloadData() -> Data {
        Data(payloadText.utf8)
    }

    struct DesktopRepairResult: Equatable, Sendable {
        var removed: [String]
    }

    /// True only for the two-key placeholder we wrote. Extra keys (OAuth tokens, etc.) are
    /// treated as the user's own file.
    static func isCreatedByCPA(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        guard obj.count == 2 else { return false }
        guard (obj["auth_mode"] as? String) == authMode else { return false }
        guard (obj["OPENAI_API_KEY"] as? String) == apiKey else { return false }
        return true
    }

    static func isCreatedByCPA(text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return isCreatedByCPA(data)
    }

    /// Create the placeholder when enabling CPA; delete it when leaving CPA, but only if
    /// the file is still the placeholder.
    static func sync(url: URL = liveURL, enableCPA: Bool) throws {
        if enableCPA {
            try ensurePlaceholderIfMissing(at: url)
        } else {
            try removeIfCreatedByCPA(at: url)
        }
    }

    static func ensurePlaceholderIfMissing(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        try writePlaceholder(at: url)
    }

    static func writePlaceholder(at url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payloadData().write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func removeIfCreatedByCPA(at url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url), isCreatedByCPA(data) else { return }
        try fm.removeItem(at: url)
    }

    /// Force-delete Desktop cached auth/state, then write the CPA `auth.json` placeholder.
    /// Unlike profile switch, this deletes `auth.json` even when it is a ChatGPT login.
    @discardableResult
    static func repairDesktopCustomModels(codexDirectory: URL = liveDirectory) throws -> DesktopRepairResult {
        let fm = FileManager.default
        try fm.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        var removed: [String] = []
        for name in desktopStateFilenames {
            let url = codexDirectory.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            try fm.removeItem(at: url)
            removed.append(name)
        }
        try writePlaceholder(at: codexDirectory.appendingPathComponent(authFilename))
        return DesktopRepairResult(removed: removed)
    }
}
