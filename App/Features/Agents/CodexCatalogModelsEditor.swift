import SwiftUI

/// Codex multi-model mapping: one default (`config.toml model=`) + catalog list (`model_catalog_json`).
/// Per-model context window and supported thinking levels are editable; live
/// `model_reasoning_effort` is still chosen inside Codex itself.
struct CodexCatalogModelsEditor: View {
    @Binding var defaultModel: String
    @Binding var catalogModels: [String]
    @Binding var modelOverrides: [String: AgentModelOverride]
    var fetchedCatalog: [AgentModelCatalogService.Model]
    @State private var customID = ""
    @State private var expandedID: String?

    /// Keep catalog add order stable; marking default must not move the row.
    private var orderedIDs: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in catalogModels {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        let main = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !main.isEmpty, seen.insert(main).inserted {
            out.append(main)
        }
        return out
    }

    var body: some View {
        let resolutions = AgentModelCatalogService.routingResolutions(from: AppPaths.coreConfigURL)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("默认模型")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    // Bare string arguments turn into external labels inside a Form; `prompt`
                    // keeps the hint where it belongs.
                    TextField("", text: defaultModelBinding, prompt: Text("写入 config.toml · model"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    if !fetchedCatalog.isEmpty {
                        Menu {
                            Button("不指定") { defaultModel = "" }
                            Divider()
                            ForEach(AgentModelCatalogService.groups(fetchedCatalog)) { group in
                                Section(group.title) {
                                    ForEach(group.models, id: \.identity) { model in
                                        Button(AgentModelCatalogService.menuRowLabel(
                                            modelID: model.id, resolutions: resolutions
                                        )) { setDefault(model.id) }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 36)
                    }
                }
                Text("Catalog 供 Codex /model 切换。点模型行展开，可改上下文与思考档位。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Catalog")
                    .font(.subheadline.weight(.semibold))
                Text("\(orderedIDs.count)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Spacer()
                if !fetchedCatalog.isEmpty {
                    Button("添加全部已获取") { addAllFetched() }
                        .font(.caption)
                }
            }

            if orderedIDs.isEmpty {
                Text("尚未添加模型。从列表勾选，或手动输入后添加。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(orderedIDs, id: \.self) { id in
                        modelCard(id, resolutions: resolutions)
                    }
                }
            }

            HStack(spacing: 8) {
                if !fetchedCatalog.isEmpty {
                    Menu {
                        ForEach(AgentModelCatalogService.groups(fetchedCatalog)) { group in
                            Section(group.title) {
                                ForEach(group.models, id: \.identity) { model in
                                    Button {
                                        add(model.id)
                                    } label: {
                                        Label(
                                            AgentModelCatalogService.menuRowLabel(
                                                modelID: model.id, resolutions: resolutions
                                            ),
                                            systemImage: contains(model.id) ? "checkmark" : "plus"
                                        )
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("从列表添加", systemImage: "plus")
                    }
                }
                TextField("", text: $customID, prompt: Text("手动添加模型 id"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                Button("添加") {
                    add(customID)
                    customID = ""
                }
                .disabled(customID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private func modelCard(
        _ id: String,
        resolutions: [String: AgentModelCatalogService.RoutingResolution]
    ) -> some View {
        let isDefault = id == defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = expandedID == id
        let protocolInfo = AgentModelCatalogService.protocolLabel(modelID: id, resolutions: resolutions)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedID = expanded ? nil : id
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Image(systemName: isDefault ? "star.fill" : "cube.fill")
                        .font(.caption)
                        .foregroundStyle(isDefault ? Color.orange : Color.secondary.opacity(0.8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(id)
                            .font(.callout.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(summaryLabel(for: id, protocolShort: protocolInfo?.short))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let detail = protocolInfo?.detail {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    if isDefault {
                        Text("默认")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                    } else {
                        Button("设为默认") {
                            setDefault(id)
                        }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                    }
                    Button(role: .destructive) {
                        remove(id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                    .buttonStyle(.borderless)
                    .help("从 catalog 移除")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                AgentModelCapabilityEditor(
                    agent: .codex,
                    modelID: id,
                    modelOverrides: $modelOverrides
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isDefault ? Color.orange.opacity(0.35) : Color.primary.opacity(0.06),
                    lineWidth: 1
                )
        )
    }

    private func summaryLabel(for id: String, protocolShort: String?) -> String {
        let ctx = AgentReasoningEffort.resolveContextWindow(
            modelID: id,
            override: modelOverrides[id]?.contextWindow
                ?? modelOverrides[AgentReasoningEffort.normalizeModelID(id)]?.contextWindow,
            fallback: 128_000
        )
        let levels = AgentReasoningEffort.options(
            agent: .codex,
            modelID: id,
            override: modelOverrides[id]?.reasoningLevels
                ?? modelOverrides[AgentReasoningEffort.normalizeModelID(id)]?.reasoningLevels
        )
        let levelPart = levels.isEmpty ? "无思考档" : "\(levels.count) 档 · \(levels.joined(separator: " / "))"
        let base = "\(ContextWindowFormat.display(ctx)) · \(levelPart)"
        guard let protocolShort else { return base }
        return "\(base) · \(protocolShort)"
    }

    private var defaultModelBinding: Binding<String> {
        Binding(
            get: { defaultModel },
            set: { newValue in
                defaultModel = newValue
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { add(trimmed) }
            }
        )
    }

    private func contains(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return orderedIDs.contains(trimmed)
    }

    private func add(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = catalogModels
        if !next.contains(trimmed) {
            next.append(trimmed)
        }
        catalogModels = next
        if defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaultModel = trimmed
        }
    }

    private func addAllFetched() {
        for model in fetchedCatalog {
            add(model.id)
        }
        if defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let first = fetchedCatalog.first
        {
            defaultModel = first.id
        }
    }

    private func setDefault(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        defaultModel = trimmed
        add(trimmed)
    }

    private func remove(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        catalogModels.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }
        modelOverrides.removeValue(forKey: trimmed)
        modelOverrides.removeValue(forKey: AgentReasoningEffort.normalizeModelID(trimmed))
        if expandedID == trimmed { expandedID = nil }
        if defaultModel.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
            defaultModel = catalogModels.first ?? ""
        }
    }
}
