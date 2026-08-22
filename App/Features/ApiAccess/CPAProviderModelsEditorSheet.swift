import SwiftUI

/// Edit CPA openai-compatibility model rows: max-context-length + thinking.levels.
struct CPAProviderModelsEditorSheet: View {
    @Environment(AppState.self) private var appState
    let item: ProviderConfig
    let section: ProviderKind
    var onSaved: () -> Void
    var onClose: () -> Void

    @State private var rows: [DraftRow] = []
    @State private var expandedID: String?
    @State private var busy = false
    @State private var errorMessage: String?

    private struct DraftRow: Identifiable, Equatable {
        var id: String
        var name: String
        var alias: String
        var displayName: String
        var maxContextLength: Int?
        var thinkingLevels: [String]
        var raw: [String: Any]

        static func == (lhs: DraftRow, rhs: DraftRow) -> Bool {
            lhs.id == rhs.id
                && lhs.name == rhs.name
                && lhs.alias == rhs.alias
                && lhs.displayName == rhs.displayName
                && lhs.maxContextLength == rhs.maxContextLength
                && lhs.thinkingLevels == rhs.thinkingLevels
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(item.name) · 模型列表")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("关闭") { onClose() }
                    .disabled(busy)
                Button("保存到 CPA") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
            }
            Text("客户端 model 用「别名」；上游发「name」。可改上下文长度与思考档位（写入 \(section.managementPath).models）。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            List {
                ForEach($rows) { $row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Button {
                                expandedID = expandedID == row.id ? nil : row.id
                            } label: {
                                Image(systemName: expandedID == row.id ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.displayName.isEmpty ? row.alias : row.displayName)
                                    .font(.subheadline.weight(.semibold))
                                Text("别名 \(row.alias)  →  上游 \(row.name)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Text(summary(row))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        if expandedID == row.id {
                            rowEditor($row)
                                .padding(.leading, 18)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(minHeight: 360)
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 480)
        .onAppear(perform: bootstrap)
    }

    @ViewBuilder
    private func rowEditor(_ row: Binding<DraftRow>) -> some View {
        let modelKey = row.wrappedValue.alias.isEmpty ? row.wrappedValue.name : row.wrappedValue.alias
        let auto = AgentReasoningEffort.resolveContextWindow(
            modelID: modelKey,
            override: nil,
            fallback: 128_000
        )
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("上下文")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField(
                    ContextWindowFormat.display(auto),
                    text: Binding(
                        get: {
                            if let value = row.wrappedValue.maxContextLength, value > 0 {
                                return ContextWindowFormat.display(value)
                            }
                            return ""
                        },
                        set: { raw in
                            if let value = ContextWindowFormat.parse(raw) {
                                row.wrappedValue.maxContextLength = value
                            } else if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                row.wrappedValue.maxContextLength = nil
                            }
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
                .frame(maxWidth: 120)
                Text("1M / 272K")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text("思考档位")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(AgentReasoningEffort.selectableTags, id: \.self) { tag in
                    Toggle(tag, isOn: Binding(
                        get: { row.wrappedValue.thinkingLevels.contains(tag) },
                        set: { enabled in
                            var levels = Set(row.wrappedValue.thinkingLevels)
                            if enabled { levels.insert(tag) } else { levels.remove(tag) }
                            row.wrappedValue.thinkingLevels = AgentReasoningEffort.sanitizeLevels(Array(levels))
                        }
                    ))
                    .toggleStyle(.button)
                    .font(.caption2)
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                }
                Spacer(minLength: 0)
            }
            Button("按模型默认填充") {
                let levels = AgentReasoningEffort.options(agent: .codex, modelID: modelKey)
                row.wrappedValue.thinkingLevels = levels
                row.wrappedValue.maxContextLength = AgentReasoningEffort.knownContextWindow(for: modelKey)
            }
            .font(.caption2)

            Divider().opacity(0.4)
            Button(role: .destructive) {
                let removedID = row.wrappedValue.id
                rows.removeAll { $0.id == removedID }
                if expandedID == removedID { expandedID = nil }
            } label: {
                Label("删除该模型", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func summary(_ row: DraftRow) -> String {
        let modelKey = row.alias.isEmpty ? row.name : row.alias
        let ctxTokens = row.maxContextLength
            ?? AgentReasoningEffort.knownContextWindow(for: modelKey)
        let ctx = ctxTokens.map(ContextWindowFormat.display) ?? "未设"
        let levels = row.thinkingLevels.isEmpty ? "无档位" : "\(row.thinkingLevels.count) 档"
        return "\(ctx) · \(levels)"
    }

    private func bootstrap() {
        let rawModels = (item.raw["models"] as? [[String: Any]]) ?? []
        if rawModels.isEmpty {
            rows = item.models.map { model in
                DraftRow(
                    id: model.id,
                    name: model.name,
                    alias: model.alias,
                    displayName: model.displayName,
                    maxContextLength: model.maxContextLength,
                    thinkingLevels: model.thinkingLevels,
                    raw: [
                        "name": model.name,
                        "alias": model.alias,
                        "display-name": model.displayName,
                    ]
                )
            }
        } else {
            rows = rawModels.enumerated().compactMap { index, raw in
                let entry = ProviderModelEntry(raw: raw)
                guard !entry.name.isEmpty || !entry.alias.isEmpty else { return nil }
                return DraftRow(
                    id: entry.id.isEmpty ? "row-\(index)" : entry.id,
                    name: entry.name,
                    alias: entry.alias,
                    displayName: entry.displayName,
                    maxContextLength: entry.maxContextLength,
                    thinkingLevels: entry.thinkingLevels,
                    raw: raw
                )
            }
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        errorMessage = nil
        do {
            let client = appState.managementClient()
            let path = section.managementPath
            let storage = section
            let existingJSON = try await client.getJSON(path: path)
            var list = rawRows(existingJSON, section: storage)
            guard let idx = list.firstIndex(where: { matches($0, item) })
                    ?? (item.listIndex < list.count ? item.listIndex : nil)
            else {
                throw AppError("找不到 Provider，请刷新后重试")
            }
            var entry = list[idx]
            entry["models"] = rows.map { row -> [String: Any] in
                var raw = row.raw
                raw["name"] = row.name
                raw["alias"] = row.alias.isEmpty ? row.name : row.alias
                if !row.displayName.isEmpty {
                    raw["display-name"] = row.displayName
                }
                if let ctx = row.maxContextLength, ctx > 0 {
                    raw["max-context-length"] = ctx
                } else {
                    raw.removeValue(forKey: "max-context-length")
                }
                if row.thinkingLevels.isEmpty {
                    raw.removeValue(forKey: "thinking")
                } else {
                    raw["thinking"] = ["levels": row.thinkingLevels]
                }
                return raw
            }
            var key = item.apiKey
            if key.isEmpty {
                key = ProviderSecretStore.get(
                    section: storage,
                    name: item.name,
                    authIndex: item.authIndex,
                    baseURL: item.baseURL
                ) ?? ProviderConfig.extractAPIKey(from: entry).key
            }
            if !key.isEmpty {
                ProviderConfig.applyAPIKey(to: &entry, apiKey: key)
            }
            list[idx] = entry
            // This is a whole-list PUT: without re-injection the sibling providers we are not
            // editing would be written back without their keys.
            list = ProviderSecretStore.reinject(into: list, section: storage)
            _ = try await client.sendJSON(method: "PUT", path: path, body: list)
            appState.flash("已更新 \(rows.count) 个模型的上下文/思考档位")
            onSaved()
        } catch {
            errorMessage = error.localizedDescription
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func matches(_ raw: [String: Any], _ item: ProviderConfig) -> Bool {
        if let auth = item.authIndex, !auth.isEmpty {
            let rawAuth = (raw["auth-index"] as? String) ?? (raw["authIndex"] as? String)
            if rawAuth == auth { return true }
        }
        let name = (raw["name"] as? String) ?? ""
        let base = (raw["base-url"] as? String) ?? (raw["baseUrl"] as? String) ?? ""
        return name == item.name && base == item.baseURL
    }

    private func rawRows(_ json: Any, section: ProviderKind) -> [[String: Any]] {
        if let list = json as? [[String: Any]] { return list }
        if let dict = json as? [String: Any] {
            if let list = dict[section.rawValue] as? [[String: Any]] { return list }
            if let list = dict["items"] as? [[String: Any]] { return list }
            if let list = dict["data"] as? [[String: Any]] { return list }
        }
        return []
    }
}
