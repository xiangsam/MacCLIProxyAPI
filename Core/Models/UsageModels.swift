import Foundation

struct UsageCollectorStatus: Equatable, Sendable {
    var state: String // waiting-core | collecting | error
    var message: String
    var lastCollectedAt: Date?
    var totalRecords: Int

    static let waiting = UsageCollectorStatus(
        state: "waiting-core",
        message: "等待内核启动",
        lastCollectedAt: nil,
        totalRecords: 0
    )
}

struct UsageTokenStats: Equatable, Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var reasoningTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var totalTokens: Int = 0
}

struct UsageRecord: Identifiable, Equatable, Sendable {
    var id: String
    var timestamp: String
    var latencyMs: Int
    var ttftMs: Int?
    var source: String
    var failed: Bool
    var provider: String
    var model: String
    var alias: String
    var reasoningEffort: String
    var endpoint: String
    var authType: String
    var apiKeyHash: String
    var apiKeyDisplay: String
    var apiKeyRemark: String
    var requestId: String
    var tokens: UsageTokenStats

    /// Short label for chips / filters.
    var providerDisplayName: String {
        UsageProviderLabel.display(
            provider,
            authType: authType,
            source: source,
            nativeResponsesOwners: ProviderSecretStore.nativeResponsesProviderNames()
        )
    }

    /// `source` as it is safe to render.
    ///
    /// Under api-key auth CPA reports the upstream credential itself, so showing it verbatim puts a
    /// live key on screen — and in any screenshot of this page. OAuth rows carry an account
    /// identifier instead, which is not a secret and is what makes the row useful, so it stays.
    var sourceDisplay: String {
        UsageProviderLabel.maskSourceIfCredential(source, authType: authType)
    }

    /// Cache hit rate for this event (0…100).
    var cacheHitRatePercent: Double {
        UsageProviderLabel.cacheHitPercent(
            cacheRead: tokens.cacheReadTokens,
            input: tokens.inputTokens
        )
    }
}

struct UsageTimelinePoint: Identifiable, Equatable, Sendable {
    var id: String { hour }
    var hour: String
    var requests: Int
    var success: Int
    var failure: Int
    var tokens: Int
}

struct UsageOverview: Equatable, Sendable {
    var totalRequests: Int = 0
    var successCount: Int = 0
    var failureCount: Int = 0
    var successRate: Double = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var reasoningTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var totalTokens: Int = 0
    var rpm: Double = 0
    var tpm: Double = 0
    var tps: Double = 0
    var averageLatencyMs: Double = 0
    /// 0…100
    var cacheHitRate: Double = 0
    var estimatedCost: Double = 0
    var pricedRequests: Int = 0
    var timeline: [UsageTimelinePoint] = []
    /// Top providers in the same filter window (for overview breakdown).
    var providers: [UsageCategory] = []
}

struct UsageCategory: Identifiable, Equatable, Sendable {
    /// `key` alone is not unique for providers: a `codex-api-key` credential and a Codex
    /// subscription are both stored as `codex` and only differ by label, so identity has to
    /// include it.
    var id: String { "\(key)|\(label)" }
    var key: String
    var label: String
    var requests: Int
    var failures: Int
    var tokens: Int
    var inputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0

    /// 0…100
    var cacheHitRate: Double {
        UsageProviderLabel.cacheHitPercent(cacheRead: cacheReadTokens, input: inputTokens)
    }

    var successRate: Double {
        guard requests > 0 else { return 0 }
        return Double(requests - failures) * 100.0 / Double(requests)
    }
}

struct UsageAnalysis: Equatable, Sendable {
    var models: [UsageCategory] = []
    var providers: [UsageCategory] = []
    var sources: [UsageCategory] = []
    var apiKeys: [UsageCategory] = []
}

struct UsageEventPage: Equatable, Sendable {
    var items: [UsageRecord] = []
    var total: Int = 0
    var page: Int = 1
    var pageSize: Int = 50
    var totalPages: Int = 1
}

struct ModelPrice: Equatable, Sendable, Identifiable {
    var id: String { model }
    var model: String
    var promptPer1M: Double
    var completionPer1M: Double
    var cacheReadPer1M: Double
    var cacheCreationPer1M: Double
    var source: String
}

struct UsagePriceRow: Identifiable, Equatable, Sendable {
    var id: String { "\(provider)|\(providerLabel)|\(model)" }
    var provider: String
    /// Attributed label: the raw `provider` cannot tell a `codex-api-key` credential from a
    /// Codex subscription.
    var providerLabel: String = ""
    var model: String
    var requests: Int
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var totalTokens: Int
    var estimatedCost: Double
    var price: ModelPrice?

    var providerDisplayName: String {
        providerLabel.isEmpty ? UsageProviderLabel.display(provider) : providerLabel
    }

    var cacheHitRate: Double {
        UsageProviderLabel.cacheHitPercent(cacheRead: cacheReadTokens, input: inputTokens)
    }
}

struct UsagePricing: Equatable, Sendable {
    var rows: [UsagePriceRow] = []
    var totalCost: Double = 0
    var totalRequests: Int = 0
    var pricedRequests: Int = 0
    var savedPrices: Int = 0
}

