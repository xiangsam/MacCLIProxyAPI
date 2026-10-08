import Foundation
import Yams

/// YAML boundary adapter for CPA v7 and v8. Paths follow upstream v8.0.21 config_v8.go.
/// Runtime management endpoints remain v0-compatible; grouped credentials stay intact on edits.
enum CoreConfigLayout {
    static let paths: [(String, String)] = [
        ("codex.optimize-multi-agent-v2", "client.codex.optimize-multi-agent-v2"),
        ("host", "server.host"),
        ("port", "server.port"),
        ("trusted-proxies", "server.trusted-proxies"),
        ("github-token", "server.github-token"),
        ("tls", "server.tls"),
        ("commercial-mode", "server.commercial-mode"),
        ("discovery", "server.discovery"),
        ("remote-management", "management"),
        ("api-keys", "access.api-keys"),
        ("credential-concurrency", "credentials.concurrency"),
        ("credential-in-flight", "credentials.in-flight"),
        ("force-model-prefix", "routing.force-model-prefix"),
        ("request-retry", "routing.retry.request-retry"),
        ("max-retry-credentials", "routing.retry.max-retry-credentials"),
        ("max-retry-interval", "routing.retry.max-retry-interval"),
        ("disable-cooling", "routing.cooldown.disable-cooling"),
        ("save-cooldown-status", "routing.cooldown.save-cooldown-status"),
        ("transient-error-cooldown-seconds", "routing.cooldown.transient-error-cooldown-seconds"),
        ("proxy-url", "requests.proxy-url"),
        ("passthrough-headers", "requests.passthrough-headers"),
        ("nonstream-keepalive-interval", "requests.nonstream-keepalive-interval"),
        ("streaming", "requests.streaming"),
        ("payload", "requests.payload"),
        ("auth-dir", "oauth.auth-dir"),
        ("auth-auto-refresh-workers", "oauth.auth-auto-refresh-workers"),
        ("oauth-model-alias", "oauth.model-alias"),
        ("oauth-excluded-models", "oauth.excluded-models"),
        ("oauth-request-scoped-errors", "oauth.request-scoped-errors"),
        ("oauth-settings", "oauth.settings"),
        ("ws-auth", "oauth.providers.aistudio.ws-auth"),
        ("codex.disable-codex-cloaking", "upstream.codex.disable-codex-cloaking"),
        ("codex.stream-bootstrap-buffering", "upstream.codex.stream-bootstrap-buffering"),
        ("codex.stream-bootstrap-timeout", "upstream.codex.stream-bootstrap-timeout"),
        ("codex.orphan-delegation-compatibility", "upstream.codex.orphan-delegation-compatibility"),
        ("codex.model-level-cooling", "upstream.codex.model-level-cooling"),
        ("codex.response-steering", "upstream.codex.response-steering"),
        ("codex", "oauth.providers.codex"),
        ("codex-header-defaults", "oauth.providers.codex.header-defaults"),
        ("claude", "upstream.claude"),
        ("claude-code", "upstream.claude"),
        ("disable-claude-cloak-mode", "upstream.claude.disable-claude-cloak-mode"),
        ("claude-header-defaults", "upstream.claude.header-defaults"),
        ("antigravity", "oauth.providers.antigravity"),
        ("antigravity-signature-cache-enabled", "oauth.providers.antigravity.signature-cache-enabled"),
        ("antigravity-signature-bypass-strict", "oauth.providers.antigravity.signature-bypass-strict"),
        ("quota-exceeded.antigravity-credits", "oauth.providers.antigravity.antigravity-credits"),
        ("xai", "upstream.xai"),
        ("devin", "oauth.providers.devin"),
        ("disable-image-generation", "multimedia.disable-image-generation"),
        ("gpt-image-2-base-model", "multimedia.gpt-image-2-base-model"),
        ("video-result-auth-cache-ttl", "multimedia.video-result-auth-cache-ttl"),
        ("debug", "observability.logs.debug"),
        ("logging-to-file", "observability.logs.logging-to-file"),
        ("logs-max-total-size-mb", "observability.logs.logs-max-total-size-mb"),
        ("request-log", "observability.logs.request-log"),
        ("error-logs-max-files", "observability.logs.error-logs-max-files"),
        ("usage-statistics-enabled", "observability.usage.usage-statistics-enabled"),
        ("redis-usage-queue-retention-seconds", "observability.usage.redis-usage-queue-retention-seconds"),
        ("pprof", "observability.pprof"),
    ]
    private static let aliases: [(String, String)] = [
        ("oauth.providers.codex.optimize-multi-agent-v2", "client.codex.optimize-multi-agent-v2"),
        ("providers.codex.optimize-multi-agent-v2", "client.codex.optimize-multi-agent-v2"),
        ("codex.optimize-multi-agent-v2", "client.codex.optimize-multi-agent-v2"),
        ("oauth.providers.codex.disable-codex-cloaking", "upstream.codex.disable-codex-cloaking"),
        ("oauth.providers.codex.stream-bootstrap-buffering", "upstream.codex.stream-bootstrap-buffering"),
        ("oauth.providers.codex.stream-bootstrap-timeout", "upstream.codex.stream-bootstrap-timeout"),
        ("oauth.providers.codex.orphan-delegation-compatibility", "upstream.codex.orphan-delegation-compatibility"),
        ("oauth.providers.codex.model-level-cooling", "upstream.codex.model-level-cooling"),
        ("oauth.providers.codex.response-steering", "upstream.codex.response-steering"),
        ("oauth.providers.claude.model-level-cooling", "upstream.claude.model-level-cooling"),
        ("oauth.providers.claude.claude-code.disable-cloaking-model-list", "upstream.claude.disable-cloaking-model-list"),
        ("oauth.providers.claude.disable-claude-cloak-mode", "upstream.claude.disable-claude-cloak-mode"),
        ("oauth.providers.claude.header-defaults.user-agent", "upstream.claude.header-defaults.user-agent"),
        ("oauth.providers.claude.header-defaults.package-version", "upstream.claude.header-defaults.package-version"),
        ("oauth.providers.claude.header-defaults.runtime-version", "upstream.claude.header-defaults.runtime-version"),
        ("oauth.providers.claude.header-defaults.os", "upstream.claude.header-defaults.os"),
        ("oauth.providers.claude.header-defaults.arch", "upstream.claude.header-defaults.arch"),
        ("oauth.providers.claude.header-defaults.timeout", "upstream.claude.header-defaults.timeout"),
        ("oauth.providers.claude.header-defaults.timezone", "upstream.claude.header-defaults.timezone"),
        ("oauth.providers.claude.header-defaults.stabilize-device-profile", "upstream.claude.header-defaults.stabilize-device-profile"),
        ("oauth.providers.xai.inject-x-search", "upstream.xai.inject-x-search"),
    ]
    static let families: [(String, String)] = [
        ("gemini-api-key", "gemini"),
        ("interactions-api-key", "interactions"),
        ("vertex-api-key", "vertex"),
        ("codex-api-key", "codex"),
        ("claude-api-key", "claude"),
        ("xai-api-key", "xai"),
        ("meta-api-key", "meta"),
        ("openai-compatibility", "openai-compatibility"),
    ]
    private static let sharedFields: Set<String> = [
        "priority", "prefix", "proxy-url", "headers", "models", "excluded-models",
        "disable-cooling", "request-retry", "request-scoped-errors",
    ]

