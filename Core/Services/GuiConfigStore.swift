import Foundation

struct GuiConfigFile: Equatable, Sendable {
    var locale: String = "zh-CN"
    var port: UInt16 = AppPaths.defaultPort
    var allowLan: Bool = false
    var host: String = "127.0.0.1"
    var runOnStartup: Bool = false
    var authDir: String = AppPaths.defaultAuthDir
    /// Empty by default; first-run seeding injects a default key once when the file is created.
    var apiKeys: [GuiApiKey] = []
    var apiAccessRemarks: [String: String] = [:]
    var managementSecretKey: String = AppPaths.defaultManagementSecret
    var usageStatisticsEnabled: Bool = true
    var routingStrategy: String = "round-robin"
    var proxyUrl: String = ""
    var routingSessionAffinity: Bool = false
    var routingSessionAffinityTtl: String = ""
    /// When true, overlapping GPT ids are excluded from Codex OAuth so fill-first priority can stick to API providers.
    var routingExcludeCodexOverlappingModels: Bool = false
    /// CPA `codex.optimize-multi-agent-v2`. Default on: plaintext agent `encrypted_content` → `input_text`.
    var optimizeCodexMultiAgentV2: Bool = true
    var theme: String = AppThemePreference.system.rawValue
    var codexSessionRepairOnLaunch: Bool = false

    var effectiveHost: String {
        allowLan ? "0.0.0.0" : "127.0.0.1"
    }

    var displayHost: String {
        allowLan ? (localLANIPv4() ?? "0.0.0.0") : "127.0.0.1"
    }

    var guiSettings: GuiSettings {
        GuiSettings(port: port, allowLan: allowLan, runOnStartup: runOnStartup)
    }

    var coreConfigSettings: CoreConfigSettings {
        CoreConfigSettings(
            apiKeys: apiKeys,
            port: port,
            allowLan: allowLan,
            routingStrategy: routingStrategy,
            proxyUrl: proxyUrl,
            routingSessionAffinity: routingSessionAffinity,
            routingSessionAffinityTtl: routingSessionAffinityTtl,
            routingExcludeCodexOverlappingModels: routingExcludeCodexOverlappingModels,
            optimizeCodexMultiAgentV2: optimizeCodexMultiAgentV2,
            managementSecretConfigured: !managementSecretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }
}

@MainActor
final class GuiConfigStore {
    private(set) var config: GuiConfigFile
    private let fileURL: URL
    private let apiKeysURL: URL

    init(
        fileURL: URL = AppPaths.guiConfigURL,
        apiKeysURL: URL = AppPaths.apiKeysURL
    ) {
        self.fileURL = fileURL
        self.apiKeysURL = apiKeysURL
        try? AppPaths.ensurePrivateDirectory(fileURL.deletingLastPathComponent())
        if apiKeysURL.deletingLastPathComponent() != fileURL.deletingLastPathComponent() {
            try? AppPaths.ensurePrivateDirectory(apiKeysURL.deletingLastPathComponent())
        }

        if let loaded = Self.load(from: fileURL, apiKeysURL: apiKeysURL) {
            self.config = loaded
            // Ensure durable JSON sidecar exists for existing installs.
            try? Self.saveAPIKeys(loaded.apiKeys, to: apiKeysURL)
            try? AppPaths.secureSensitiveFile(fileURL)
            try? AppPaths.secureSensitiveFile(apiKeysURL)
        } else {
            var fresh = GuiConfigFile()
            fresh.apiKeys = [
                GuiApiKey(
                    apiKey: SecureToken.generate(length: 32, prefix: "sk-"),
                    remark: AppPaths.defaultAPIKeyRemark
                ),
            ]
            fresh.managementSecretKey = SecureToken.generate(length: 48)
            self.config = fresh
            try? Self.save(fresh, to: fileURL, apiKeysURL: apiKeysURL)
        }
    }

    func reload() {
        if let loaded = Self.load(from: fileURL, apiKeysURL: apiKeysURL) {
            config = loaded
        }
    }

    /// Always re-read disk before handing config to the core (start/restart/sync).
    func snapshotFresh() -> GuiConfigFile {
        reload()
        return config
    }

    func snapshot() -> GuiConfigFile { config }

    @discardableResult
    func update(_ mutate: (inout GuiConfigFile) -> Void) throws -> GuiConfigFile {
        // Re-read disk first so concurrent/stale memory cannot clobber saved keys.
        if let disk = Self.load(from: fileURL, apiKeysURL: apiKeysURL) {
            config = disk
        }
        var next = config
        mutate(&next)
        next.host = next.allowLan ? "0.0.0.0" : "127.0.0.1"
        try Self.save(next, to: fileURL, apiKeysURL: apiKeysURL)
        config = next
        return next
    }

    @discardableResult
    func setRunOnStartup(_ value: Bool) throws -> GuiConfigFile {
        try update { $0.runOnStartup = value }
    }

