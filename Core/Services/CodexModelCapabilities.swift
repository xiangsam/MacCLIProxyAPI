import Foundation

/// Image-input capability shared by Codex catalog generation.
///
/// Ported verbatim from cc-switch's `model_capabilities.rs`
/// (github.com/farion1231/cc-switch) so this app's Codex model catalog stays in
/// sync with cc-switch's capability data. Refresh via
/// `scripts/sync-cc-switch-codex-catalog.sh`.
///
/// `.unknown` is intentionally distinct from `.supported`: callers may choose
/// different execution policies without duplicating the model-name registry.
/// The Codex catalog treats unknown models as image-capable (fail open).
enum ImageInputCapability: Equatable {
    case supported
    case unsupported
    case unknown
}

enum CodexModelCapabilities {
    /// Resolve image-input capability from an explicit declaration first, then the
    /// confirmed text-only model registry when the caller enables registry lookup.
    static func resolveImageInputCapability(
        model: String,
        declaredSupport: Bool?,
        useConfirmedRegistry: Bool
    ) -> ImageInputCapability {
        switch declaredSupport {
        case .some(true):
            return .supported
        case .some(false):
            return .unsupported
        case .none:
            if useConfirmedRegistry, isConfirmedTextOnlyModel(model) {
                return .unsupported
            }
            return .unknown
        }
    }

    /// Convert a catalog row's explicit modality list into the shared capability
    /// representation, falling back to the text-only registry when omitted.
    static func imageInputCapability(model: String, modalities: [String]?) -> ImageInputCapability {
        let declaredSupport = modalities.map { items in
            items.contains {
                $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("image") == .orderedSame
            }
        }
        return resolveImageInputCapability(
            model: model,
            declaredSupport: declaredSupport,
            useConfirmedRegistry: true
        )
    }

    /// Models this app is willing to advertise to Codex clients as text-only.
    ///
    /// Deliberately exact (not prefix) matching and fail-open: a new suffix is
    /// not inherited automatically, so an unconfirmed `-vision`/`-vl` variant
    /// stays image-capable until its capability is separately confirmed here —
    /// this keeps a future vision variant from being blocked before a request
    /// can even reach the proxy.
    static func isConfirmedTextOnlyModel(_ model: String) -> Bool {
        let normalized = normalizeModelID(model)
        let tail = normalized.split(separator: "/").last.map(String.init) ?? normalized
        return confirmedTails.contains(tail)
    }

    /// Verbatim copy of cc-switch's `CONFIRMED_TAILS`.
    private static let confirmedTails: Set<String> = [
        "ark-code-latest",
        "deepseek-chat",
        "deepseek-reasoner",
        "deepseek-v4-flash",
        "deepseek-v4-pro",
        "glm-5.1",
        // Exact rather than prefix matching: GLM visual models use a `v`
        // suffix (for example glm-5.2v), which must remain image-capable.
        "glm-5.2",
        "kat-coder",
        "kat-coder-pro",
        "kat-coder-pro v1",
        "kat-coder-pro v2",
        "kat-coder-pro-v1",
        "kat-coder-pro-v2",
        "ling-2.5-1t",
        "longcat-2.0",
        "longcat-flash-chat",
        "minimax-m2.7",
        "minimax-m2.7-highspeed",
        "mimo-v2.5-pro",
        "qwen3-coder-480b",
        "qwen3-coder-480b-a35b-instruct",
        "qwen3-coder-flash",
        "qwen3-coder-next",
        "qwen3-coder-plus",
        "step-3.5-flash",
        "step-3.5-flash-2603",
        "us.deepseek.r1-v1",
    ]

    /// Same order of operations as cc-switch's `normalize_model_id`: trim, strip
    /// a leading `models/` namespace, trim again, lowercase, then strip a
    /// trailing `[1m]` context-window marker (cc-switch's `ONE_M_CONTEXT_MARKER`).
    private static func normalizeModelID(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("models/") {
            normalized.removeFirst("models/".count)
        }
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasSuffix("[1m]") {
            normalized.removeLast("[1m]".count)
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized
    }
}
