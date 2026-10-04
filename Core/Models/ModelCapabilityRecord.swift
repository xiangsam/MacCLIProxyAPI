import Foundation

/// Facts from models.dev's canonical model list. Provider-specific controls stay attributable.
struct ModelCapabilityRecord: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var lab: String
    var description: String?
    var reasoning: Bool?
    /// Union for discovery only; use providerVariants before issuing a request.
    var reasoningLevels: [String]?
    var reasoningLevelsScope: String = "provider-dependent"
    var inputModalities: [String]?
    var outputModalities: [String]?
    var contextWindow: Int?
    var maxInputTokens: Int?
    var maxOutputTokens: Int?
    var toolCall: Bool?
    var structuredOutput: Bool?
    var sourceUpdatedAt: String?
    var sourceURL: String
    var providerVariants: [ModelCapabilityVariant]

    var reasoningSummary: String {
        guard let reasoning else { return "未提供" }
        guard reasoning else { return "不支持" }
        if let levels = reasoningLevels, !levels.isEmpty { return levels.joined(separator: " / ") }
        let kinds = Set(providerVariants.flatMap { $0.reasoningOptions ?? [] }.map(\.type))
        if kinds.contains("budget_tokens") { return "支持 · 按预算控制" }
        if kinds.contains("toggle") { return "支持 · 开关控制" }
        return "支持 · 未提供等级"
    }
}

struct ModelReasoningOption: Codable, Equatable, Sendable {
    var type: String
    var values: [String?]?
    var min: Int?
    var max: Int?

    var summary: String {
        switch type {
        case "effort": return (values ?? []).map { $0 ?? "null" }.joined(separator: " / ")
        case "toggle": return "思考开关"
        case "budget_tokens":
            return "思考预算 " + (min.map(String.init) ?? "未提供下限") + "…" + (max.map(String.init) ?? "未提供上限")
        default: return type
        }
    }
}

struct ModelCapabilityVariant: Codable, Equatable, Identifiable, Sendable {
    var id: String { providerID + "/" + providerModelID }
    var providerID: String
    var providerName: String
    var providerModelID: String
    var reasoning: Bool?
    /// nil = unknown; [] = source explicitly lists no configurable controls.
    var reasoningOptions: [ModelReasoningOption]?
    var inputModalities: [String]?
    var outputModalities: [String]?
    var contextWindow: Int?
    var maxInputTokens: Int?
    var maxOutputTokens: Int?
}

struct ModelCapabilitySnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var source: String
    var fetchedAt: Date
    var unmappedProviderModelCount: Int
    var models: [ModelCapabilityRecord]
}
