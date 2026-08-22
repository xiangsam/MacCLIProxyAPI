import Foundation
import Yams

enum CoreConfigStore {
    static func readSettings(gui: GuiConfigFile) throws -> CoreConfigSettings {
        let url = AppPaths.coreConfigURL
        if FileManager.default.fileExists(atPath: url.path) {
            let text = try String(contentsOf: url, encoding: .utf8)
            if let parsed = try? parseCoreSettings(from: text, fallback: gui) {
                return parsed
            }
        }
        return gui.coreConfigSettings
    }

    static func mergeForStart(gui: GuiConfigFile) throws -> URL {
        try AppPaths.ensureBaseDirectories()
        let exampleURL = AppPaths.coreExampleConfigURL
        let configURL = AppPaths.coreConfigURL

        guard FileManager.default.fileExists(atPath: exampleURL.path) else {
            // No template yet (core not fully installed). Write a minimal config.
            let minimal = minimalConfigYAML(gui: gui)
            try minimal.write(to: configURL, atomically: true, encoding: .utf8)
            try AppPaths.secureSensitiveFile(configURL)
            return configURL
        }

        let template = try String(contentsOf: exampleURL, encoding: .utf8)
        let current = FileManager.default.fileExists(atPath: configURL.path)
            ? try String(contentsOf: configURL, encoding: .utf8)
            : nil
        let merged = try mergeYAML(template: template, current: current, gui: gui)
        try merged.write(to: configURL, atomically: true, encoding: .utf8)
        try AppPaths.secureSensitiveFile(configURL)
        return configURL
    }

    static func writeAPIKeys(_ keys: [GuiApiKey], gui: GuiConfigFile) throws {
        _ = gui
        let url = AppPaths.coreConfigURL
        if !FileManager.default.fileExists(atPath: url.path) {
            // Core not installed yet — still write a minimal config so keys survive.
            try AppPaths.ensureBaseDirectories()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try minimalConfigYAML(gui: gui).write(to: url, atomically: true, encoding: .utf8)
            try AppPaths.secureSensitiveFile(url)
            return
        }
        var text = try String(contentsOf: url, encoding: .utf8)
        text = try patchAPIKeys(in: text, keys: keys.map(\.apiKey))
        try text.write(to: url, atomically: true, encoding: .utf8)
        try AppPaths.secureSensitiveFile(url)
    }

    /// Push GUI-owned settings (keys, network, routing) into core config.yaml if present.
    static func syncFromGUI(_ gui: GuiConfigFile) throws {
        let url = AppPaths.coreConfigURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let text = try String(contentsOf: url, encoding: .utf8)
        let updated = try applyGUIManagedSettings(to: text, gui: gui)
        try updated.write(to: url, atomically: true, encoding: .utf8)
        try AppPaths.secureSensitiveFile(url)
    }

    static func patchNetworkAndRouting(gui: GuiConfigFile) throws {
        let url = AppPaths.coreConfigURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let text = try String(contentsOf: url, encoding: .utf8)
        let updated = try applyGUIManagedSettings(to: text, gui: gui)
        try updated.write(to: url, atomically: true, encoding: .utf8)
        try AppPaths.secureSensitiveFile(url)
    }

    // MARK: - YAML helpers

