import SwiftUI

/// Configure model mappings then apply (or restore 「默认」) on a remote SSH host.
struct RemoteAgentApplySheet: View {
    enum Mode: Identifiable, Equatable {
        case single(AgentKind)
        case all

        var id: String {
            switch self {
            case .single(let agent): return "single-\(agent.rawValue)"
            case .all: return "all"
            }
        }

        var title: String {
            switch self {
            case .single(let agent): return "配置远程 \(agent.title)"
            case .all: return "配置远程全部智能体"
            }
        }
    }

    struct Target: Identifiable, Equatable {
        var host: RemoteSSHHost
        var mode: Mode
        var id: String { "\(host.id)-\(mode.id)" }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    let host: RemoteSSHHost
    let mode: Mode
    let onFinished: (String) -> Void

    @State private var selectedAgent: AgentKind = .codex
    @State private var drafts: [AgentKind: Draft] = [:]
    @State private var catalog: [AgentModelCatalogService.Model] = []
    @State private var isFetching = false
    @State private var catalogError: String?
    @State private var isBusy = false
    @State private var statusMessage = ""

    private struct Draft {
        var models: [AgentModelRole: String] = [:]
        var catalogModels: [String] = []
        var modelOverrides: [String: AgentModelOverride] = [:]
        var reasoningEffort = ""
        var claimsOpenAIProvider = false
        var codexSubscriptionOnly = false
    }

    private var claimsRemoteCompaction: Bool {
        drafts[activeAgent]?.claimsOpenAIProvider ?? false
    }

    private var uncompactableModels: [String] {
        AgentModelCatalogService.modelsWithoutRemoteCompaction(
            catalog: drafts[activeAgent]?.catalogModels ?? [],
            known: catalog
        )
    }

    private var agents: [AgentKind] {
        switch mode {
        case .single(let agent): return [agent]
        case .all: return AgentKind.allCases
        }
    }

