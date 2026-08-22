import SwiftUI

/// Editable context window + supported reasoning levels for one model id.
///
/// Only fields that actually reach a live config are shown. `modelOverrides` is consumed solely by
/// `CodexModelCatalogWriter`; Claude's settings.json has no per-model capability schema at all.
/// Offering those controls anyway would let the user "configure" something that is silently discarded.
struct AgentModelCapabilityEditor: View {
    let agent: AgentKind
    let modelID: String
    @Binding var modelOverrides: [String: AgentModelOverride]

    /// Whether this agent's writer persists a per-model context window.
    static func supportsContextWindow(_ agent: AgentKind) -> Bool {
        switch agent {
        case .codex: return true // catalog JSON `context_window`
        case .claude: return false // 1M is expressed through the model name marker instead
        }
    }

    /// Whether this agent's writer persists a per-model reasoning-level list.
    static func supportsReasoningLevels(_ agent: AgentKind) -> Bool {
        switch agent {
        case .codex: return true // catalog JSON `supported_reasoning_efforts`
        case .claude: return false
        }
    }

    static func hasEditableCapabilities(_ agent: AgentKind) -> Bool {
        supportsContextWindow(agent) || supportsReasoningLevels(agent)
    }

    private var trimmedID: String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var override: AgentModelOverride? {
        guard !trimmedID.isEmpty else { return nil }
        return modelOverrides[trimmedID]
            ?? modelOverrides[AgentReasoningEffort.normalizeModelID(trimmedID)]
    }

    private var autoContext: Int {
        AgentReasoningEffort.resolveContextWindow(
            modelID: trimmedID,
            override: nil,
            fallback: 128_000
        )
    }

    private var matrixLevels: [String] {
        AgentReasoningEffort.options(agent: agent, modelID: trimmedID, override: nil)
    }

    private var selectedLevels: [String] {
        AgentReasoningEffort.options(
            agent: agent,
            modelID: trimmedID,
            override: override?.reasoningLevels
        )
    }

    private var contextText: Binding<String> {
        Binding(
            get: {
                if let value = override?.contextWindow, value > 0 {
                    return ContextWindowFormat.display(value)
                }
                return ""
            },
            set: { raw in
                guard !trimmedID.isEmpty else { return }
                var next = modelOverrides
                var entry = next[trimmedID] ?? AgentModelOverride()
                if let value = ContextWindowFormat.parse(raw) {
                    entry.contextWindow = value
                } else if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    entry.contextWindow = nil
                }
                if entry.isEmpty {
                    next.removeValue(forKey: trimmedID)
                } else {
                    next[trimmedID] = entry
                }
                modelOverrides = next
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if Self.supportsContextWindow(agent) {
                contextSection
            }
            if Self.supportsReasoningLevels(agent) {
                levelsSection
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("上下文长度")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if override?.contextWindow != nil {
                    Button("用自动值") { setContext(nil) }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 8) {
                // Inside a Form a bare string argument becomes an external label, which turned the
                // auto value into a permanent caption sitting next to the real one. `prompt` keeps
                // it a placeholder.
                TextField("", text: contextText, prompt: Text(ContextWindowFormat.display(autoContext)))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.body.monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: 140)
                Text("留空＝自动 \(ContextWindowFormat.display(autoContext)) · 可填 1M / 272K / 数字")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var levelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("可支持思考档位")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if override?.reasoningLevels != nil {
                    Button("恢复默认") { setLevels(nil) }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                }
            }

            if trimmedID.isEmpty {
                Text("先填写模型")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                if matrixLevels.isEmpty && override?.reasoningLevels == nil {
                    Text("该模型默认无思考档位，可手动勾选。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                EffortChipRow(
                    tags: AgentReasoningEffort.selectableTags,
                    selected: Set(selectedLevels),
                    onToggle: toggleLevel
                )
            }
        }
    }

    private func setContext(_ value: Int?) {
        guard !trimmedID.isEmpty else { return }
        var next = modelOverrides
        var entry = next[trimmedID] ?? AgentModelOverride()
        entry.contextWindow = value
        if entry.isEmpty {
            next.removeValue(forKey: trimmedID)
        } else {
            next[trimmedID] = entry
        }
        modelOverrides = next
    }

    private func setLevels(_ levels: [String]?) {
        guard !trimmedID.isEmpty else { return }
        var next = modelOverrides
        var entry = next[trimmedID] ?? AgentModelOverride()
        entry.reasoningLevels = levels.map(AgentReasoningEffort.sanitizeLevels)
        if entry.isEmpty {
            next.removeValue(forKey: trimmedID)
        } else {
            next[trimmedID] = entry
        }
        modelOverrides = next
    }

    private func toggleLevel(_ tag: String) {
        var levels = Set(selectedLevels)
        if levels.contains(tag) {
            levels.remove(tag)
        } else {
            levels.insert(tag)
        }
        let ordered = AgentReasoningEffort.sanitizeLevels(Array(levels))
        if ordered == matrixLevels {
            setLevels(nil)
        } else {
            setLevels(ordered)
        }
    }
}

private struct EffortChipRow: View {
    let tags: [String]
    let selected: Set<String>
    let onToggle: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                let on = selected.contains(tag)
                Button {
                    onToggle(tag)
                } label: {
                    Text(tag)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(on ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    on ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08),
                                    lineWidth: 1
                                )
                        )
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
        }
    }
}
