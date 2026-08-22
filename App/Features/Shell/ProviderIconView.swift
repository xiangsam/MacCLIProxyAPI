import AppKit
import SwiftUI

/// Brand icons for known AI providers (Asset Catalog + SF Symbol fallback).
struct ProviderIconView: View {
    let provider: String
    var size: CGFloat = 28

    var body: some View {
        let identity = ProviderBrand.resolve(provider)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(identity.tint.opacity(0.14))
                .frame(width: size + 10, height: size + 10)
            if let asset = identity.assetName, NSImage(named: asset) != nil {
                // Gemini sparkle reads small in-tile; give it a bit more optical weight.
                let scale: CGFloat = {
                    if case .gemini = identity { return 0.82 }
                    return 0.72
                }()
                Image(asset)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * scale, height: size * scale)
            } else {
                Image(systemName: identity.systemImage)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(identity.tint)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .accessibilityLabel(identity.label)
    }
}

enum ProviderBrand {
    case claude, codex, openai, gemini, grok, kimi, deepseek, antigravity, unknown(String)

    var assetName: String? {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .openai: return "openai"
        case .gemini: return "gemini"
        case .grok: return "grok"
        case .kimi: return "kimi"
        case .deepseek: return "deepseek"
        case .antigravity: return "antigravity"
        case .unknown: return nil
        }
    }

    var systemImage: String {
        switch self {
        case .claude: return "brain.head.profile"
        case .codex, .openai: return "terminal.fill"
        case .gemini, .antigravity: return "sparkle"
        case .grok: return "sparkles"
        case .kimi: return "moon.stars.fill"
        case .deepseek: return "waveform"
        case .unknown: return "key.fill"
        }
    }

    var tint: Color {
        switch self {
        case .claude: return .orange
        case .codex, .openai: return Color(red: 0.2, green: 0.75, blue: 0.45)
        case .gemini: return .blue
        case .grok: return .purple
        case .kimi: return .indigo
        case .deepseek: return .cyan
        case .antigravity: return Color(red: 0.35, green: 0.55, blue: 1.0)
        case .unknown: return .secondary
        }
    }

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        case .grok: return "xAI / Grok"
        case .kimi: return "Kimi"
        case .deepseek: return "DeepSeek"
        case .antigravity: return "Antigravity"
        case .unknown(let raw): return raw
        }
    }

    static func resolve(_ raw: String) -> ProviderBrand {
        let p = raw.lowercased()
        if p.contains("claude") || p.contains("anthropic") { return .claude }
        if p.contains("codex") { return .codex }
        if p.contains("openai") || p.contains("gpt") { return .openai }
        if p.contains("gemini") || p.contains("google") { return .gemini }
        if p.contains("xai") || p.contains("grok") { return .grok }
        if p.contains("kimi") || p.contains("moonshot") { return .kimi }
        if p.contains("deepseek") { return .deepseek }
        if p.contains("antigravity") || p.contains("anti-gravity") { return .antigravity }
        return .unknown(raw.isEmpty ? "unknown" : raw)
    }
}

