import SwiftUI

struct ApiAccessPageView: View {
    @Environment(AppState.self) private var appState
    @State private var section: ProviderKind = .openai
    @State private var items: [ProviderConfig] = []
    @State private var busy = false
    @State private var search = ""
    @State private var showEditor = false
    @State private var editorMode: EditorMode = .add
    @State private var editingItem: ProviderConfig?
    @State private var draftName = ""
    @State private var draftBaseURL = ""
    @State private var draftAPIKey = ""
    @State private var draftPriority = 0
    @State private var errorMessage: String?
    @State private var pendingDelete: ProviderConfig?
    @State private var testingProviderID: String?
    @State private var testResults: [String: String] = [:]
    @State private var syncingModelsProviderID: String?
    @State private var showModelListFor: ProviderConfig?

    private enum EditorMode {
        case add
        case edit
    }

    var body: some View {
        ListPageScaffold {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(ProviderKind.allCases) { item in
                        sectionChip(item)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索", text: $search).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

                    Button("刷新") { Task { await reload() } }.disabled(busy)
                    Button {
                        beginAdd()
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } bodyContent: {
            if busy && items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredItems.isEmpty {
                CenteredEmptyState(
                    systemImage: "network",
                    title: "暂无 \(section.title) 配置",
                    message: "添加上游 API 密钥后，可通过本地代理统一调用",
                    actionTitle: "添加 Provider"
                ) {
                    beginAdd()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredItems) { item in
                            providerCard(item)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .navigationTitle("API 接入")
        .sheet(isPresented: $showEditor) {
            editorSheet
                .id(editorSheetIdentity)
                .onAppear {
                    // sheet(isPresented:) can evaluate body before @State from beginEdit
                    // commits; re-sync so priority / name match the card.
                    syncEditorDraftFromEditingItem()
                }
        }
        .confirmDestructive(
            $pendingDelete,
            title: "删除 Provider？",
            confirmLabel: { "删除「\($0.name)」" },
            message: { _ in "此操作会从内核配置中移除该 Provider，且不能自动撤销。" },
            action: { item in Task { await deleteItem(item) } }
        )
        .task { await reload() }
        .sheet(item: $showModelListFor) { item in
            modelListSheet(item)
        }
    }

    private func sectionChip(_ item: ProviderKind) -> some View {
        let selected = section == item
        return Button {
            section = item
            testResults = [:]
            items = []
            Task { await reload() }
        } label: {
            HStack(spacing: 6) {
                ProviderIconView(provider: item.brandKey, size: 14)
                Text(item.title).font(.subheadline.weight(selected ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
            .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var filteredItems: [ProviderConfig] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter {
            "\($0.name) \($0.baseURL)".lowercased().contains(query)
        }
    }

    private var editorSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProviderIconView(provider: section.brandKey, size: 24)
                Text(editorMode == .add ? "添加 \(section.title)" : "编辑 \(section.title)")
                    .font(.title3.weight(.semibold))
            }
            if let help = section.protocolHelpText {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if section.requiresName {
                TextField("名称", text: $draftName)
                    .textFieldStyle(.roundedBorder)
            }

            TextField("Base URL（可选）", text: $draftBaseURL)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                if editorMode == .edit {
                    SecureField(draftAPIKeyPlaceholder, text: $draftAPIKey)
                        .textFieldStyle(.roundedBorder)
                    Text(editorKeyHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    SecureField("API Key（任意格式，不限 sk- 前缀）", text: $draftAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("路由优先级")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 10) {
                    Stepper(value: $draftPriority, in: 0...999) {
                        Text(draftPriority == 0 ? "默认 (0)" : "P\(draftPriority)")
                            .font(.body.monospacedDigit())
                            .frame(minWidth: 88, alignment: .leading)
                    }
                    Text("数字越大，fill-first 越优先；订阅与本地同名模型时靠此指定。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button("取消") { showEditor = false }
                Spacer()
                Button(editorMode == .add ? "保存" : "更新") {
                    Task { await saveEditor() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSaveEditor || busy)
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 380)
    }

    private var editorKeyHint: String {
        "OpenAI 兼容密钥不限 sk- 前缀；编辑时留空表示不修改密钥。"
    }

    private var draftAPIKeyPlaceholder: String {
        if let item = editingItem {
            if !item.apiKey.isEmpty {
                return "留空则保持原密钥（\(maskKey(item.apiKey))）"
            }
            return "请填写 API Key（服务端未返回密钥）"
        }
        return "API Key"
    }

    private var canSaveEditor: Bool {
        if section.requiresName {
            let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                return false
            }
        }
        let key = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if editorMode == .add {
            return !key.isEmpty
        }
        // Edit: allow empty key only when we already have a known key (cached or server).
        if key.isEmpty {
            return !(editingItem?.apiKey ?? "").isEmpty
        }
        return true
    }

    private var editorSheetIdentity: String {
        switch editorMode {
        case .add: return "add-\(section.rawValue)"
        case .edit: return "edit-\(editingItem?.id ?? "unknown")"
        }
    }

    /// Re-apply draft fields from `editingItem` (edit) or section defaults (add).
    private func syncEditorDraftFromEditingItem() {
        switch editorMode {
        case .add:
            break
        case .edit:
            guard let item = editingItem else { return }
            draftName = item.name.hasPrefix("配置 ") ? "" : item.name
            draftBaseURL = item.baseURL
            draftPriority = resolvedPriority(item)
        }
    }

    private func resolvedPriority(_ item: ProviderConfig) -> Int {
        if item.priority > 0 { return item.priority }
        // Fallback if struct field lagged behind raw payload.
        if let raw = item.raw["priority"] {
            if let n = raw as? Int { return max(0, n) }
            if let n = raw as? Int64 { return max(0, Int(n)) }
            if let n = raw as? Double { return max(0, Int(n)) }
            if let n = raw as? NSNumber { return max(0, n.intValue) }
            if let s = raw as? String, let n = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return max(0, n)
            }
        }
        return 0
    }

    private func beginAdd() {
        editorMode = .add
        editingItem = nil
        draftName = ""
        draftBaseURL = ""
        draftAPIKey = ""
        draftPriority = 0
        presentEditor()
    }

    private func beginEdit(_ item: ProviderConfig) {
        editorMode = .edit
        editingItem = item
        draftName = item.name.hasPrefix("配置 ") ? "" : item.name
        draftBaseURL = item.baseURL
        draftAPIKey = "" // never prefill secret into SecureField
        draftPriority = resolvedPriority(item)
        presentEditor()
    }

    private func presentEditor() {
        // Let draft* @State commit before the sheet body is evaluated.
        Task { @MainActor in
            showEditor = true
        }
    }

    /// A card's own vendor identity, not the section's generic brand. `codex-api-key` /
    /// `claude-api-key` / `gemini-api-key` are protocol-shaped passthrough sections any vendor can
    /// use (DeepSeek under "Codex 原生 Responses" included) -- stamping every row in a section with
    /// that section's brand icon falsely implies the section is brand-exclusive.
    private func providerBrandKey(_ item: ProviderConfig) -> String {
        section.requiresName ? item.name : ProviderKind.hostDerivedDisplayName(baseURL: item.baseURL)
    }

    private func providerCard(_ item: ProviderConfig) -> some View {
        GlassCard(padding: 14) {
            HStack(spacing: 12) {
                ProviderIconView(provider: providerBrandKey(item), size: 28)
                    .frame(width: 40, height: 40)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(item.name).font(.headline).lineLimit(1)
                        if item.priority > 0 {
                            Text("P\(item.priority)")
                                .font(.caption2.monospaced().weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    if !item.baseURL.isEmpty {
                        Text(item.baseURL)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !item.apiKey.isEmpty {
                        Text(maskKey(item.apiKey) + (item.apiKeyFromCache ? " · 本地缓存" : ""))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("密钥未返回 · 编辑后可测试")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if section == .openai || section == .codex {
                        HStack(spacing: 6) {
                            Text(item.models.isEmpty
                                 ? "模型列表未同步（点「同步模型」从上游拉取）"
                                 : "已注册 \(item.models.count) 个模型")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(item.models.isEmpty ? Color.orange : Color.secondary)
                            if !item.models.isEmpty {
                                Button("查看") { showModelListFor = item }
                                    .buttonStyle(.plain)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    if let result = testResults[item.id] {
                        Text(result)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(result.hasPrefix("成功") ? Color.green : Color.red)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                Text(item.disabled ? "已禁用" : "启用")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(item.disabled ? Color.secondary : Color.green)

                if section == .openai || section == .codex {
                    Button {
                        Task { await syncProviderModels(item) }
                    } label: {
                        if syncingModelsProviderID == item.id {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text(item.models.isEmpty ? "同步模型" : "更新模型")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(syncingModelsProviderID != nil || busy)
                }

                Button {
                    Task { await testConnection(item) }
                } label: {
                    if testingProviderID == item.id {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("测试")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(testingProviderID != nil || item.disabled)

                Button("编辑") { beginEdit(item) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button(item.disabled ? "启用" : "禁用") {
                    Task { await toggleDisabled(item, disabled: !item.disabled) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("删除", role: .destructive) { pendingDelete = item }
                    .controlSize(.small)
            }
        }
    }

    private func modelListSheet(_ item: ProviderConfig) -> some View {
        CPAProviderModelsEditorSheet(
            item: item,
            section: section,
            onSaved: {
                showModelListFor = nil
                Task { await reload() }
            },
            onClose: { showModelListFor = nil }
        )
        .environment(appState)
    }

    // MARK: - Data

    private func reload() async {
        let targetSection = section
        busy = true
        defer {
            if section == targetSection { busy = false }
        }
        errorMessage = nil
        do {
            let path = targetSection.managementPath
            let json = try await appState.managementClient().getJSON(path: path)
            let all = normalizeList(json, section: targetSection)
            guard section == targetSection else { return }
            items = all
        } catch {
            guard section == targetSection else { return }
            items = []
            errorMessage = error.localizedDescription
        }
    }

    private func saveEditor() async {
        busy = true
        defer { busy = false }
        do {
            let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let typedKey = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

            let resolvedKey: String
            if editorMode == .edit {
                resolvedKey = typedKey.isEmpty ? (editingItem?.apiKey ?? "") : typedKey
            } else {
                resolvedKey = typedKey
            }

            try ProviderInputValidator.validate(
                name: section.requiresName ? name : (editingItem?.name ?? name),
                baseURL: base,
                apiKey: resolvedKey,
                requiresName: section.requiresName
            )

            let client = appState.managementClient()
            let path = section.managementPath
            let existingJSON = try await client.getJSON(path: path)
            var list = rawProviderRows(existingJSON, section: section)

            var openAIModels: [[String: Any]]?
            var modelSyncWarning: String?
            if section == .openai {
                let shouldAutoSync = editorMode == .add || (editingItem?.models.isEmpty ?? true)
                if shouldAutoSync {
                    do {
                        let endpoint = base.isEmpty ? ProviderKind.openAIDefaultBaseURL : base
                        let existingRows = editorMode == .edit
                            ? ((editingItem?.raw["models"] as? [[String: Any]]) ?? [])
                            : []
                        openAIModels = try await openAIModelRows(
                            endpoint: endpoint,
                            apiKey: resolvedKey,
                            existingRows: existingRows
                        )
                    } catch {
                        modelSyncWarning = "已保存，但自动同步模型失败：\(error.localizedDescription)。可在卡片上点「同步模型」重试。"
                    }
                }
            }

            if editorMode == .add {
                if section.requiresName,
                   list.contains(where: {
                       (($0["name"] as? String) ?? "").caseInsensitiveCompare(name) == .orderedSame
                   })
                {
                    throw AppError("Provider 名称已存在")
                }
                var entry: [String: Any] = ["disabled": false]
                ProviderConfig.applyAPIKey(to: &entry, apiKey: resolvedKey)
                if !base.isEmpty { entry["base-url"] = base }
                if section.requiresName { entry["name"] = name }
                if draftPriority > 0 {
                    entry["priority"] = draftPriority
                }
                if let openAIModels {
                    entry["models"] = openAIModels
                }
                list.append(entry)
            } else {
                guard let editing = editingItem else {
                    throw AppError("找不到要编辑的 Provider，请刷新后重试")
                }
                // Match by auth-index / name rather than filtered listIndex alone.
                guard let idx = resolveListIndex(of: editing, in: list) else {
                    throw AppError("找不到要编辑的 Provider，请刷新后重试")
                }
                var entry = list[idx]
                if section.requiresName {
                    let newName = name
                    if newName.caseInsensitiveCompare(editing.name) != .orderedSame,
                       list.enumerated().contains(where: { i, row in
                           i != idx
                               && ((row["name"] as? String) ?? "")
                               .caseInsensitiveCompare(newName) == .orderedSame
                       })
                    {
                        throw AppError("Provider 名称已存在")
                    }
                    entry["name"] = newName
                }
                entry["base-url"] = base
                ProviderConfig.applyAPIKey(to: &entry, apiKey: resolvedKey)
                entry["disabled"] = editing.disabled
                if draftPriority > 0 {
                    entry["priority"] = draftPriority
                } else {
                    entry.removeValue(forKey: "priority")
                }
                if let openAIModels {
                    entry["models"] = openAIModels
                }
                list[idx] = entry
            }

            // 先写本条密钥，再给列表其余条目补回 GET 省略的密钥，避免全量 PUT 冲掉 auth。
            list = injectCachedSecrets(into: list, section: section)

            _ = try await client.sendJSON(
                method: "PUT",
                path: path,
                body: list
            )

            // base is what identifies nameless sections (codex / claude / gemini); without it a
            // freshly added provider would have no cache entry and 「测试」 would fail immediately.
            let cacheName = section.requiresName ? name : nil
            if editorMode == .add {
                ProviderSecretStore.set(
                    section: section,
                    name: cacheName,
                    authIndex: nil,
                    baseURL: base,
                    apiKey: resolvedKey
                )
            } else if let editing = editingItem {
                ProviderSecretStore.set(
                    section: section,
                    name: section.requiresName ? name : editing.name,
                    authIndex: editing.authIndex,
                    baseURL: base,
                    apiKey: resolvedKey
                )
            }

            draftAPIKey = ""
            draftBaseURL = ""
            draftName = ""
            editingItem = nil
            showEditor = false
            if let modelSyncWarning {
                appState.flash(modelSyncWarning, error: true)
            } else {
                appState.flash(editorMode == .add ? "已保存" : "已更新")
            }
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func resolveListIndex(of item: ProviderConfig, in list: [[String: Any]]) -> Int? {
        if let auth = item.authIndex, !auth.isEmpty {
            if let idx = list.firstIndex(where: {
                (($0["auth-index"] as? String) ?? ($0["authIndex"] as? String)) == auth
            }) {
                return idx
            }
        }
        if !item.name.isEmpty, !item.name.hasPrefix("配置 ") {
            if let idx = list.firstIndex(where: {
                (($0["name"] as? String) ?? "").caseInsensitiveCompare(item.name) == .orderedSame
            }) {
                return idx
            }
        }
        if item.listIndex >= 0, item.listIndex < list.count {
            return item.listIndex
        }
        return nil
    }

    private func deleteItem(_ item: ProviderConfig) async {
        do {
            let path = section.managementPath
            let query = item.deletionQuery
            let client = appState.managementClient()
            if !query.isEmpty {
                do {
                    _ = try await client.sendJSON(
                        method: "DELETE",
                        path: path,
                        query: query,
                        body: nil
                    )
                } catch {
                    let existingJSON = try await client.getJSON(path: path)
                    var list = rawProviderRows(existingJSON, section: section)
                    if let idx = resolveListIndex(of: item, in: list) {
                        list.remove(at: idx)
                        list = injectCachedSecrets(into: list, section: section)
                        _ = try await client.sendJSON(
                            method: "PUT",
                            path: path,
                            body: list
                        )
                    } else {
                        throw error
                    }
                }
            } else {
                throw AppError("无法识别 Provider，已取消删除")
            }
            ProviderSecretStore.remove(
                section: section,
                name: item.name,
                authIndex: item.authIndex,
                baseURL: item.baseURL
            )
            appState.flash("已删除")
            await reload()
        } catch {
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func toggleDisabled(_ item: ProviderConfig, disabled: Bool) async {
        do {
            let path = section.managementPath
            let client = appState.managementClient()
            let existingJSON = try await client.getJSON(path: path)
            var list = rawProviderRows(existingJSON, section: section)
            guard let idx = resolveListIndex(of: item, in: list) else {
                throw AppError("Provider 索引无效，请刷新后重试")
            }
            list[idx]["disabled"] = disabled
            list = injectCachedSecrets(into: list, section: section)
            if (list[idx]["api-key"] as? String)?.isEmpty != false, !item.apiKey.isEmpty {
                list[idx]["api-key"] = item.apiKey
            }
            _ = try await client.sendJSON(
                method: "PUT",
                path: path,
                body: list
            )
            await reload()
        } catch {
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func testConnection(_ item: ProviderConfig) async {
        testingProviderID = item.id
        defer { testingProviderID = nil }
        do {
            var provider = item
            if provider.apiKey.isEmpty {
                if let cached = ProviderSecretStore.get(
                    section: section,
                    name: item.name,
                    authIndex: item.authIndex,
                    baseURL: item.baseURL
                ) {
                    provider.apiKey = cached
                } else {
                    throw AppError("密钥未在本地缓存。请点「编辑」重新填写 API Key 后再测试（服务端列表通常不回传密钥）。")
                }
            }
            let result = try await ProviderConnectionTester.test(kind: section, provider: provider)
            testResults[item.id] = "成功 · \(result)"
        } catch {
            testResults[item.id] = "失败 · \(error.localizedDescription)"
        }
    }

    private func syncProviderModels(_ item: ProviderConfig) async {
        if section == .openai {
            await syncOpenAIModels(item)
        } else if section == .codex {
            await syncCodexAPIModels(item)
        }
    }

    /// Fetch the upstream `/models` payload and write it into this openai-compatibility row.
    private func syncOpenAIModels(_ item: ProviderConfig) async {
        syncingModelsProviderID = item.id
        defer { syncingModelsProviderID = nil }
        do {
            var key = item.apiKey
            if key.isEmpty {
                key = ProviderSecretStore.get(
                    section: .openai,
                    name: item.name,
                    authIndex: item.authIndex,
                    baseURL: item.baseURL
                ) ?? ""
            }
            if key.isEmpty {
                key = ProviderConfig.extractAPIKey(from: item.raw).key
            }
            guard !key.isEmpty else {
                throw AppError("本地没有 API Key 缓存。请先「编辑」重新填写密钥，再同步模型。")
            }

            let endpoint = item.baseURL.isEmpty ? ProviderKind.openAIDefaultBaseURL : item.baseURL
            let existingRows = (item.raw["models"] as? [[String: Any]]) ?? []
            let rows = try await openAIModelRows(
                endpoint: endpoint,
                apiKey: key,
                existingRows: existingRows,
                ownerName: item.name,
                otherProviderAliases: otherProviderAliases(excludingOwner: item.name)
            )

            let client = appState.managementClient()
            let path = section.managementPath
            let existingJSON = try await client.getJSON(path: path)
            var list = rawProviderRows(existingJSON, section: section)
            list = injectCachedSecrets(into: list, section: section)
            guard let idx = resolveListIndex(of: item, in: list) else {
                throw AppError("找不到 Provider，请刷新后重试")
            }
            var entry = list[idx]
            entry["models"] = rows
            if !item.name.isEmpty, !item.name.hasPrefix("配置 ") {
                entry["name"] = item.name
            }
            if !item.baseURL.isEmpty {
                entry["base-url"] = item.baseURL
            }
            ProviderConfig.applyAPIKey(to: &entry, apiKey: key)
            list[idx] = entry
            list = injectCachedSecrets(into: list, section: section)
            _ = try await client.sendJSON(method: "PUT", path: path, body: list)

            appState.flash("已同步 \(rows.count) 个模型")
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            appState.flash(error.localizedDescription, error: true)
        }
    }

    /// Fetch the upstream `/models` payload and write it into this codex-api-key row.
    private func syncCodexAPIModels(_ item: ProviderConfig) async {
        syncingModelsProviderID = item.id
        defer { syncingModelsProviderID = nil }
        do {
            var key = item.apiKey
            if key.isEmpty {
                key = ProviderSecretStore.get(
                    section: .codex,
                    name: item.name,
                    authIndex: item.authIndex,
                    baseURL: item.baseURL
                ) ?? ""
            }
            if key.isEmpty {
                key = ProviderConfig.extractAPIKey(from: item.raw).key
            }
            guard !key.isEmpty else {
                throw AppError("本地没有 API Key 缓存。请先「编辑」重新填写密钥，再同步模型。")
            }
            guard !item.baseURL.isEmpty else {
                throw AppError("缺少 base URL，请先编辑填写后再同步模型。")
            }

            let existingRows = (item.raw["models"] as? [[String: Any]]) ?? []
            let ownerName = ProviderKind.hostDerivedDisplayName(baseURL: item.baseURL)
            let rows = try await openAIModelRows(
                endpoint: item.baseURL,
                apiKey: key,
                existingRows: existingRows,
                ownerName: ownerName,
                otherProviderAliases: otherProviderAliases(excludingOwner: ownerName)
            )

            let client = appState.managementClient()
            let path = ProviderKind.codex.managementPath
            let storage = ProviderKind.codex
            let existingJSON = try await client.getJSON(path: path)
            var list = rawProviderRows(existingJSON, section: storage)
            list = injectCachedSecrets(into: list, section: storage)
            guard let idx = resolveListIndex(of: item, in: list) else {
                throw AppError("找不到 Provider，请刷新后重试")
            }
            var entry = list[idx]
            entry["models"] = rows
            if !item.name.isEmpty, !item.name.hasPrefix("配置 ") {
                entry["name"] = item.name
            }
            if !item.baseURL.isEmpty {
                entry["base-url"] = item.baseURL
            }
            ProviderConfig.applyAPIKey(to: &entry, apiKey: key)
            list[idx] = entry
            list = injectCachedSecrets(into: list, section: storage)
            _ = try await client.sendJSON(method: "PUT", path: path, body: list)

            appState.flash("已同步 \(rows.count) 个模型")
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func openAIModelRows(
        endpoint: String,
        apiKey: String,
        existingRows: [[String: Any]] = [],
        ownerName: String = "",
        otherProviderAliases: Set<String> = []
    ) async throws -> [[String: Any]] {
        let models = try await AgentModelCatalogService.fetchUpstream(endpoint: endpoint, apiKey: apiKey)
        return AgentModelCatalogService.openAIModelRows(
            from: models,
            existingRows: existingRows,
            ownerName: ownerName,
            otherProviderAliases: otherProviderAliases
        )
    }

    /// Every model alias currently configured under a *different* provider than `owner`, across
    /// both `openai-compatibility` and `codex-api-key`. Used to detect id collisions before a
    /// sync assigns a brand-new alias -- see `AgentModelCatalogService.openAIModelRows`.
    private func otherProviderAliases(excludingOwner owner: String) -> Set<String> {
        let normalizedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Set(
            AgentModelCatalogService.loadLocalProviderModels(from: AppPaths.coreConfigURL)
                .filter { $0.owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != normalizedOwner }
                .map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
    }

    // MARK: - Helpers

    /// Management API returns either a bare array or `{ "<section>": [ ... ] }`.
    private func rawProviderRows(_ json: Any, section: ProviderKind) -> [[String: Any]] {
        if let list = json as? [[String: Any]] {
            return list
        }
        if let dict = json as? [String: Any] {
            if let list = dict[section.rawValue] as? [[String: Any]] {
                return list
            }
            if let list = dict["items"] as? [[String: Any]] {
                return list
            }
            if let list = dict["data"] as? [[String: Any]] {
                return list
            }
            if dict["api-key"] != nil || dict["name"] != nil {
                return [dict]
            }
        }
        return []
    }

    private func normalizeList(_ json: Any, section: ProviderKind) -> [ProviderConfig] {
        rawProviderRows(json, section: section)
            .enumerated()
            .map { index, row in
                let name = (row["name"] as? String)
                let extracted = ProviderConfig.extractAPIKey(from: row)
                let authIndex = (row["auth-index"] as? String)
                    ?? (row["authIndex"] as? String)
                    ?? extracted.authIndex
                let serverKey = extracted.key
                let baseURL = (row["base-url"] as? String) ?? (row["baseUrl"] as? String)
                let cached = ProviderSecretStore.get(
                    section: section,
                    name: name,
                    authIndex: authIndex,
                    baseURL: baseURL
                )
                if !serverKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ProviderSecretStore.set(
                        section: section,
                        name: name,
                        authIndex: authIndex,
                        baseURL: baseURL,
                        apiKey: serverKey
                    )
                }
                return ProviderConfig(raw: row, index: index, cachedAPIKey: cached)
            }
    }

    /// Before full-list PUT, re-inject secrets that GET omitted (legacy + api-key-entries).
    private func injectCachedSecrets(into list: [[String: Any]], section: ProviderKind) -> [[String: Any]] {
        ProviderSecretStore.reinject(into: list, section: section)
    }

    private func maskKey(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: max(key.count, 4)) }
        return String(key.prefix(4)) + "…" + String(key.suffix(4))
    }
}