    private var activeAgent: AgentKind {
        switch mode {
        case .single(let agent): return agent
        case .all: return selectedAgent
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(mode.title)
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
            }
            .padding()

            Divider()

            Form {
                Section {
                    Text(host.name)
                    Text(host.displayTarget)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("写入远端 live 配置，指向本机 CPA。首次应用会拉取远程现有文件存为「默认」，之后可一键还原。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if case .all = mode {
                    Section {
                        Picker("智能体", selection: $selectedAgent) {
                            ForEach(AgentKind.allCases) { agent in
                                Text(agent.title).tag(agent)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: selectedAgent) { _, _ in
                            catalog = []
                            catalogError = nil
                        }
                    }
                }

                Section {
                    if activeAgent == .codex {
                        CodexCatalogModelsEditor(
                            defaultModel: Binding(
                                get: { drafts[activeAgent]?.models[.main] ?? "" },
                                set: { value in
                                    var draft = drafts[activeAgent] ?? Draft()
                                    draft.models[.main] = value
                                    drafts[activeAgent] = draft
                                }
                            ),
                            catalogModels: Binding(
                                get: { drafts[activeAgent]?.catalogModels ?? [] },
                                set: { value in
                                    var draft = drafts[activeAgent] ?? Draft()
                                    draft.catalogModels = value
                                    drafts[activeAgent] = draft
                                }
                            ),
                            modelOverrides: Binding(
                                get: { drafts[activeAgent]?.modelOverrides ?? [:] },
                                set: { value in
                                    var draft = drafts[activeAgent] ?? Draft()
                                    draft.modelOverrides = value
                                    drafts[activeAgent] = draft
                                }
                            ),
                            fetchedCatalog: catalog
                        )
                    } else {
                        ForEach(activeAgent.modelRoles) { role in
                            modelRow(role, agent: activeAgent)
                        }
                        if AgentModelCapabilityEditor.hasEditableCapabilities(activeAgent) {
                            AgentModelCapabilityEditor(
                                agent: activeAgent,
                                modelID: effortModelID(for: activeAgent),
                                modelOverrides: Binding(
                                    get: { drafts[activeAgent]?.modelOverrides ?? [:] },
                                    set: { value in
                                        var draft = drafts[activeAgent] ?? Draft()
                                        draft.modelOverrides = value
                                        drafts[activeAgent] = draft
                                    }
                                )
                            )
                        }
                        Text("实际档位在 \(activeAgent.title) 里调整。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } header: {
                    HStack {
                        Text("模型映射")
                        Spacer()
                        Button {
                            fetchCatalog()
                        } label: {
                            if isFetching {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("获取模型", systemImage: "arrow.down.circle")
                            }
                        }
                        .disabled(isFetching || isBusy)
                    }
                } footer: {
                    if let catalogError {
                        Text(catalogError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if catalog.isEmpty {
                        Text(footerHint(for: activeAgent))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("已获取 \(catalog.count) 个模型，可多选写入 catalog")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if activeAgent == .codex {
                    Section {
                        Toggle("远程压缩（写 name = \"OpenAI\"）", isOn: Binding(
                            get: { drafts[activeAgent]?.claimsOpenAIProvider ?? false },
                            set: { value in
                                var draft = drafts[activeAgent] ?? Draft()
                                draft.claimsOpenAIProvider = value
                                drafts[activeAgent] = draft
                            }
                        ))
                        Toggle("同名 GPT 模型只走 Codex 订阅", isOn: Binding(
                            get: { drafts[activeAgent]?.codexSubscriptionOnly ?? false },
                            set: { value in
                                var draft = drafts[activeAgent] ?? Draft()
                                draft.codexSubscriptionOnly = value
                                drafts[activeAgent] = draft
                            }
                        ))
                        if claimsRemoteCompaction, !uncompactableModels.isEmpty {
                            Label(
                                "这些模型的上游没有 /responses/compact：\(uncompactableModels.joined(separator: "、"))。远程压缩失败不会退回本地压缩。",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        } else if claimsRemoteCompaction, drafts[activeAgent]?.codexSubscriptionOnly != true {
                            Text("某个 API Provider 当前权重高于 Codex 订阅，同名 GPT 模型会先落到它那边，那边没有压缩端点。建议一并开启上面的隔离开关。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("远程压缩")
                    } footer: {
                        Text("远端 Codex 与本机走同一个 CPA。隔离开关改的是本机 CPA 的路由，对所有客户端生效。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !statusMessage.isEmpty {
                    Section {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if RemoteAgentDefaultSnapshot.hasSnapshot(hostID: host.id, agent: activeAgent) {
                    Button("恢复默认") {
                        restore(activeAgent)
                    }
                    .disabled(isBusy)
                    .help("把首次配置前拉取的远程文件写回")
                }
                Spacer()
                if case .all = mode {
                    Button("全部应用") {
                        applyAll()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                } else {
                    Button("应用到远程") {
                        apply(activeAgent)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
                }
            }
            .padding()
        }
        .frame(width: 560, height: 560)
        .onAppear(perform: bootstrap)
    }

    // MARK: - Rows

    private func effortModelID(for agent: AgentKind) -> String {
        let draft = drafts[agent]
        switch agent {
        case .codex:
            return draft?.models[.main] ?? ""
        case .claude:
            for role in [AgentModelRole.main, .sonnet, .opus, .haiku, .fable, .subagent] {
                let value = (draft?.models[role] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
            return ""
        }
    }

    private func modelRow(_ role: AgentModelRole, agent: AgentKind) -> some View {
        let supportsOneM = role.supportsOneMContext(for: agent)
        let binding = Binding(
            get: { drafts[agent]?.models[role] ?? "" },
            set: { value in
                var draft = drafts[agent] ?? Draft()
                draft.models[role] = supportsOneM ? value : ClaudeContextMarker.stripOneM(value)
                drafts[agent] = draft
            }
        )
        let oneM = Binding(
            get: { ClaudeContextMarker.hasOneM(drafts[agent]?.models[role] ?? "") },
            set: { enabled in
                var draft = drafts[agent] ?? Draft()
                draft.models[role] = ClaudeContextMarker.setOneM(draft.models[role] ?? "", enabled: enabled)
                drafts[agent] = draft
            }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(role.title(for: agent), text: binding, prompt: Text("不指定"))
                if !catalog.isEmpty {
                    Menu {
                        Button("不指定（不写入配置）") { binding.wrappedValue = "" }
                        Divider()
                        ForEach(AgentModelCatalogService.groups(catalog)) { group in
                            Section(group.title) {
                                ForEach(group.models, id: \.identity) { model in
                                    Button(model.id) {
                                        binding.wrappedValue = supportsOneM
                                            ? ClaudeContextMarker.setOneM(model.id, enabled: oneM.wrappedValue)
                                            : model.id
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 44)
                }
            }
            HStack(spacing: 8) {
                Text(role.hint(for: agent))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                if supportsOneM {
                    Spacer()
                    Toggle("1M 上下文", isOn: oneM)
                        .toggleStyle(.checkbox)
                        .font(.caption2)
                        .disabled(ClaudeContextMarker.stripOneM(binding.wrappedValue)
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func footerHint(for agent: AgentKind) -> String {
        switch agent {
        case .claude:
            return "从本机 CPA 拉模型列表后选择；留空则不写入该字段。"
        case .codex:
            return "可配置多个模型写入 catalog；选一个为默认。点「获取模型」后可「添加全部已获取」。"
        }
    }

    // MARK: - Actions

    private func bootstrap() {
        if case .single(let agent) = mode {
            selectedAgent = agent
        } else {
            selectedAgent = .codex
        }
        let gui = appState.guiConfig.snapshot()
        for agent in agents {
            var draft = Draft()
            if let template = AgentProviderStore.loadProfiles().first(where: { $0.agent == agent && $0.isLocalCPA }) {
                for role in agent.modelRoles {
                    draft.models[role] = template.model(for: role)
                }
                draft.catalogModels = template.catalogModels
                if draft.catalogModels.isEmpty, let main = draft.models[.main], !main.isEmpty {
                    draft.catalogModels = [main]
                }
                draft.modelOverrides = template.modelOverrides
                draft.reasoningEffort = template.reasoningEffort
                draft.claimsOpenAIProvider = template.claimsOpenAIProvider
                draft.codexSubscriptionOnly = template.codexSubscriptionOnly
            }
            drafts[agent] = draft
        }
        _ = gui
        // Auto-fetch catalog for the active agent so Codex has selectable models.
        fetchCatalog()
    }

    private func template(for agent: AgentKind) -> AgentProviderProfile {
        let gui = appState.guiConfig.snapshot()
        let key = appState.firstAPIKey()
        var profile = AgentProviderProfile.localCPA(agent: agent, port: gui.port, apiKey: key)
        let draft = drafts[agent] ?? Draft()
        for role in agent.modelRoles {
            let value = (draft.models[role] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            profile.setModel(value, for: role)
        }
        profile.reasoningEffort = ""
        profile.modelOverrides = draft.modelOverrides
        if agent == .codex {
            var ids = draft.catalogModels
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let main = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !main.isEmpty, !ids.contains(main) {
                ids.append(main)
            }
            profile.catalogModels = ids
            profile.claimsOpenAIProvider = draft.claimsOpenAIProvider
            profile.codexSubscriptionOnly = draft.codexSubscriptionOnly
        }
        return profile
    }

    private func fetchCatalog() {
        isFetching = true
        catalogError = nil
        let gui = appState.guiConfig.snapshot()
        let endpoint = RemoteAgentConfigurator.localCatalogEndpoint(agent: activeAgent, cpaPort: gui.port)
        let key = appState.firstAPIKey()
        Task {
            do {
                let ids = try await AgentModelCatalogService.fetch(endpoint: endpoint, apiKey: key)
                await MainActor.run {
                    catalog = ids
                    isFetching = false
                }
            } catch {
                await MainActor.run {
                    catalogError = error.localizedDescription
                    isFetching = false
                }
            }
        }
    }

    private func apply(_ agent: AgentKind) {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = "正在应用到远程…"
        let gui = appState.guiConfig.snapshot()
        let template = template(for: agent)
        let apiKey = appState.firstAPIKey()
        let lan = appState.lanIPv4
        let hostName = host.name
        Task.detached(priority: .userInitiated) {
            do {
                let result = try RemoteAgentConfigurator.apply(
                    agent: agent,
                    sshHost: host,
                    template: template,
                    cpaPort: gui.port,
                    apiKey: apiKey,
                    lanIPv4: lan,
                    allowLan: gui.allowLan,
                    catalogModels: agent == .codex ? template.resolvedCodexCatalogModels : nil
                )
                let summary = "\(result.message)\n→ \(result.remotePath)"
                await MainActor.run {
                    self.isBusy = false
                    self.statusMessage = summary
                    self.onFinished(summary)
                    self.appState.flash("\(hostName)：\(result.message)")
                    self.dismiss()
                }
                await self.appState.syncCodexSubscriptionIsolation(for: template)
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.statusMessage = error.localizedDescription
                    self.appState.flash(error.localizedDescription, error: true)
                }
            }
        }
    }

    private func applyAll() {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = "正在配置全部智能体…"
        let gui = appState.guiConfig.snapshot()
        let templates = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0, template(for: $0)) })
        let catalogModelsByAgent: [AgentKind: [String]] = [
            .codex: templates[.codex]?.resolvedCodexCatalogModels ?? []
        ]
        let apiKey = appState.firstAPIKey()
        let lan = appState.lanIPv4
        let hostName = host.name
        Task.detached(priority: .userInitiated) {
            do {
                let results = try RemoteAgentConfigurator.applyAll(
                    sshHost: host,
                    templates: templates,
                    cpaPort: gui.port,
                    apiKey: apiKey,
                    lanIPv4: lan,
                    allowLan: gui.allowLan,
                    catalogModelsByAgent: catalogModelsByAgent
                )
                let summary = results.map { "\($0.agent.title)：\($0.message) → \($0.remotePath)" }
                    .joined(separator: "\n")
                await MainActor.run {
                    self.isBusy = false
                    self.statusMessage = summary
                    self.onFinished(summary)
                    self.appState.flash("\(hostName)：已配置 Claude / Codex")
                    self.dismiss()
                }
                if let codex = templates[.codex] {
                    await self.appState.syncCodexSubscriptionIsolation(for: codex)
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.statusMessage = error.localizedDescription
                    self.appState.flash(error.localizedDescription, error: true)
                }
            }
        }
    }

    private func restore(_ agent: AgentKind) {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = "正在恢复远程默认配置…"
        let hostName = host.name
        let unify = RemoteAgentProviderStore.load(hostID: host.id).unifyCodexSessionHistory
        Task.detached(priority: .userInitiated) {
            do {
                let result = try RemoteAgentConfigurator.restoreDefault(
                    agent: agent,
                    sshHost: host,
                    unifyCodexSessionHistory: unify
                )
                let summary = "\(result.message)\n→ \(result.remotePath)"
                await MainActor.run {
                    self.isBusy = false
                    self.statusMessage = summary
                    self.onFinished(summary)
                    self.appState.flash("\(hostName)：\(result.message)")
                    self.dismiss()
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.statusMessage = error.localizedDescription
                    self.appState.flash(error.localizedDescription, error: true)
                }
            }
        }
    }
}
