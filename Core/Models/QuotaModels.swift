import Foundation

enum QuotaProvider: String, Sendable {
    case claude
    case codex
    case kimi
    case xai
    case antigravity
    case deepseek

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .kimi: return "Kimi"
        case .xai: return "xAI"
        case .antigravity: return "Antigravity"
        case .deepseek: return "DeepSeek"
        }
    }
}

enum QuotaLoadStatus: String, Sendable {
    case idle
    case loading
    case success
    case error
}

struct QuotaMetric: Identifiable, Equatable, Sendable {
    var id: String { "\(label)::\(reset ?? "")::\(detail ?? "")" }
    var label: String
    var remainingPercent: Double?
    var reset: String?
    var detail: String?
}

struct AccountQuotaSummary: Identifiable, Equatable, Sendable {
    var id: String
    var fileName: String
    var provider: QuotaProvider
    var displayName: String
    var status: QuotaLoadStatus
    var plan: String?
    var metrics: [QuotaMetric]
    var error: String?
    var fetchedAt: Date?
    var resetCredits: Int?

    /// Primary remaining percent for compact UI (lowest among metrics, or sole metric).
    var primaryRemainingPercent: Double? {
        let values = metrics.compactMap(\.remainingPercent)
        return values.min()
    }

    /// Text for compact UI when a percent is not meaningful (e.g. prepaid balance).
    var primaryDisplayText: String? {
        metrics.first { $0.remainingPercent == nil && !($0.detail ?? "").isEmpty }?.detail
    }

    var isLow: Bool {
        guard let p = primaryRemainingPercent else { return false }
        return p < 20
    }
}

struct QuotaSnapshot: Equatable, Sendable {
    var accounts: [AccountQuotaSummary] = []
    var isRefreshing: Bool = false
    var lastError: String?
    var lastRefreshedAt: Date?

    var overallRemainingPercent: Double? {
        let values = accounts.compactMap(\.primaryRemainingPercent)
        return values.min()
    }

    func account(id: String?) -> AccountQuotaSummary? {
        guard let id else { return accounts.first }
        return accounts.first(where: { $0.id == id }) ?? accounts.first
    }

    func remainingPercent(forAccountID id: String?) -> Double? {
        account(id: id)?.primaryRemainingPercent ?? overallRemainingPercent
    }

    var summaryLine: String {
        if !accounts.isEmpty, let overall = overallRemainingPercent {
            return String(format: "额度 %.0f%%", overall)
        }
        if isRefreshing { return "额度刷新中" }
        if lastError != nil { return "额度失败" }
        return "额度 —"
    }
}