    private static func parseCoreSettings(from text: String, fallback: GuiConfigFile) throws -> CoreConfigSettings {
        guard let root = try Yams.load(yaml: text) as? [String: Any] else {
            return fallback.coreConfigSettings
        }

        let port = (root["port"] as? Int).flatMap { UInt16(exactly: $0) } ?? fallback.port
        let host = (root["host"] as? String) ?? fallback.host
        let allowLan = host != "127.0.0.1" && host != "localhost"

        var apiKeys: [GuiApiKey] = []
        if let keys = root["api-keys"] as? [String] {
            apiKeys = keys.map { GuiApiKey(apiKey: $0, remark: "") }
        } else if let keys = root["api-keys"] as? [[String: Any]] {
            apiKeys = keys.compactMap { item in
                let key = (item["api-key"] as? String) ?? (item["key"] as? String) ?? ""
                guard !key.isEmpty else { return nil }
                let remark = (item["remark"] as? String) ?? ""
                return GuiApiKey(apiKey: key, remark: remark)
            }
        }
        if apiKeys.isEmpty {
            apiKeys = fallback.apiKeys
        } else {
            // Preserve remarks from GUI config when possible.
            let remarkMap = Dictionary(uniqueKeysWithValues: fallback.apiKeys.map { ($0.apiKey, $0.remark) })
            apiKeys = apiKeys.map { key in
                var copy = key
                if copy.remark.isEmpty {
                    copy.remark = remarkMap[copy.apiKey] ?? ""
                }
                return copy
            }
        }

        let routing = root["routing"] as? [String: Any]
        let strategy = (routing?["strategy"] as? String) ?? fallback.routingStrategy
        let sessionAffinity = (routing?["session-affinity"] as? Bool) ?? fallback.routingSessionAffinity
        let sessionTTL = (routing?["session-affinity-ttl"] as? String) ?? fallback.routingSessionAffinityTtl
        let proxy = (root["proxy-url"] as? String) ?? fallback.proxyUrl
        let remote = root["remote-management"] as? [String: Any]
        let secret = (remote?["secret-key"] as? String) ?? ""
        let excluded = root["oauth-excluded-models"] as? [String: Any]
        let codexExcluded = (excluded?["codex"] as? [String]) ?? []
        let excludeOverlapping = !codexExcluded.isEmpty
            ? true
            : fallback.routingExcludeCodexOverlappingModels
        let codex = root["codex"] as? [String: Any]
        let optimizeMultiAgentV2 = (codex?["optimize-multi-agent-v2"] as? Bool)
            ?? fallback.optimizeCodexMultiAgentV2

        return CoreConfigSettings(
            apiKeys: apiKeys,
            port: port,
            allowLan: allowLan,
            routingStrategy: strategy,
            proxyUrl: proxy,
            routingSessionAffinity: sessionAffinity,
            routingSessionAffinityTtl: sessionTTL,
            routingExcludeCodexOverlappingModels: excludeOverlapping,
            optimizeCodexMultiAgentV2: optimizeMultiAgentV2,
            managementSecretConfigured: !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private static func mergeYAML(template: String, current: String?, gui: GuiConfigFile) throws -> String {
        var base = template
        if let current,
           let currentRoot = try Yams.load(yaml: current) as? [String: Any],
           var templateRoot = try Yams.load(yaml: template) as? [String: Any]
        {
            deepMerge(into: &templateRoot, from: currentRoot)
            // Keep provider sections from current if present.
            base = try Yams.dump(object: templateRoot, width: -1, sortKeys: false)
        }
        return try applyGUIManagedSettings(to: base, gui: gui)
    }

    private static func deepMerge(into target: inout [String: Any], from source: [String: Any]) {
        for (key, value) in source {
            if var targetDict = target[key] as? [String: Any], let sourceDict = value as? [String: Any] {
                deepMerge(into: &targetDict, from: sourceDict)
                target[key] = targetDict
            } else {
                target[key] = value
            }
        }
    }

    private static func applyGUIManagedSettings(to content: String, gui: GuiConfigFile) throws -> String {
        guard var root = try Yams.load(yaml: content) as? [String: Any] else {
            return minimalConfigYAML(gui: gui)
        }

        root["host"] = gui.effectiveHost
        root["port"] = Int(gui.port)
        root["auth-dir"] = gui.authDir
        root["usage-statistics-enabled"] = gui.usageStatisticsEnabled
        root["proxy-url"] = gui.proxyUrl
        root["api-keys"] = resolvedAPIKeys(gui: gui, existingRoot: root)

        var remote = (root["remote-management"] as? [String: Any]) ?? [:]
        // Keep existing bcrypt hash if GUI still has the plaintext default placeholder
        // and yaml already stores a hashed secret — avoid thrashing auth.
        let guiSecret = gui.managementSecretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingSecret = (remote["secret-key"] as? String) ?? ""
        if guiSecret.isEmpty {
            // leave existing
        } else if existingSecret.hasPrefix("$2a$") || existingSecret.hasPrefix("$2b$") {
            // Core already hashed the secret; only replace if GUI changed away from known plaintext.
            // Plain "123456" matching default should not overwrite hash every restart.
            if guiSecret != AppPaths.defaultManagementSecret && guiSecret != existingSecret {
                remote["secret-key"] = guiSecret
            }
        } else {
            remote["secret-key"] = guiSecret
        }
        if remote["allow-remote"] == nil {
            remote["allow-remote"] = false
        }
        root["remote-management"] = remote

        var routing = (root["routing"] as? [String: Any]) ?? [:]
        routing["strategy"] = gui.routingStrategy
        routing["session-affinity"] = gui.routingSessionAffinity
        routing["session-affinity-ttl"] = Self.normalizeSessionAffinityTTL(gui.routingSessionAffinityTtl)
        root["routing"] = routing

        applyCodexOverlappingExclusions(to: &root, enabled: gui.routingExcludeCodexOverlappingModels)
        applyCodexOptimizeMultiAgentV2(to: &root, enabled: gui.optimizeCodexMultiAgentV2)

        return try Yams.dump(object: root, width: -1, sortKeys: false)
    }

    /// Value a native-Responses leg needs for `disable-image-generation`.
    ///
    /// CPA injects an `image_generation` tool into Responses requests by default, and some
    /// `codex-api-key` upstreams reject it (e.g. `imagegen deployment must be provided through
    /// header: …`). `chat` suppresses the injection while keeping `/v1/images/*` usable, unlike `true`.
    static let nativeResponsesImageGenerationMode = "chat"

    /// Apply the config-level prerequisite for GPT models routed via native Responses.
    ///
    /// Applied on the live config rather than only the GUI template, so an already-running core
    /// picks it up without a restart. Returns true when the value had to be changed.
    @discardableResult
    static func ensureNativeResponsesPrerequisites(client: ManagementClient) async throws -> Bool {
        let yaml = try await client.getConfigYAML()
        guard var root = try Yams.load(yaml: yaml) as? [String: Any] else { return false }
        let current = root["disable-image-generation"]
        if let mode = current as? String, mode == nativeResponsesImageGenerationMode {
            return false
        }
        // `true` already suppresses injection; don't downgrade a stricter user choice.
        if let flag = current as? Bool, flag { return false }
        root["disable-image-generation"] = nativeResponsesImageGenerationMode
        try await client.putConfigYAML(try Yams.dump(object: root, width: -1, sortKeys: false))
        return true
    }

    /// Go `time.ParseDuration` requires a unit (`30s`, `30m`, `1h`). Bare numbers are treated as seconds.
    static func normalizeSessionAffinityTTL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "1h" }
        if trimmed.range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) != nil {
            return "\(trimmed)s"
        }
        return trimmed
    }

    static let codexOverlappingModelExclusions: [String] = [
        "gpt-5.6*",
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.3-codex",
    ]

    private static func applyCodexOverlappingExclusions(to root: inout [String: Any], enabled: Bool) {
        var excluded = (root["oauth-excluded-models"] as? [String: Any]) ?? [:]
        if enabled {
            excluded["codex"] = codexOverlappingModelExclusions
        } else {
            excluded.removeValue(forKey: "codex")
        }
        if excluded.isEmpty {
            root.removeValue(forKey: "oauth-excluded-models")
        } else {
            root["oauth-excluded-models"] = excluded
        }
    }

    /// Write CPA `codex.optimize-multi-agent-v2`, preserving sibling keys under `codex:`.
    static func applyCodexOptimizeMultiAgentV2(to root: inout [String: Any], enabled: Bool) {
        var codex = (root["codex"] as? [String: Any]) ?? [:]
        codex["optimize-multi-agent-v2"] = enabled
        root["codex"] = codex
    }

    /// Prefer GUI / durable JSON keys. Only fall back to existing yaml when no durable store exists
    /// (guards against accidental wipe from a stale empty in-memory list).
    private static func resolvedAPIKeys(gui: GuiConfigFile, existingRoot: [String: Any]) -> [String] {
        let fromGUI = gui.apiKeys
            .map { $0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !fromGUI.isEmpty {
            return fromGUI
        }

        // Durable JSON exists → honor it, including intentional empty after user deleted all keys.
        if FileManager.default.fileExists(atPath: AppPaths.apiKeysURL.path),
           let data = try? Data(contentsOf: AppPaths.apiKeysURL),
           let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        {
            return rows.compactMap { row -> String? in
                let key = (row["apiKey"] as? String) ?? (row["key"] as? String) ?? ""
                let t = key.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
        }

        // No durable store yet: keep existing yaml keys if any.
        if let existing = existingRoot["api-keys"] as? [String] {
            let cleaned = existing.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !cleaned.isEmpty { return cleaned }
        }
        if let existing = existingRoot["api-keys"] as? [[String: Any]] {
            let cleaned = existing.compactMap { item -> String? in
                let key = (item["api-key"] as? String) ?? (item["key"] as? String) ?? ""
                let t = key.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            if !cleaned.isEmpty { return cleaned }
        }
        return []
    }

    private static func patchAPIKeys(in content: String, keys: [String]) throws -> String {
        guard var root = try Yams.load(yaml: content) as? [String: Any] else {
            return content
        }
        // Explicit patch always writes the provided list (including intentional empty after delete).
        root["api-keys"] = keys
        return try Yams.dump(object: root, width: -1, sortKeys: false)
    }

    private static func minimalConfigYAML(gui: GuiConfigFile) -> String {
        let keys = gui.apiKeys.map { "  - \(yamlQuote($0.apiKey))" }.joined(separator: "\n")
        var yaml = """
        host: \(yamlQuote(gui.effectiveHost))
        port: \(gui.port)
        auth-dir: \(yamlQuote(gui.authDir))
        api-keys:
        \(keys.isEmpty ? "  []" : keys)
        usage-statistics-enabled: \(gui.usageStatisticsEnabled)
        proxy-url: \(yamlQuote(gui.proxyUrl))
        remote-management:
          allow-remote: false
          secret-key: \(yamlQuote(gui.managementSecretKey))
        plugins:
          enabled: false
        routing:
          strategy: \(yamlQuote(gui.routingStrategy))
          session-affinity: \(gui.routingSessionAffinity)
          session-affinity-ttl: \(yamlQuote(Self.normalizeSessionAffinityTTL(gui.routingSessionAffinityTtl)))
        codex:
          optimize-multi-agent-v2: \(gui.optimizeCodexMultiAgentV2)
        """
        if gui.routingExcludeCodexOverlappingModels {
            let items = codexOverlappingModelExclusions.map { "  - \(yamlQuote($0))" }.joined(separator: "\n")
            yaml += """
            
            oauth-excluded-models:
              codex:
            \(items)
            """
        }
        return yaml
    }

    private static func yamlQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