struct UsageQuery: Equatable, Sendable {
    var start: Date?
    var end: Date?
    var model: String?
    var provider: String?
    var source: String?
    var page: Int = 1
    var pageSize: Int = 50
}

enum UsageRange: String, CaseIterable, Identifiable, Sendable {
    case fourHours = "4h"
    case twentyFourHours = "24h"
    case today
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fourHours: return "近 4 小时"
        case .twentyFourHours: return "近 24 小时"
        case .today: return "今天"
        case .sevenDays: return "近 7 天"
        case .thirtyDays: return "近 30 天"
        case .all: return "全部"
        }
    }

    func makeQuery(now: Date = Date(), provider: String? = nil) -> UsageQuery {
        let calendar = Calendar.current
        var query: UsageQuery
        switch self {
        case .fourHours:
            query = UsageQuery(start: now.addingTimeInterval(-4 * 3600), end: now)
        case .twentyFourHours:
            query = UsageQuery(start: now.addingTimeInterval(-24 * 3600), end: now)
        case .today:
            let start = calendar.startOfDay(for: now)
            query = UsageQuery(start: start, end: now)
        case .sevenDays:
            query = UsageQuery(start: now.addingTimeInterval(-7 * 24 * 3600), end: now)
        case .thirtyDays:
            query = UsageQuery(start: now.addingTimeInterval(-30 * 24 * 3600), end: now)
        case .all:
            query = UsageQuery()
        }
        if let provider, !provider.isEmpty {
            query.provider = provider
        }
        return query
    }
}

// MARK: - Display helpers

enum UsageProviderLabel {
    /// Human-friendly provider label for UI chips / cards.
    ///
    /// `authType` disambiguates the `codex` provider, which covers two different upstreams: the
    /// OAuth subscription and any `codex-api-key` credential. `nativeResponsesOwners` maps a
    /// `codex-api-key` credential's api-key to its own provider name (see
    /// `ProviderSecretStore.nativeResponsesProviderNames`), so that provider's usage groups under
    /// its own name instead of the generic "Codex API Key" bucket.
    static func display(
        _ raw: String,
        authType: String = "",
        source: String = "",
        nativeResponsesOwners: [String: String] = [:]
    ) -> String {
        let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return "未知" }
        let lower = p.lowercased()
        if lower == "codex" || lower == "openai" {
            if isAPIKeyAuth(authType) {
                let credential = source.trimmingCharacters(in: .whitespacesAndNewlines)
                if !credential.isEmpty, let owner = nativeResponsesOwners[credential], !owner.isEmpty {
                    return owner
                }
                return "Codex API Key"
            }
            if authType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "oauth" {
                return "Codex 订阅"
            }
        }
        // Every branch below title-cases its result (matching `ProviderKind
        // .hostDerivedDisplayName`'s convention): CPA lowercases the provider name it slugs
        // into this raw `provider` column, so a vendor's `openai-compatibility` leg and its
        // `codex-api-key` leg (attributed by host, see `nativeResponsesOwners` above) would
        // otherwise produce two case-only-different labels for what is the same provider to the
        // user -- distinct under byte comparison, but the same under the `COLLATE NOCASE` used to
        // filter by label, splitting usage from one provider across two picker entries.
        if lower.hasPrefix("openai-compatible-") {
            let rest = String(p.dropFirst("openai-compatible-".count))
            return rest.isEmpty ? "OpenAI 兼容" : rest.prefix(1).uppercased() + rest.dropFirst()
        }
        if lower.hasPrefix("openai-compatibility:") {
            // auth id style: openai-compatibility:<name>:hash
            let parts = p.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count >= 2, !parts[1].isEmpty {
                return parts[1].prefix(1).uppercased() + parts[1].dropFirst()
            }
        }
        switch lower {
        case "openai", "codex": return "Codex / OpenAI"
        case "xai", "grok": return "xAI / Grok"
        case "claude", "anthropic": return "Claude"
        case "gemini", "google": return "Gemini"
        case "antigravity": return "Antigravity"
        default: return p.prefix(1).uppercased() + p.dropFirst()
        }
    }

    static func isAPIKeyAuth(_ authType: String) -> Bool {
        switch authType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "apikey", "api-key", "api_key": return true
        default: return false
        }
    }

    /// Mask `source` when it is the upstream credential rather than an account name.
    ///
    /// Enough of the value survives to tell two keys apart at a glance, which is all the events
    /// list needs it for.
    static func maskSourceIfCredential(_ source: String, authType: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAPIKeyAuth(authType), !trimmed.isEmpty else { return trimmed }
        guard trimmed.count > 12 else {
            return String(repeating: "•", count: min(trimmed.count, 8))
        }
        return String(trimmed.prefix(6)) + "…" + String(trimmed.suffix(4))
    }

    /// Cache hit percentage 0…100 (cache_read / input).
    static func cacheHitPercent(cacheRead: Int, input: Int) -> Double {
        guard input > 0, cacheRead > 0 else { return 0 }
        return min(100.0, Double(cacheRead) * 100.0 / Double(input))
    }
}
