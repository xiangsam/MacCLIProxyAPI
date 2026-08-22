import Foundation

enum AppPaths {
    static let bundleIdentifier = "com.maccliproxyapi"
    static let coreDirName = "cpa-core"
    static let coreBinaryName = "cli-proxy-api"
    static let coreConfigFile = "config.yaml"
    static let coreExampleConfigFile = "config.example.yaml"
    static let coreMetadataFile = "cpa-mac-meta.json"
    static let legacyCoreMetadataFile = "cpa-gui-meta.json"
    static let coreProcessFile = "cpa-mac-process.json"
    static let guiConfigFile = "config.toml"
    /// Durable API key store (JSON). Survives TOML/YAML merge glitches.
    static let apiKeysFile = "api-keys.json"
    static let oauthDirName = "oauth"
    static let defaultAuthDir = "../oauth"
    static let defaultPort: UInt16 = 8317
    static let defaultAPIKey = "123456"
    static let defaultAPIKeyRemark = "默认密钥"
    static let defaultManagementSecret = "123456"
    static let coreVersionFile = "core-version.txt"
    static let usageDirName = "usage-records"
    static let usageDBFile = "usage.db"
    static let agentsDirName = "agents"
    static let agentProvidersFile = "providers.json"
    static let agentSettingsFile = "settings.json"
    static let agentBackupsDirName = "backups"

    static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static var baseDirectory: URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    static var installDirectory: URL {
        baseDirectory.appendingPathComponent(coreDirName, isDirectory: true)
    }

    static var stagingDirectory: URL {
        baseDirectory.appendingPathComponent("cpa-core.staging", isDirectory: true)
    }

    static var backupDirectory: URL {
        baseDirectory.appendingPathComponent("cpa-core.backup", isDirectory: true)
    }

    static var downloadDirectory: URL {
        baseDirectory.appendingPathComponent("cpa-core.download", isDirectory: true)
    }

    static var guiConfigURL: URL {
        baseDirectory.appendingPathComponent(guiConfigFile)
    }

    static var apiKeysURL: URL {
        baseDirectory.appendingPathComponent(apiKeysFile)
    }

    static var oauthDirectory: URL {
        baseDirectory.appendingPathComponent(oauthDirName, isDirectory: true)
    }

    static var usageDatabaseURL: URL {
        baseDirectory
            .appendingPathComponent(usageDirName, isDirectory: true)
            .appendingPathComponent(usageDBFile)
    }

    static let remoteSSHDirName = "remote-ssh"
    static let remoteSSHHostsFile = "hosts.json"

    static var agentsDirectory: URL {
        baseDirectory.appendingPathComponent(agentsDirName, isDirectory: true)
    }

    static var agentProvidersURL: URL {
        agentsDirectory.appendingPathComponent(agentProvidersFile)
    }

    static var agentSettingsURL: URL {
        agentsDirectory.appendingPathComponent(agentSettingsFile)
    }

    static var agentBackupsDirectory: URL {
        agentsDirectory.appendingPathComponent(agentBackupsDirName, isDirectory: true)
    }

    static var remoteSSHDirectory: URL {
        baseDirectory.appendingPathComponent(remoteSSHDirName, isDirectory: true)
    }

    static var remoteSSHHostsURL: URL {
        remoteSSHDirectory.appendingPathComponent(remoteSSHHostsFile)
    }

    /// Per-host 「默认」snapshots pulled from remote before first takeover.
    static var remoteSSHDefaultsDirectory: URL {
        remoteSSHDirectory.appendingPathComponent("defaults", isDirectory: true)
    }

    /// Per-host remote agent providers + current selection.
    static var remoteSSHProvidersDirectory: URL {
        remoteSSHDirectory.appendingPathComponent("providers", isDirectory: true)
    }

    static func remoteSSHDefaultDirectory(hostID: String, agent: AgentKind) -> URL {
        remoteSSHDefaultsDirectory
            .appendingPathComponent(hostID, isDirectory: true)
            .appendingPathComponent(agent.rawValue, isDirectory: true)
    }

    static func remoteSSHProvidersURL(hostID: String) -> URL {
        remoteSSHProvidersDirectory.appendingPathComponent("\(hostID).json")
    }

    static var coreConfigURL: URL {
        installDirectory.appendingPathComponent(coreConfigFile)
    }

    static var coreExampleConfigURL: URL {
        installDirectory.appendingPathComponent(coreExampleConfigFile)
    }

    static var coreMetadataURL: URL {
        installDirectory.appendingPathComponent(coreMetadataFile)
    }

    static var legacyCoreMetadataURL: URL {
        installDirectory.appendingPathComponent(legacyCoreMetadataFile)
    }

    static var coreProcessURL: URL {
        baseDirectory.appendingPathComponent(coreProcessFile)
    }

    @discardableResult
    static func ensureBaseDirectories() throws -> URL {
        let fm = FileManager.default
        try ensurePrivateDirectory(baseDirectory, fileManager: fm)
        try ensurePrivateDirectory(oauthDirectory, fileManager: fm)
        try ensurePrivateDirectory(
            baseDirectory.appendingPathComponent(usageDirName, isDirectory: true),
            fileManager: fm
        )
        try ensurePrivateDirectory(agentsDirectory, fileManager: fm)
        try ensurePrivateDirectory(agentBackupsDirectory, fileManager: fm)
        try ensurePrivateDirectory(remoteSSHDirectory, fileManager: fm)
        try ensurePrivateDirectory(remoteSSHDefaultsDirectory, fileManager: fm)
        try ensurePrivateDirectory(remoteSSHProvidersDirectory, fileManager: fm)
        return baseDirectory
    }

    static func ensurePrivateDirectory(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func secureSensitiveFile(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func resolveAuthDirectory(authDir: String, installDir: URL = installDirectory) -> URL {
        let trimmed = authDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == defaultAuthDir {
            return oauthDirectory
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed, isDirectory: true)
        }
        return installDir.appendingPathComponent(trimmed).standardizedFileURL
    }

    static func findCoreBinary(in directory: URL = installDirectory) -> URL? {
        let fm = FileManager.default
        let direct = directory.appendingPathComponent(coreBinaryName)
        if fm.isExecutableFile(atPath: direct.path) {
            return direct
        }

        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == coreBinaryName {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue {
                    return fileURL
                }
            }
        }
        return nil
    }

    static func bundledCoreVersionURL() -> URL? {
        Bundle.main.url(forResource: "core-version", withExtension: "txt")
    }

    static func readBundledCoreVersion() -> String? {
        guard let url = bundledCoreVersionURL(),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : normalizeVersion(version)
    }

    /// Version recorded by the installer for the core currently on disk.
    static func readInstalledCoreVersion() -> String? {
        for url in [coreMetadataURL, legacyCoreMetadataURL] {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? String,
                  !version.isEmpty
            else { continue }
            return normalizeVersion(version)
        }
        return nil
    }

    static func normalizeVersion(_ version: String) -> String {
        var value = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") {
            value = String(value.dropFirst())
        }
        return value
    }
}
