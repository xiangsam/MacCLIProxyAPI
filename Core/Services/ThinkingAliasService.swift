import Foundation
import Yams

struct ThinkingAliasEntry: Identifiable, Equatable, Sendable {
    var id: String { alias }
    var sourceModel: String
    var alias: String
    var effort: String?
    var provider: String
    var kind: String
}

/// Thinking aliases live in CLIProxyAPI config.yaml (oauth-model-alias + payload.override),
/// not as a dedicated management CRUD path. EasyCLIProxyAPI edits YAML via config.yaml GET/PUT.
enum ThinkingAliasService {
    static func list(client: ManagementClient) async throws -> [ThinkingAliasEntry] {
        let yaml = try await client.getConfigYAML()
        return try parseAliases(from: yaml)
    }

    enum AliasChannel: String, CaseIterable, Identifiable, Sendable {
        case codexOAuth = "codex-oauth"
        case openaiCompatible = "openai-compatible"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .codexOAuth: return "Codex OAuth"
            case .openaiCompatible: return "OpenAI 兼容"
            }
        }

        var protocolName: String {
            switch self {
            case .codexOAuth: return "codex"
            case .openaiCompatible: return "openai"
            }
        }
    }

    /// Create thinking alias for Codex OAuth or OpenAI-compatible providers.
    static func createAlias(
        client: ManagementClient,
        channel: AliasChannel,
        sourceModel: String,
        alias: String,
        effort: String
    ) async throws -> [ThinkingAliasEntry] {
        let source = sourceModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliasID = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let effortValue = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw AppError("请填写源模型") }
        guard !aliasID.isEmpty else { throw AppError("请填写别名") }
        guard source.caseInsensitiveCompare(aliasID) != .orderedSame else {
            throw AppError("别名不能与源模型相同")
        }
        guard !effortValue.isEmpty else { throw AppError("请选择 effort") }

        let yaml = try await client.getConfigYAML()
        let existing = try parseAliases(from: yaml)
        if existing.contains(where: { $0.alias.caseInsensitiveCompare(aliasID) == .orderedSame }) {
            throw AppError("别名 \(aliasID) 已存在")
        }

        let updated = try mutateYAML(yaml) { root in
            switch channel {
            case .codexOAuth:
                var oauth = (root["oauth-model-alias"] as? [String: Any]) ?? [:]
                var codex = (oauth["codex"] as? [[String: Any]]) ?? []
                codex.append([
                    "name": source,
                    "alias": aliasID,
                    "fork": true,
                ])
                oauth["codex"] = codex
                root["oauth-model-alias"] = oauth
            case .openaiCompatible:
                // Append model alias into first openai-compatibility provider (or create one).
                var providers = (root["openai-compatibility"] as? [[String: Any]]) ?? []
                if providers.isEmpty {
                    providers = [[
                        "name": "default",
                        "base-url": "https://api.openai.com/v1",
                        "api-key": "",
                        "models": [] as [[String: Any]],
                    ]]
                }
                var models = (providers[0]["models"] as? [[String: Any]]) ?? []
                models.append([
                    "name": source,
                    "alias": aliasID,
                    "levels": [effortValue],
                ])
                providers[0]["models"] = models
                root["openai-compatibility"] = providers
            }

            appendEffortPayload(
                root: &root,
                alias: aliasID,
                protocolName: channel.protocolName,
                effort: effortValue,
                sourceModel: source
            )
        }

        try await client.putConfigYAML(updated)
        return try parseAliases(from: updated)
    }

    /// Backward-compatible wrapper.
    static func createCodexOAuthAlias(
        client: ManagementClient,
        sourceModel: String,
        alias: String,
        effort: String
    ) async throws -> [ThinkingAliasEntry] {
        try await createAlias(
            client: client,
            channel: .codexOAuth,
            sourceModel: sourceModel,
            alias: alias,
            effort: effort
        )
    }

    private static func appendEffortPayload(
        root: inout [String: Any],
        alias: String,
        protocolName: String,
        effort: String,
        sourceModel: String
    ) {
        var payload = (root["payload"] as? [String: Any]) ?? [:]
        var overrides = (payload["override"] as? [[String: Any]]) ?? []
        overrides.removeAll { rule in
            guard let models = rule["models"] as? [[String: Any]] else { return false }
            return models.contains { ($0["name"] as? String)?.caseInsensitiveCompare(alias) == .orderedSame }
        }
        var params: [String: Any] = [:]
        if protocolName == "openai" {
            params["reasoning_effort"] = effort
            if sourceModel.lowercased().hasPrefix("deepseek") {
                params["thinking.type"] = "enabled"
            }
        } else {
            params["reasoning.effort"] = effort
        }
        overrides.append([
            "models": [
                ["name": alias, "protocol": protocolName],
            ],
            "params": params,
        ])
        payload["override"] = overrides
        root["payload"] = payload
    }

    static func delete(client: ManagementClient, alias: String) async throws -> [ThinkingAliasEntry] {
        let aliasID = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !aliasID.isEmpty else { throw AppError("别名不能为空") }

        let yaml = try await client.getConfigYAML()
        var removed = false
        let updated = try mutateYAML(yaml) { root in
            if var oauth = root["oauth-model-alias"] as? [String: Any] {
                if var codex = oauth["codex"] as? [[String: Any]] {
                    let before = codex.count
                    codex.removeAll {
                        ($0["alias"] as? String)?.caseInsensitiveCompare(aliasID) == .orderedSame
                    }
                    if codex.count != before { removed = true }
                    if codex.isEmpty {
                        oauth.removeValue(forKey: "codex")
                    } else {
                        oauth["codex"] = codex
                    }
                }
                if oauth.isEmpty {
                    root.removeValue(forKey: "oauth-model-alias")
                } else {
                    root["oauth-model-alias"] = oauth
                }
            }

            // Also strip from openai-compatibility / codex-api-key model lists if present.
            for section in ["codex-api-key", "openai-compatibility"] {
                guard var providers = root[section] as? [[String: Any]] else { continue }
                for i in providers.indices {
                    guard var models = providers[i]["models"] as? [[String: Any]] else { continue }
                    let before = models.count
                    models.removeAll {
                        let alias = ($0["alias"] as? String) ?? ""
                        let name = ($0["name"] as? String) ?? ""
                        // Thinking alias entries usually have alias != name
                        return alias.caseInsensitiveCompare(aliasID) == .orderedSame
                            || (name.caseInsensitiveCompare(aliasID) == .orderedSame && !alias.isEmpty && alias != name)
                    }
                    if models.count != before { removed = true }
                    providers[i]["models"] = models
                }
                root[section] = providers
            }

            if var payload = root["payload"] as? [String: Any],
               var overrides = payload["override"] as? [[String: Any]]
            {
                overrides.removeAll { rule in
                    guard let models = rule["models"] as? [[String: Any]] else { return false }
                    return models.contains {
                        ($0["name"] as? String)?.caseInsensitiveCompare(aliasID) == .orderedSame
                    }
                }
                payload["override"] = overrides
                root["payload"] = payload
            }
        }

        guard removed else { throw AppError("别名 \(aliasID) 不存在") }
        try await client.putConfigYAML(updated)
        return try parseAliases(from: updated)
    }

    // MARK: - Parse

    private static func parseAliases(from yaml: String) throws -> [ThinkingAliasEntry] {
        guard let root = try Yams.load(yaml: yaml) as? [String: Any] else {
            return []
        }
        var entries: [ThinkingAliasEntry] = []

        if let oauth = root["oauth-model-alias"] as? [String: Any],
           let codex = oauth["codex"] as? [[String: Any]]
        {
            for item in codex {
                let fork = (item["fork"] as? Bool) ?? false
                guard fork else { continue }
                let source = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let alias = (item["alias"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !source.isEmpty, !alias.isEmpty else { continue }
                entries.append(ThinkingAliasEntry(
                    sourceModel: source,
                    alias: alias,
                    effort: findEffort(in: root, alias: alias, protocolName: "codex"),
                    provider: "Codex OAuth",
                    kind: "codex-oauth"
                ))
            }
        }

        // Config model aliases (name + different alias)
        for (section, providerLabel, kind, protocolName) in [
            ("codex-api-key", "Codex API", "codex-api", "codex"),
            ("openai-compatibility", "OpenAI 兼容", "openai-compatible", "openai"),
        ] as [(String, String, String, String)] {
            guard let providers = root[section] as? [[String: Any]] else { continue }
            for provider in providers {
                let pname = (provider["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? providerLabel
                guard let models = provider["models"] as? [[String: Any]] else { continue }
                for model in models {
                    let name = (model["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let alias = (model["alias"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? name
                    guard !name.isEmpty, !alias.isEmpty, name != alias else { continue }
                    let effort = findEffort(in: root, alias: alias, protocolName: protocolName)
                        ?? (model["levels"] as? [String])?.first
                    entries.append(ThinkingAliasEntry(
                        sourceModel: name,
                        alias: alias,
                        effort: effort,
                        provider: pname,
                        kind: kind
                    ))
                }
            }
        }

        return entries.sorted {
            if $0.provider != $1.provider { return $0.provider < $1.provider }
            return $0.alias < $1.alias
        }
    }

    private static func findEffort(in root: [String: Any], alias: String, protocolName: String) -> String? {
        guard let payload = root["payload"] as? [String: Any],
              let overrides = payload["override"] as? [[String: Any]]
        else { return nil }

        for rule in overrides {
            guard let models = rule["models"] as? [[String: Any]] else { continue }
            let matches = models.contains {
                ($0["name"] as? String)?.caseInsensitiveCompare(alias) == .orderedSame
            }
            guard matches else { continue }
            let params = rule["params"] as? [String: Any] ?? [:]
            if protocolName == "openai" {
                if let v = params["reasoning_effort"] as? String { return v }
            }
            if let v = params["reasoning.effort"] as? String { return v }
            if let v = params["reasoning_effort"] as? String { return v }
        }
        return nil
    }

    private static func mutateYAML(_ yaml: String, mutate: (inout [String: Any]) throws -> Void) throws -> String {
        var root: [String: Any]
        if yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            root = [:]
        } else if let parsed = try Yams.load(yaml: yaml) as? [String: Any] {
            root = parsed
        } else {
            throw AppError("解析内核 config.yaml 失败")
        }
        try mutate(&root)
        return try Yams.dump(object: root, width: -1, sortKeys: false)
    }
}
