import SwiftUI

/// Add / edit a remote agent provider (same role as local Agents editor).
struct RemoteAgentProviderEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    let host: RemoteSSHHost
    let agent: AgentKind
    let existing: AgentProviderProfile?
    let onSaved: (AgentProviderProfile) -> Void

    @State private var name = ""
    @State private var models: [AgentModelRole: String] = [:]
    @State private var catalogModels: [String] = []
    @State private var modelOverrides: [String: AgentModelOverride] = [:]
    @State private var catalog: [AgentModelCatalogService.Model] = []
    @State private var claimsOpenAIProvider = false
    @State private var codexSubscriptionOnly = false
    @State private var isFetching = false
    @State private var catalogError: String?

    private var isLocalCPA: Bool { existing?.isLocalCPA == true }

    private var uncompactableModels: [String] {
        AgentModelCatalogService.modelsWithoutRemoteCompaction(catalog: catalogModels, known: catalog)
    }

    private var effortModelID: String {
        switch agent {
        case .codex:
            return models[.main] ?? ""
        case .claude:
            for role in [AgentModelRole.main, .sonnet, .opus, .haiku, .fable, .subagent] {
                let value = (models[role] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
            return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existing == nil ? "添加远程 Provider" : "编辑远程 Provider")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()

            Divider()

            Form {
                Section {
                    Text("\(host.name) · \(agent.title)")
                        .foregroundStyle(.secondary)
                    TextField("名称", text: $name)
                        .disabled(isLocalCPA || (existing?.isDefault ?? false))
                } footer: {
                    Text("Endpoint / API Key 跟随本机 CPA 与局域网可达地址；这里配置模型映射。保存后在列表里点「启用」。")
                        .font(.caption)
                }

                Section {
                    if agent == .codex {
                        CodexCatalogModelsEditor(
                            defaultModel: Binding(
                                get: { models[.main] ?? "" },
                                set: { models[.main] = $0 }
                            ),
                            catalogModels: $catalogModels,
                            modelOverrides: $modelOverrides,
                            fetchedCatalog: catalog
                        )
                    } else {
                        ForEach(agent.modelRoles) { role in
                            modelRow(role)
                        }
                        if AgentModelCapabilityEditor.hasEditableCapabilities(agent) {
                            AgentModelCapabilityEditor(
                                agent: agent,
                                modelID: effortModelID,
                                modelOverrides: $modelOverrides
                            )
                        }
                        Text("实际档位在 \(agent.title) 里调整。")
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
                        .disabled(isFetching)
                    }
                } footer: {
                    if let catalogError {
                        Text(catalogError).font(.caption).foregroundStyle(.orange)
                    } else if catalog.isEmpty {
                        Text("点「获取模型」从本机 CPA 拉列表").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("已获取 \(catalog.count) 个模型").font(.caption).foregroundStyle(.secondary)
                    }
                }

                if agent == .codex {
                    Section {
                        Toggle(isOn: $claimsOpenAIProvider) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("远程压缩（写 name = \"OpenAI\"）")
                                Text("Codex 只认 model_providers 的 name 是否等于 OpenAI。远端 Codex 与本机走同一个 CPA，能力判断一致。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Toggle(isOn: $codexSubscriptionOnly) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("同名 GPT 模型只走 Codex 订阅")
                                Text("在本机 CPA 上把订阅同样提供的 GPT 模型从其他 Provider 的路由里摘掉，影响所有客户端。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if claimsOpenAIProvider, !uncompactableModels.isEmpty {
                            Label(
                                "这些模型的上游没有 /responses/compact：\(uncompactableModels.joined(separator: "、"))。远程压缩失败不会退回本地压缩。",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        } else if claimsOpenAIProvider, !codexSubscriptionOnly {
                            Text("某个 API Provider 当前权重高于 Codex 订阅，同名 GPT 模型会先落到它那边，那边没有压缩端点。建议一并开启上面的隔离开关。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("远程压缩")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 560)
        .onAppear(perform: bootstrap)
    }

    private func modelRow(_ role: AgentModelRole) -> some View {
        let supportsOneM = role.supportsOneMContext(for: agent)
        let binding = Binding(
            get: { models[role] ?? "" },
            set: { models[role] = supportsOneM ? $0 : ClaudeContextMarker.stripOneM($0) }
        )
        let oneM = Binding(
            get: { ClaudeContextMarker.hasOneM(models[role] ?? "") },
            set: { models[role] = ClaudeContextMarker.setOneM(models[role] ?? "", enabled: $0) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(role.title(for: agent), text: binding, prompt: Text("不指定"))
                if !catalog.isEmpty {
                    Menu {
                        Button("不指定") { binding.wrappedValue = "" }
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
            if supportsOneM {
                Toggle("1M 上下文", isOn: oneM)
                    .toggleStyle(.checkbox)
                    .font(.caption2)
            }
        }
    }

    private func bootstrap() {
        if let existing {
            name = existing.name
            for role in agent.modelRoles {
                models[role] = existing.model(for: role)
            }
            catalogModels = existing.catalogModels
            modelOverrides = existing.modelOverrides
            claimsOpenAIProvider = existing.claimsOpenAIProvider
            codexSubscriptionOnly = existing.codexSubscriptionOnly
            if catalogModels.isEmpty, !existing.model.isEmpty {
                catalogModels = [existing.model]
            }
        } else {
            name = ""
            let local = AgentProviderStore.loadProfiles().first(where: { $0.agent == agent && $0.isLocalCPA })
            for role in agent.modelRoles {
                models[role] = local?.model(for: role) ?? ""
            }
            catalogModels = local?.catalogModels ?? []
            modelOverrides = local?.modelOverrides ?? [:]
            claimsOpenAIProvider = local?.claimsOpenAIProvider ?? false
            codexSubscriptionOnly = local?.codexSubscriptionOnly ?? false
        }
        fetchCatalog()
    }

    private func fetchCatalog() {
        isFetching = true
        catalogError = nil
        let gui = appState.guiConfig.snapshot()
        let endpoint = RemoteAgentConfigurator.localCatalogEndpoint(agent: agent, cpaPort: gui.port)
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

    private func commit() {
        let gui = appState.guiConfig.snapshot()
        let key = appState.firstAPIKey()
        guard !key.isEmpty else {
            appState.flash("请先在配置页添加 API Key", error: true)
            return
        }
        let cpaHost: String
        do {
            cpaHost = try RemoteAgentConfigurator.resolveCPAReachableHost(
                sshHost: host,
                lanIPv4: appState.lanIPv4 ?? localLANIPv4(),
                allowLan: gui.allowLan
            )
        } catch {
            appState.flash(error.localizedDescription, error: true)
            return
        }

        var base = RemoteAgentConfigurator.remoteLocalCPAProfile(
            agent: agent,
            template: nil,
            cpaHost: cpaHost,
            cpaPort: gui.port,
            apiKey: key
        )
        if let existing {
            base.id = existing.id
            base.isDefault = existing.isDefault
            base.isLocalCPA = existing.isLocalCPA
            base.createdAt = existing.createdAt
            base.notes = existing.notes
        } else {
            base.id = UUID().uuidString
            base.isLocalCPA = false
            base.createdAt = Date()
        }
        base.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for role in agent.modelRoles {
            base.setModel((models[role] ?? "").trimmingCharacters(in: .whitespacesAndNewlines), for: role)
        }
        base.reasoningEffort = ""
        base.modelOverrides = modelOverrides
        if agent == .codex {
            var ids = catalogModels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let main = base.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !main.isEmpty, !ids.contains(main) { ids.append(main) }
            base.catalogModels = ids
            base.claimsOpenAIProvider = claimsOpenAIProvider
            base.codexSubscriptionOnly = codexSubscriptionOnly
        }
        if existing?.isLocalCPA == true {
            base.isLocalCPA = true
            base.id = RemoteAgentProviderStore.localCPAID(hostID: host.id, agent: agent)
            base.name = "本机 CPA（远程）"
        }
        onSaved(base)
        dismiss()
    }
}