    @discardableResult
    func saveNetwork(port: UInt16, allowLan: Bool) throws -> GuiConfigFile {
        try update {
            $0.port = port
            $0.allowLan = allowLan
            $0.host = allowLan ? "0.0.0.0" : "127.0.0.1"
        }
    }

    // MARK: - Load / Save

    private static func load(from url: URL, apiKeysURL: URL) -> GuiConfigFile? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            // TOML missing — still try JSON keys for recovery.
            if let keys = loadAPIKeys(from: apiKeysURL), !keys.isEmpty {
                var cfg = GuiConfigFile()
                cfg.apiKeys = keys
                return cfg
            }
            return nil
        }
        var config = parseTOML(text)
        // JSON sidecar is the durable source of truth for keys when present.
        if let keys = loadAPIKeys(from: apiKeysURL) {
            config.apiKeys = keys
        } else if !config.apiKeys.isEmpty {
            // Migrate TOML keys → JSON once.
            try? saveAPIKeys(config.apiKeys, to: apiKeysURL)
        }
        return config
    }

    private static func save(_ config: GuiConfigFile, to url: URL, apiKeysURL: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = encodeTOML(config)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try AppPaths.secureSensitiveFile(url)
        try saveAPIKeys(config.apiKeys, to: apiKeysURL)
    }

    private static func loadAPIKeys(from url: URL) -> [GuiApiKey]? {
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return nil
        }
        let keys: [GuiApiKey] = rows.compactMap { row in
            let key = (row["apiKey"] as? String) ?? (row["key"] as? String) ?? ""
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let remark = (row["remark"] as? String) ?? ""
            return GuiApiKey(apiKey: trimmed, remark: remark)
        }
        // Distinguish "file missing" (nil) from "file exists with empty list".
        // Empty array is a valid intentional state.
        return keys
    }

    private static func saveAPIKeys(_ keys: [GuiApiKey], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rows: [[String: String]] = keys.map { ["apiKey": $0.apiKey, "remark": $0.remark] }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
        try AppPaths.secureSensitiveFile(url)
    }

    // MARK: - TOML (minimal)

    private static func parseTOML(_ text: String) -> GuiConfigFile {
        var config = GuiConfigFile()
        var currentTable = ""
        var apiKeys: [GuiApiKey] = []
        var pendingKey: GuiApiKey?
        var remarks: [String: String] = [:]
        var remarkKey: String?
        var sawAPIKeysSection = false

        func flushKey() {
            if let key = pendingKey {
                let trimmed = key.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    var copy = key
                    copy.apiKey = trimmed
                    apiKeys.append(copy)
                }
            }
            pendingKey = nil
        }

        func flushRemark() {
            if let key = remarkKey {
                remarks[key] = remarks[key] ?? ""
            }
            remarkKey = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                flushKey()
                flushRemark()
                let table = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if table == "api-keys" || table.hasPrefix("api-keys.") {
                    currentTable = "api-keys"
                    sawAPIKeysSection = true
                    pendingKey = GuiApiKey(apiKey: "", remark: "")
                } else if table == "api-access-remarks" || table.hasPrefix("api-access-remarks.") {
                    currentTable = "api-access-remarks"
                    remarkKey = nil
                } else {
                    currentTable = table
                }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let value = unquote(rawValue)

            switch currentTable {
            case "api-keys":
                if pendingKey == nil {
                    pendingKey = GuiApiKey(apiKey: "", remark: "")
                }
                if key == "key" || key == "api-key" {
                    pendingKey?.apiKey = value
                } else if key == "remark" {
                    pendingKey?.remark = value
                }
            case "api-access-remarks":
                if key == "id" || key == "key" {
                    remarkKey = value
                    remarks[value] = remarks[value] ?? ""
                } else if key == "remark", let remarkKey {
                    remarks[remarkKey] = value
                }
            default:
                if key == "api-keys" || key == "api_keys" {
                    sawAPIKeysSection = true
                    if let array = extractTopLevelStringArray(named: key, from: line) {
                        apiKeys = array.map { GuiApiKey(apiKey: $0, remark: "") }
                    }
                }
                applyTopLevel(key: key, value: value, rawValue: rawValue, into: &config)
            }
        }

        flushKey()
        flushRemark()

        // Only use extractStringArray fallback for true top-level arrays, not [[api-keys]] tables.
        if apiKeys.isEmpty, let array = extractTopLevelStringArray(named: "api-keys", from: text) {
            sawAPIKeysSection = true
            apiKeys = array.map { GuiApiKey(apiKey: $0, remark: "") }
        }

        if sawAPIKeysSection || !apiKeys.isEmpty {
            config.apiKeys = apiKeys
        }
        if !remarks.isEmpty {
            config.apiAccessRemarks = remarks
        }
        config.host = config.allowLan ? "0.0.0.0" : "127.0.0.1"
        return config
    }

    private static func applyTopLevel(key: String, value: String, rawValue: String, into config: inout GuiConfigFile) {
        switch key {
        case "locale":
            config.locale = value
        case "port":
            if let port = UInt16(value) { config.port = port }
        case "allow-lan", "allow_lan":
            config.allowLan = parseBool(rawValue)
        case "host":
            config.host = value
        case "run-on-startup", "run_on_startup":
            config.runOnStartup = parseBool(rawValue)
        case "auth-dir", "auth_dir":
            config.authDir = value
        case "management-secret-key", "management_secret_key":
            config.managementSecretKey = value
        case "usage-statistics-enabled", "usage_statistics_enabled":
            config.usageStatisticsEnabled = parseBool(rawValue)
        case "routing-strategy", "routing_strategy":
            config.routingStrategy = value
        case "proxy-url", "proxy_url":
            config.proxyUrl = value
        case "routing-session-affinity", "routing_session_affinity":
            config.routingSessionAffinity = parseBool(rawValue)
        case "routing-session-affinity-ttl", "routing_session_affinity_ttl":
            config.routingSessionAffinityTtl = value
        case "routing-exclude-codex-overlapping-models", "routing_exclude_codex_overlapping_models":
            config.routingExcludeCodexOverlappingModels = parseBool(rawValue)
        case "optimize-codex-multi-agent-v2", "optimize_codex_multi_agent_v2":
            config.optimizeCodexMultiAgentV2 = parseBool(rawValue)
        case "theme":
            config.theme = value
        case "codex-session-repair-on-launch", "codex_session_repair_on_launch":
            config.codexSessionRepairOnLaunch = parseBool(rawValue)
        default:
            break
        }
    }

    private static func encodeTOML(_ config: GuiConfigFile) -> String {
        var lines: [String] = [
            "# MacCLIProxyAPI GUI config",
            "locale = \(quote(config.locale))",
            "port = \(config.port)",
            "allow-lan = \(config.allowLan)",
            "host = \(quote(config.host))",
            "run-on-startup = \(config.runOnStartup)",
            "auth-dir = \(quote(config.authDir))",
            "management-secret-key = \(quote(config.managementSecretKey))",
            "usage-statistics-enabled = \(config.usageStatisticsEnabled)",
            "routing-strategy = \(quote(config.routingStrategy))",
            "proxy-url = \(quote(config.proxyUrl))",
            "routing-session-affinity = \(config.routingSessionAffinity)",
            "routing-session-affinity-ttl = \(quote(config.routingSessionAffinityTtl))",
            "routing-exclude-codex-overlapping-models = \(config.routingExcludeCodexOverlappingModels)",
            "optimize-codex-multi-agent-v2 = \(config.optimizeCodexMultiAgentV2)",
            "theme = \(quote(config.theme))",
            "codex-session-repair-on-launch = \(config.codexSessionRepairOnLaunch)",
            "",
        ]

        // Always write both forms: top-level array for robust parse + table for remarks.
        let keyLiterals = config.apiKeys.map { quote($0.apiKey) }.joined(separator: ", ")
        lines.append("api-keys = [\(keyLiterals)]")
        lines.append("")

        for key in config.apiKeys {
            lines.append("[[api-keys]]")
            lines.append("key = \(quote(key.apiKey))")
            lines.append("remark = \(quote(key.remark))")
            lines.append("")
        }

        for (id, remark) in config.apiAccessRemarks.sorted(by: { $0.key < $1.key }) {
            lines.append("[[api-access-remarks]]")
            lines.append("id = \(quote(id))")
            lines.append("remark = \(quote(remark))")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func unquote(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { return "" }
        if let hash = text.firstIndex(of: "#"), !text.contains("\"") {
            text = String(text[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        if text.hasPrefix("\"") && text.hasSuffix("\"") && text.count >= 2 {
            text = String(text.dropFirst().dropLast())
            text = text
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return text
    }

    private static func parseBool(_ raw: String) -> Bool {
        let value = unquote(raw).lowercased()
        return value == "true" || value == "1" || value == "yes"
    }

    /// Parse `api-keys = ["a", "b"]` only — never matches `[[api-keys]]` tables.
    private static func extractTopLevelStringArray(named name: String, from text: String) -> [String]? {
        // Prefer a single-line assignment match.
        let pattern = #"^\s*"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*\[(.*?)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let bodyRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        let body = String(text[bodyRange])
        return body
            .split(separator: ",")
            .map { unquote(String($0)) }
            .filter { !$0.isEmpty }
    }
}

func localLANIPv4() -> String? {
    var address: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }

    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let interface = ptr.pointee
        let family = interface.ifa_addr.pointee.sa_family
        guard family == UInt8(AF_INET) else { continue }
        let name = String(cString: interface.ifa_name)
        guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(
            interface.ifa_addr,
            socklen_t(interface.ifa_addr.pointee.sa_len),
            &hostname,
            socklen_t(hostname.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        let ip = String(cString: hostname)
        if ip.hasPrefix("127.") { continue }
        address = ip
        break
    }
    return address
}