    static func parse(_ yaml: String) throws -> [String: Any] {
        guard let root = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw AppError("内核配置必须是 YAML 对象；未覆盖原文件")
        }
        if let version = root["config-version"], (version as? Int) != 8 {
            throw AppError("不支持的内核配置版本；未覆盖原文件")
        }
        return root
    }

    static func isV8(_ root: [String: Any]) -> Bool {
        if root["config-version"] != nil || root["api-keys"] is [String: Any] { return true }
        return ["server", "management", "access", "credentials", "requests", "oauth", "upstream", "observability", "multimedia", "models"].contains { root[$0] != nil }
            || (paths + aliases).contains { value(root, $0.1) != nil }
    }

    /// Canonical fields win by presence, including false, null and empty collections.
    static func canonical(_ original: [String: Any]) throws -> [String: Any] {
        var root = original
        for (old, current) in aliases + paths {
            if old == "api-keys", root[old] is [String: Any] { continue }
            guard let existing = value(root, old) else { continue }
            let preferred = value(root, current)
            remove(&root, old)
            try set(&root, current, mergeFallback(existing, preferred: preferred))
        }
        for (legacy, family) in families {
            if let rows = root[legacy] {
                let path = "api-keys.\(family)"
                if value(root, path) == nil {
                    guard let list = rows as? [[String: Any]] else {
                        throw AppError("\(legacy) 必须是列表")
                    }
                    try set(&root, path, grouped(list, family: family))
                }
                root.removeValue(forKey: legacy)
            }
        }
        root["config-version"] = 8
        // Validate grouped credentials before any caller writes or installs this document.
        _ = try expandedFamilies(root)
        return root
    }

    static func legacyView(_ original: [String: Any]) throws -> [String: Any] {
        guard isV8(original) else { return original }
        let canonical = try canonical(original)
        let credentials = try expandedFamilies(canonical)
        var root = canonical
        // api-keys has different meanings in the two layouts.
        root.removeValue(forKey: "api-keys")
        root.removeValue(forKey: "config-version")
        for (old, current) in paths {
            guard let item = value(canonical, current) else { continue }
            remove(&root, current)
            try set(&root, old, mergeFallback(item, preferred: value(root, old)))
        }
        for (key, rows) in credentials { root[key] = rows }
        return root
    }

    static func readLegacy(_ yaml: String) throws -> [String: Any] {
        try legacyView(parse(yaml))
    }

    /// Apply the existing GUI operations to a legacy view, then patch only changed fields
    /// back into v8. Unchanged key overrides, group names and unknown settings survive.
    static func mutate(_ yaml: String, _ edit: (inout [String: Any]) throws -> Void) throws -> String {
        let original = try parse(yaml)
        guard isV8(original) else {
            var root = original
            try edit(&root)
            return try dump(root)
        }
        var root = try canonical(original)
        let before = try legacyView(root)
        var after = before
        try edit(&after)
        let providerKeys = Set(families.map(\.0))
        for key in Set(before.keys).union(after.keys) where !providerKeys.contains(key) {
            try applyDifference(before[key], after[key], legacyPath: key, to: &root)
        }
        for (legacy, family) in families where !equal(before[legacy], after[legacy]) {
            guard let rows = after[legacy] as? [[String: Any]] else {
                remove(&root, "api-keys.\(family)")
                continue
            }
            if family == "openai-compatibility" {
                try set(&root, "api-keys.\(family)", grouped(rows, family: family))
                continue
            }
            var groups = value(root, "api-keys.\(family)") as? [[String: Any]] ?? []
            let previous = before[legacy] as? [[String: Any]] ?? []
            guard rows.count == previous.count else {
                throw AppError("分组凭据数量已变化，请通过上游 API 编辑器修改")
            }
            var offset = 0
            for groupIndex in groups.indices {
                var keys = groups[groupIndex]["keys"] as? [[String: Any]] ?? []
                for keyIndex in keys.indices {
                    for field in Set(previous[offset].keys).union(rows[offset].keys)
                        where !equal(previous[offset][field], rows[offset][field]) {
                        guard field != "base-url" else {
                            throw AppError("v8 的 base-url 属于整个分组，请通过上游 API 编辑器修改")
                        }
                        // null means inherit in v8; [] explicitly clears inherited lists.
                        if let item = rows[offset][field] { keys[keyIndex][field] = item }
                        else if previous[offset][field] is [Any] { keys[keyIndex][field] = [Any]() }
                        else { keys[keyIndex].removeValue(forKey: field) }
                    }
                    offset += 1
                }
                groups[groupIndex]["keys"] = keys
            }
            try set(&root, "api-keys.\(family)", groups)
        }
        if usesEarlyV8Paths(original) { root = try earlyV8(root) }
        return try dump(root)
    }

    /// Early v8 releases only understand the OAuth paths. Newer v8 releases accept them
    /// as aliases; keep this spelling until installation explicitly migrates to the new one.
    static func usesEarlyV8Paths(_ root: [String: Any]) -> Bool {
        root["client"] == nil && root["upstream"] == nil
    }

    private static func earlyV8(_ original: [String: Any]) throws -> [String: Any] {
        var root = original
        for (old, current) in aliases where old.hasPrefix("oauth.providers.") {
            guard let item = value(root, current) else { continue }
            remove(&root, current)
            try set(&root, old, item)
        }
        return root
    }

    static func migrate(_ yaml: String, to version: String) throws -> String {
        let root = try parse(yaml)
        guard let major = Int(AppPaths.normalizeVersion(version).split(separator: ".").first ?? "") else {
            // Unknown local archives must not guess a schema downgrade.
            guard !isV8(root) else {
                throw AppError("本地安装包版本未知，无法确认支持 v8 配置；请使用带版本号和配置示例的安装包")
            }
            return yaml
        }
        if major < 8 {
            guard !isV8(root) else {
                throw AppError("当前配置使用 CPA v8 格式，不能直接安装 v7；请先恢复升级前的配置备份")
            }
            return yaml
        }
        guard major == 8 else { throw AppError("尚未验证 CPA v\(major) 配置迁移，已保留当前安装") }
        let numbers = AppPaths.normalizeVersion(version).split(separator: "-")[0].split(separator: ".").compactMap { Int($0) }
        let earlyTarget = numbers.count == 3 && numbers[1] == 0 && numbers[2] < 21
        if earlyTarget, isV8(root), !usesEarlyV8Paths(root) {
            throw AppError("新版 v8 配置不能直接回退到早期 v8；请先恢复对应版本的配置备份")
        }
        let migrated = try canonical(root)
        return try dump(earlyTarget ? earlyV8(migrated) : migrated)
    }

    static func dump(_ root: [String: Any]) throws -> String {
        try Yams.dump(object: root, width: -1, sortKeys: false)
    }

    private static func expandedFamilies(_ root: [String: Any]) throws -> [String: [[String: Any]]] {
        var result: [String: [[String: Any]]] = [:]
        for (legacy, family) in families {
            guard let raw = value(root, "api-keys.\(family)") else { continue }
            guard let groups = raw as? [[String: Any]] else { throw AppError("api-keys.\(family) 必须是列表") }
            var rows: [[String: Any]] = []
            for group in groups {
                guard let keys = group["keys"] as? [[String: Any]] else {
                    throw AppError("api-keys.\(family) 分组的 keys 必须是列表")
                }
                if family == "openai-compatibility" {
                    var row = group
                    row.removeValue(forKey: "keys")
                    row["api-key-entries"] = keys
                    rows.append(row)
                } else {
                    for key in keys {
                        guard key["base-url"] == nil else { throw AppError("v8 的 base-url 必须放在分组中") }
                        var row = group.filter { sharedFields.contains($0.key) || $0.key == "base-url" }
                        for (field, item) in key where !(item is NSNull) { row[field] = item }
                        rows.append(row)
                    }
                }
            }
            result[legacy] = rows
        }
        return result
    }

    private static func grouped(_ rows: [[String: Any]], family: String) -> [[String: Any]] {
        rows.enumerated().map { index, row in
            if family == "openai-compatibility" {
                var group = row
                var keys = group.removeValue(forKey: "api-key-entries") as? [[String: Any]]
                if keys == nil, let key = group["api-key"] as? String { keys = [["api-key": key]] }
                if keys == nil, let legacyKeys = group["api-keys"] as? [String] {
                    keys = legacyKeys.map { ["api-key": $0] }
                }
                group.removeValue(forKey: "api-key")
                group.removeValue(forKey: "api-keys")
                group["keys"] = keys ?? []
                return group
            }
            var group: [String: Any] = ["name": "\(family)-\(index + 1)"]
            var key = row
            for (field, item) in row where sharedFields.contains(field) || field == "base-url" {
                group[field] = item
                key.removeValue(forKey: field)
            }
            // The GUI historically duplicated API keys in both spellings. Native families
            // only accept the top-level key; do not migrate this redundant compatibility field.
            key.removeValue(forKey: "api-key-entries")
            group["keys"] = [key]
            return group
        }
    }

    private static func applyDifference(_ before: Any?, _ after: Any?, legacyPath: String, to root: inout [String: Any]) throws {
        guard !equal(before, after) else { return }
        if before is [String: Any] || after is [String: Any] {
            let old = before as? [String: Any] ?? [:]
            let new = after as? [String: Any] ?? [:]
            for key in Set(old.keys).union(new.keys) {
                try applyDifference(old[key], new[key], legacyPath: legacyPath + "." + key, to: &root)
            }
            return
        }
        let mapping = paths.first { legacyPath == $0.0 || legacyPath.hasPrefix($0.0 + ".") }
        let path = mapping.map { $0.1 + legacyPath.dropFirst($0.0.count) } ?? legacyPath
        if let after { try set(&root, path, after) } else { remove(&root, path) }
    }

    private static func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a?, let b?): return NSDictionary(dictionary: ["value": a]).isEqual(to: ["value": b])
        default: return false
        }
    }

    private static func mergeFallback(_ fallback: Any, preferred: Any?) -> Any {
        guard let preferred else { return fallback }
        guard var result = fallback as? [String: Any], let overrides = preferred as? [String: Any] else { return preferred }
        for (key, item) in overrides { result[key] = result[key].map { mergeFallback($0, preferred: item) } ?? item }
        return result
    }

    static func value(_ root: [String: Any], _ path: String) -> Any? {
        var current: Any = root
        for part in path.split(separator: ".") {
            guard let next = (current as? [String: Any])?[String(part)] else { return nil }
            current = next
        }
        return current
    }

    private static func set(_ root: inout [String: Any], _ path: String, _ item: Any) throws {
        let parts = path.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { root[path] = item; return }
        if let existing = root[parts[0]], !(existing is [String: Any]), !(existing is NSNull) {
            throw AppError("配置字段 \(parts[0]) 必须是对象；未覆盖原文件")
        }
        var child = root[parts[0]] as? [String: Any] ?? [:]
        try set(&child, parts[1], item)
        root[parts[0]] = child
    }

    private static func remove(_ root: inout [String: Any], _ path: String) {
        let parts = path.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { root.removeValue(forKey: path); return }
        guard var child = root[parts[0]] as? [String: Any] else { return }
        remove(&child, parts[1])
        if child.isEmpty { root.removeValue(forKey: parts[0]) } else { root[parts[0]] = child }
    }
}
