import AppKit
import SwiftUI

struct AgentsPageView: View {
    @Environment(AppState.self) private var appState

    enum Tab: String, CaseIterable, Identifiable {
        case providers
        case sessions

        var id: String { rawValue }
        var title: String {
            switch self {
            case .providers: return "接入配置"
            case .sessions: return "会话"
            }
        }
    }

    @State private var tab: Tab = .providers
    @State private var selectedAgent: AgentKind = .claude
    @State private var profiles: [AgentProviderProfile] = []
    @State private var settings = AgentSettings.default
    @State private var sessions: [AgentSessionRecord] = []
    @State private var sessionQuery = ""
    @State private var sessionAgentFilter: AgentKind? = nil
    @State private var isBusy = false
    @State private var editorTarget: AgentEditorTarget?
    @State private var pendingDeleteProfile: AgentProviderProfile?
    @State private var pendingDeleteSession: AgentSessionRecord?
    @State private var pendingFixCodexDesktopModels: Bool?
    /// `model_provider` currently in `~/.codex/config.toml` — the only thing that decides the bucket.
    @State private var codexLiveBucket: String?

    var body: some View {
        PageContainer(layout: .fill) {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, AppDesign.pagePadding)
                    .padding(.top, AppDesign.pagePadding)
                    .padding(.bottom, 12)

                Divider().opacity(0.45)

                Group {
                    switch tab {
                    case .providers:
                        providersPane
                    case .sessions:
                        sessionsPane
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("客户端接入")
        .onAppear(perform: reloadAll)
        .sheet(item: $editorTarget) { target in
            AgentProviderEditorSheet(
                agent: target.agent,
                existing: target.profile,
                defaultEndpoint: defaultEndpoint(for: target.agent),
                defaultAPIKey: currentAPIKey()
            ) { saved in
                saveProfile(saved)
            }
        }
        .confirmDestructive(
            $pendingDeleteProfile,
            title: "删除后无法自动恢复",
            confirmLabel: { $0.isDefault ? "删除快照" : "删除「\($0.name)」" },
            message: deleteProfileWarning,
            action: deleteProfile
        )
        .confirmDestructive(
            $pendingDeleteSession,
            title: "删除会话？",
            confirmLabel: { _ in "删除会话" },
            message: { "将永久删除 \($0.filePath)，无法恢复。" },
            action: deleteSession
        )
        .confirmDestructive(
            $pendingFixCodexDesktopModels,
            title: "修复 Codex Desktop 自定义模型？",
            confirmLabel: { _ in "删除并重建" },
            message: { _ in
                "Codex Desktop 会把登录态和模型列表缓存在 ~/.codex 里，导致自定义模型不出现。"
                    + "将删除（若存在）auth.json、.codex-global-state.json、.codex-global-state.json.back，"
                    + "然后写入本机 CPA 使用的 auth.json。ChatGPT 登录态会丢失，完成后请重启 Codex Desktop。"
            },
            action: { _ in fixCodexDesktopCustomModels() }
        )
    }

    /// Spell out what the user loses, which differs a lot between the three delete entries.
    private func deleteProfileWarning(_ profile: AgentProviderProfile) -> String {
        let livePath = profile.agent.liveConfigPathHint
        guard !profile.isDefault else {
            return "「接管前配置」保存的是启用本应用前的 \(livePath)。删除快照后将无法再还原到那份配置。"
        }
        guard settings.currentProviderID(for: profile.agent) == profile.id else {
            return "仅删除应用内保存的这套接入配置，不改动 \(livePath)。"
        }
        let hasSnapshot = profiles.contains { $0.agent == profile.agent && $0.isDefault }
        return hasSnapshot
            ? "「\(profile.name)」正在生效，删除后 \(livePath) 会还原为「接管前配置」快照。"
            : "「\(profile.name)」正在生效，且没有「接管前配置」快照可还原，删除后 \(livePath) 仍保留它写入的配置。"
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("客户端接入")
                    .font(.title3.weight(.semibold))
                Text("切换本地接入配置，管理编码会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            Button {
                reloadAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isBusy)
            .help("刷新接入配置与会话")
        }
        .frame(maxWidth: AppDesign.contentMaxWidth)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Providers

    private var providersPane: some View {
        VStack(spacing: 0) {
            agentPicker
                .padding(.horizontal, AppDesign.pagePadding)
                .padding(.vertical, 12)
            Divider().opacity(0.35)
            providerList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var agentPicker: some View {
        HStack(spacing: 8) {
            ForEach(AgentKind.allCases) { agent in
                let selected = selectedAgent == agent
                Button {
                    selectedAgent = agent
                } label: {
                    Label(agent.title, systemImage: agent.systemImage)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            selected ? Color.accentColor : Color.secondary.opacity(0.12),
                            in: Capsule()
                        )
                        .foregroundStyle(selected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(maxWidth: AppDesign.contentMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private var filteredProfiles: [AgentProviderProfile] {
        profiles.filter { $0.agent == selectedAgent }
            .sorted(by: AgentProviderStore.providerSort)
    }

    private var currentProviderID: String? {
        settings.currentProviderID(for: selectedAgent)
    }

    private var liveHint: String? {
        let live = AgentLiveConfigReader.read(agent: selectedAgent)
        guard live.configExists else {
            return "未检测到 \(selectedAgent.liveConfigPathHint)"
        }
        guard let endpoint = live.endpoint, !endpoint.isEmpty else {
            return "已检测到 \(selectedAgent.liveConfigPathHint) · 尚未设置自定义接入配置"
        }
        let modelPart = (live.model?.isEmpty == false) ? " · 模型 \(live.model!)" : ""
        return "live：\(endpoint)\(modelPart)"
    }

    private var providerList: some View {
        ScrollView {
            VStack(spacing: AppDesign.pageStackSpacing) {
                agentSummaryCard

                if selectedAgent == .codex {
                    codexSettingsCard
                    codexRemoteCompactionNote
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("接入配置")
                            .font(.headline)
                        Text("\(filteredProfiles.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            editorTarget = .new(agent: selectedAgent)
                        } label: {
                            Label("添加", systemImage: "plus")
                        }
                    }

                    if filteredProfiles.isEmpty {
                        GlassCard {
                            CenteredEmptyState(
                                systemImage: "server.rack",
                                title: "暂无接入配置",
                                message: "点击右上角添加，或刷新以加载本机 CPA"
                            )
                            .frame(minHeight: 180)
                        }
                    } else {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredProfiles) { profile in
                            providerCard(profile)
                        }
                    }
                    }
                }
            }
            .padding(AppDesign.pagePadding)
            .frame(maxWidth: AppDesign.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private var agentSummaryCard: some View {
        GlassCard(padding: 18) {
            HStack(spacing: 16) {
                    Image(systemName: selectedAgent.systemImage)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 46, height: 46)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(selectedAgent.title)
                            .font(.headline)
                        Text(selectedAgent.liveConfigPathHint)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                        if let liveHint {
                            Label(liveHint.replacingOccurrences(of: "live：", with: ""), systemImage: "circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 16)

                    Menu {
                        Button {
                            launchSelectedAgent()
                        } label: {
                            Label("打开终端", systemImage: "play.fill")
                        }
                        Button {
                            importLiveProfile()
                        } label: {
                            Label("导入当前 live 配置", systemImage: "square.and.arrow.down.on.square")
                        }
                        Button {
                            editorTarget = .new(agent: selectedAgent)
                        } label: {
                            Label("添加接入配置", systemImage: "plus")
                        }
                    } label: {
                        Label("更多", systemImage: "ellipsis.circle")
                    }
            }
        }
    }

    /// What `~/.codex/config.toml` actually says, so the switch can't imply a state the file lacks.
    @ViewBuilder
    private var codexBucketStatus: some View {
        let pinned = codexLiveBucket == CodexStableProvider.id
        let color: Color = pinned ? .green : .orange
        let text: String = {
            if pinned {
                return "已生效：~/.codex/config.toml 的 model_provider = \(CodexStableProvider.id)"
            }
            let current = codexLiveBucket ?? "未设置"
            guard AgentLiveConfigWriter.canRepinOfficialCodexBucket() else {
                return "未生效：model_provider = \(current)，指向第三方 provider。改桶会让它已有的历史对不上，"
                    + "启用一个 Codex 接入配置即可进入共享桶。"
            }
            return "当前会话库：\(current)。可点击下方按钮改用共享库。"
        }()
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var codexSettingsCard: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Text("会话历史").font(.headline)
                Toggle("下次应用官方接入时也使用共享会话库", isOn: Binding(
                    get: { settings.unifyCodexSessionHistory },
                    set: { setUnify($0) }
                ))
                Text("此策略在应用接入配置时生效，不会立即修改当前配置或旧会话。自定义接入始终使用 custom 会话库；官方接入可选择共享或官方 openai 会话库。")
                    .font(.caption).foregroundStyle(.secondary)
                codexBucketStatus
                HStack {
                    Button("当前官方配置改用共享库") {
                        do {
                            try pinCodexSessionBucket()
                            codexLiveBucket = AgentLiveConfigWriter.codexLiveProviderID()
                            appState.flash("当前配置已使用共享会话库")
                        } catch { appState.flash(error.localizedDescription, error: true) }
                    }
                    .disabled(!AgentLiveConfigWriter.canRepinOfficialCodexBucket())
                    Button("迁移已有官方会话…") { setMigrateExisting(true) }
                    if CodexSessionUnifier.hasOfficialUnifyBackup() {
                        Button("撤销已有会话迁移…") { restoreMigratedSessions() }
                    }
                }
                Toggle("启动时自动迁移官方旧会话", isOn: Binding(
                    get: { appState.guiConfig.snapshot().codexSessionRepairOnLaunch },
                    set: { value in
                        _ = try? appState.guiConfig.update { $0.codexSessionRepairOnLaunch = value }
                    }
                ))
                .disabled(!settings.unifyCodexSessionHistory)
                .help("需启用共享库策略，且 Codex 未运行时才会执行；修改会话前备份。")
                Button("清理加密思考…") { sanitizeEncryptedThinking() }
                    .help("备份后清理绑定原上游的加密思考记录，避免恢复会话时签名错误。")
                Text("迁移、撤销迁移和清理均是独立操作；修改前会备份，Codex 运行中拒绝执行。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Explains a per-Provider switch that lives in the editor, because its effect is invisible
    /// from the outside: nothing in Codex reports which compaction it chose.
    @ViewBuilder
    private var codexRemoteCompactionNote: some View {
        let live = profiles.first { $0.id == currentProviderID && $0.agent == .codex }
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.caption)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("远程压缩：由服务端压缩上下文，Codex 只在 model_providers 的 name 等于 OpenAI 时才启用，在自定义接入配置中设置；官方接入自动使用官方能力。")
                Text(remoteCompactionStateText(live))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func remoteCompactionStateText(_ profile: AgentProviderProfile?) -> String {
        let live = AgentLiveConfigReader.read(agent: .codex)
        guard live.configExists, live.readable else { return "尚未读取到有效的 Codex 配置。" }
        let official = (live.endpoint ?? "").isEmpty
            && (live.providerID == nil || live.providerID == "openai")
        let configured = official || live.providerName == CodexStableProvider.openAIProviderName
        let status = configured ? "已配置服务端压缩；端点能力尚未验证。" : "当前配置未启用服务端压缩。"
        return status + " CPA 同名模型来源：" + appState.guiConfig.snapshot().overlappingModelPolicy.title
    }

    private func providerCard(_ profile: AgentProviderProfile) -> some View {
        let isCurrent = currentProviderID == profile.id
        let iconName: String = {
            if profile.isDefault { return "arrow.uturn.backward.circle.fill" }
            if profile.isOfficial { return "shield.checkmark.fill" }
            if profile.isLocalCPA { return "bolt.horizontal.circle.fill" }
            return "server.rack"
        }()
        let endpointText: String = {
            if profile.isDefault {
                return "启用前的配置快照（可随时切回）"
            }
            if profile.isOfficial {
                return profile.agent == .claude
                    ? "Anthropic 官方直连（无代理端点）"
                    : "OpenAI 官方直连（ChatGPT OAuth）"
            }
            return profile.endpoint.isEmpty ? "未配置 Endpoint" : profile.endpoint
        }()

        return GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: iconName)
                        .font(.title3)
                        .foregroundStyle(isCurrent ? Color.green : (profile.isOfficial ? Color.purple : Color.secondary))
                        .frame(width: 38, height: 38)
                        .background(
                            (isCurrent ? Color.green : (profile.isOfficial ? Color.purple : Color.secondary)).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 10)
                        )

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(profile.name)
                                .font(.headline)
                            if profile.isDefault {
                                Text("快照")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                            if profile.isOfficial {
                                Text("官方")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.purple.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.purple)
                            }
                            if profile.isLocalCPA {
                                Text("CPA")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.blue)
                            }
                            if isCurrent {
                                Text("配置匹配")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.green)
                            }
                        }
                        Text(endpointText)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                        if let summary = modelSummary(profile) {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if profile.isDefault {
                        Menu {
                            Button("删除快照", role: .destructive) {
                                pendingDeleteProfile = profile
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                    } else if profile.isOfficial {
                        // Built-in official profile is fixed: no edit/delete menu
                    } else if profile.isLocalCPA {
                        Menu {
                            Button("编辑模型映射") {
                                editorTarget = .edit(profile)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                    } else {
                        Menu {
                            Button("编辑") {
                                editorTarget = .edit(profile)
                            }
                            Divider()
                            Button("删除", role: .destructive) {
                                pendingDeleteProfile = profile
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                    }

                    if isCurrent {
                        Button { enable(profile) } label: {
                            Label("重新应用", systemImage: "checkmark.circle.fill")
                                .frame(minWidth: 72)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy)
                    } else {
                        Button {
                            enable(profile)
                        } label: {
                            Label("应用配置", systemImage: "checkmark.circle")
                                .frame(minWidth: 72)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy)
                    }
                }

                if profile.isLocalCPA && profile.agent == .codex {
                    Button {
                        pendingFixCodexDesktopModels = true
                    } label: {
                        Label("修复 Codex Desktop 自定义模型…", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy)
                    .help("删除 Desktop 缓存的登录态和全局状态，再写入 CPA 的 auth.json")
                }
            }
        }
    }

    // MARK: - Sessions

    private var sessionsPane: some View {
        VStack(spacing: 0) {
            sessionToolbar
                .padding(.horizontal, AppDesign.pagePadding)
                .padding(.vertical, 12)

            Divider().opacity(0.35)

            if filteredSessions.isEmpty {
                CenteredEmptyState(
                    systemImage: "bubble.left.and.bubble.right",
                    title: "没有会话",
                    message: "使用对应 CLI 产生对话后，可在此浏览与恢复"
                )
            } else {
                ScrollView {
                    VStack(spacing: AppDesign.pageStackSpacing) {
                        ForEach(AgentKind.allCases) { agent in
                            let records = filteredSessions.filter { $0.agent == agent }
                            if !records.isEmpty {
                                sessionGroup(agent, records: records)
                            }
                        }
                    }
                    .padding(AppDesign.pagePadding)
                    .frame(maxWidth: AppDesign.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var sessionToolbar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                sessionFilterChip(nil, title: "全部", systemImage: "square.grid.2x2")
                ForEach(AgentKind.allCases) { agent in
                    sessionFilterChip(agent, title: agent.title, systemImage: agent.systemImage)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索标题、项目路径或会话 ID", text: $sessionQuery)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

                Text("\(filteredSessions.count) 条")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: AppDesign.contentMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private func sessionFilterChip(_ agent: AgentKind?, title: String, systemImage: String) -> some View {
        let selected = sessionAgentFilter == agent
        return Button {
            sessionAgentFilter = agent
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    selected ? Color.accentColor : Color.secondary.opacity(0.12),
                    in: Capsule()
                )
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var filteredSessions: [AgentSessionRecord] {
        sessions.filter { session in
            if let sessionAgentFilter, session.agent != sessionAgentFilter { return false }
            let q = sessionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty { return true }
            let hay = [session.title, session.projectPath ?? "", session.id, session.filePath, session.modelProvider ?? ""]
                .joined(separator: " ")
                .lowercased()
            return hay.contains(q.lowercased())
        }
    }

    private func sessionGroup(_ agent: AgentKind, records: [AgentSessionRecord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(agent.title, systemImage: agent.systemImage)
                    .font(.headline)
                Text("\(records.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            LazyVStack(spacing: 10) {
                ForEach(records) { session in
                    sessionCard(session)
                }
            }
        }
    }

    private func sessionCard(_ session: AgentSessionRecord) -> some View {
        GlassCard(padding: 16) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: session.agent.systemImage)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(session.title)
                            .font(.headline)
                            .lineLimit(1)
                        if let provider = session.modelProvider, !provider.isEmpty {
                            Text(provider)
                                .font(.caption2.monospaced())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let path = session.projectPath {
                        Text(path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                    Text(session.id.replacingOccurrences(of: "\(session.agent.rawValue):", with: ""))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                Text(relativeDate(session.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Menu {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.filePath, forType: .string)
                        appState.flash("已复制会话文件路径")
                    } label: {
                        Label("复制文件路径", systemImage: "doc.on.doc")
                    }
                    Divider()
                    Button(role: .destructive) {
                        pendingDeleteSession = session
                    } label: {
                        Label("删除会话", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)

                Button {
                    resume(session)
                } label: {
                    Label("恢复", systemImage: "play.fill")
                        .frame(minWidth: 72)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.resumeCommand == nil)
            }
        }
    }

    // MARK: - Actions

    private func reloadAll() {
        isBusy = true
        defer { isBusy = false }
        let gui = appState.guiConfig.snapshot()
        let key = gui.apiKeys.first?.apiKey ?? ""
        profiles = (try? AgentProviderStore.ensureLocalCPAProfiles(port: gui.port, apiKey: key)) ?? AgentProviderStore.loadProfiles()
        settings = AgentProviderStore.loadSettings()

        // "当前" always reflects the live config: clear it when the file was edited or removed.
        var changed = false
        for agent in AgentKind.allCases {
            let matched = AgentLiveConfigReader.matchingProfileID(
                agent: agent,
                in: profiles,
                preferring: settings.currentProviderID(for: agent)
            )
            if settings.currentProviderID(for: agent) != matched {
                settings.setCurrentProviderID(matched, for: agent)
                changed = true
            }
        }
        if changed {
            try? AgentProviderStore.saveSettings(settings)
        }

        codexLiveBucket = AgentLiveConfigWriter.codexLiveProviderID()
        sessions = AgentSessionService.listSessions()
    }

    private func modelSummary(_ profile: AgentProviderProfile) -> String? {
        var parts = profile.agent.modelRoles.compactMap { role -> String? in
            let value = profile.model(for: role)
            return value.isEmpty ? nil : "\(role.title(for: profile.agent)) \(value)"
        }
        if profile.agent == .codex {
            let count = profile.resolvedCodexCatalogModels.count
            if count > 1 {
                parts.append("catalog \(count) 个模型")
            }
            let levels = AgentReasoningEffort.options(agent: .codex, modelID: profile.model)
            if !levels.isEmpty {
                parts.append("档位 \(levels.joined(separator: "/"))")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func currentAPIKey() -> String {
        appState.guiConfig.snapshot().apiKeys.first?.apiKey ?? ""
    }

    private func defaultEndpoint(for agent: AgentKind) -> String {
        let port = appState.guiConfig.snapshot().port
        switch agent {
        case .claude: return "http://127.0.0.1:\(port)"
        case .codex: return "http://127.0.0.1:\(port)/v1"
        }
    }

    private func launchSelectedAgent() {
        do {
            try AgentSessionService.launch(selectedAgent)
            appState.flash("已启动 \(selectedAgent.title)")
        } catch {
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func importLiveProfile() {
        guard let imported = AgentLiveConfigReader.importAsProfile(agent: selectedAgent) else {
            appState.flash("当前 live 配置缺少 endpoint 或 API Key，无法导入", error: true)
            return
        }
        // Avoid duplicating Local CPA / identical endpoint+key.
        if let existing = profiles.first(where: {
            $0.agent == selectedAgent
                && AgentLiveConfigReader.normalizeComparableEndpoint($0.endpoint, agent: selectedAgent)
                == AgentLiveConfigReader.normalizeComparableEndpoint(imported.endpoint, agent: selectedAgent)
                && $0.apiKey == imported.apiKey
        }) {
            appState.flash("已存在相同接入配置：\(existing.name)")
            return
        }
        saveProfile(imported)
    }

    private func enable(_ profile: AgentProviderProfile) {
        isBusy = true
        defer { isBusy = false }
        do {
            var next = profile
            if next.isLocalCPA {
                let gui = appState.guiConfig.snapshot()
                let key = gui.apiKeys.first?.apiKey ?? ""
                guard !key.isEmpty else { throw AppError("请先在配置页添加 API Key") }
                // Refresh endpoint/key from GUI config but keep the user's model mapping.
                let fresh = AgentProviderProfile.localCPA(agent: profile.agent, port: gui.port, apiKey: key)
                next.endpoint = fresh.endpoint
                next.apiKey = fresh.apiKey
                profiles = try AgentProviderStore.upsert(next)
            }
            let hadDefaultBefore = profiles.contains(where: { $0.agent == next.agent && $0.isDefault })
            try AgentLiveConfigWriter.enable(next, settings: settings)
            // captureIfNeeded may have inserted 「接管前配置」
            profiles = AgentProviderStore.loadProfiles()
            settings.setCurrentProviderID(next.id, for: next.agent)
            try AgentProviderStore.saveSettings(settings)
            let createdDefault = !hadDefaultBefore
                && !next.isDefault
                && profiles.contains(where: { $0.agent == next.agent && $0.isDefault })
            let suffix = createdDefault ? "（已保存启用前配置为「接管前配置」）" : ""
            codexLiveBucket = AgentLiveConfigWriter.codexLiveProviderID()
            appState.flash("已启用 \(next.name) → \(next.agent.title)\(suffix)")
        } catch {
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func saveProfile(_ profile: AgentProviderProfile) {
        do {
            var next = profile
            // Local CPA: refresh endpoint/key from GUI, keep model mapping / overrides.
            if next.isLocalCPA {
                let gui = appState.guiConfig.snapshot()
                let key = gui.apiKeys.first?.apiKey ?? next.apiKey
                guard !key.isEmpty else { throw AppError("请先在配置页添加 API Key") }
                let fresh = AgentProviderProfile.localCPA(agent: next.agent, port: gui.port, apiKey: key)
                next.endpoint = fresh.endpoint
                next.apiKey = fresh.apiKey
            }
            profiles = try AgentProviderStore.upsert(next)

            let liveID = settings.currentProviderID(for: next.agent)
            let isLive = !next.isDefault && liveID == next.id
            if isLive {
                // Same path as 「启用」so catalog / live files always rewrite.
                try AgentLiveConfigWriter.enable(next, settings: settings)
                profiles = AgentProviderStore.loadProfiles()
                reloadAll()
                appState.flash("已保存 \(next.name)，并同步到 \(next.agent.liveConfigPathHint)")
                } else {
                appState.flash("已保存 \(next.name)")
            }
        } catch {
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func deleteProfile(_ profile: AgentProviderProfile) {
        do {
            // Deleting the live provider leaves the agent pointed at a profile that no longer
            // exists, so roll the live files back to the pre-takeover snapshot first.
            let wasLive = !profile.isDefault
                && settings.currentProviderID(for: profile.agent) == profile.id
            let hasSnapshot = profiles.contains { $0.agent == profile.agent && $0.isDefault }
            var rollbackNote = ""
            var isWarning = false
            if wasLive, hasSnapshot {
                if let backup = profiles.first(where: { $0.agent == profile.agent && $0.isDefault }) {
                    try AgentLiveConfigWriter.enable(backup, settings: settings)
                }
                rollbackNote = "，\(profile.agent.liveConfigPathHint) 已还原为「接管前配置」"
            } else if wasLive {
                rollbackNote = "，但没有「接管前配置」快照可还原，\(profile.agent.liveConfigPathHint) 仍是它的配置"
                isWarning = true
            }
            profiles = try AgentProviderStore.delete(id: profile.id)
            settings = AgentProviderStore.loadSettings()
            reloadAll()
            appState.flash("已删除 \(profile.name)\(rollbackNote)", error: isWarning)
        } catch {
            appState.flash(error.localizedDescription, error: true)
        }
    }

    /// Point `~/.codex/config.toml` at the shared `custom` bucket.
    ///
    /// This only ever has work to do for Codex's own default config. Every Provider we write
    /// lands in `custom` already (see `mergeCodex`), so the setting exists for the one config
    /// we don't author: the official backend, which would otherwise write into `openai`.
    private func pinCodexSessionBucket() throws {
        try AgentLiveConfigWriter.repinOfficialCodexBucket()
        let landed = AgentLiveConfigWriter.codexLiveProviderID()
        codexLiveBucket = landed
        guard landed == CodexStableProvider.id else {
            throw AppError(
                "~/.codex/config.toml 的 model_provider 是 \(landed ?? "未设置")，指向第三方 provider。"
                + "改桶会让它已有的历史对不上，因此未改动；启用一个 Codex 接入配置即可进入共享桶。"
            )
        }
    }

    /// Checking 「迁移已有 openai 会话」 runs the migration right away.
    ///
    /// Storing the flag alone would leave the old sessions where they are until the next unify
    /// toggle, which reads as a no-op checkbox.
    private func setMigrateExisting(_ enabled: Bool) {
        do {
            let result = try CodexSessionUnifier.migrateOfficialSessionsToCustom()
            sessions = AgentSessionService.listSessions()
            appState.flash("已迁移旧会话：\(result.jsonlRewritten) 个文件、\(result.sqliteUpdated) 条索引")
        } catch { appState.flash(error.localizedDescription, error: true) }
    }

    private func restoreMigratedSessions() {
        do {
            let result = try CodexSessionUnifier.restoreOfficialSessionsFromBackups()
            sessions = AgentSessionService.listSessions()
            appState.flash("已撤销旧会话迁移：\(result.jsonlRestored) 个文件、\(result.sqliteRestored) 条索引；当前接入配置不变")
        } catch { appState.flash(error.localizedDescription, error: true) }
    }

    private func setUnify(_ enabled: Bool) {
        let previous = settings
        settings.unifyCodexSessionHistory = enabled
        settings.migrateCodexSessionsOnUnify = false
        settings.restoreCodexSessionsOnDisableUnify = false
        do {
            try AgentProviderStore.saveSettings(settings)
            appState.flash("会话库策略已保存，下次应用接入配置时生效")
        } catch {
            settings = previous
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func sanitizeEncryptedThinking() {
        do {
            let result = try CodexEncryptedContentSanitizer.sanitizeLocalSessions()
            if result.filesTouched == 0 {
                appState.flash("没有需要清理的加密思考项")
            } else {
                let backup = result.backupDirectory.map { "；备份：\($0)" } ?? ""
                appState.flash(
                    "已清理加密思考：\(result.filesTouched) 个文件，去掉 \(result.linesRemoved) 行\(backup)"
                )
            }
            sessions = AgentSessionService.listSessions()
        } catch {
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func fixCodexDesktopCustomModels() {
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try CodexCPAAuthFile.repairDesktopCustomModels()
            if result.removed.isEmpty {
                appState.flash("已写入 CPA auth.json，请重启 Codex Desktop")
            } else {
                appState.flash(
                    "已删除 \(result.removed.joined(separator: "、"))，并写入 CPA auth.json。请重启 Codex Desktop"
                )
            }
        } catch {
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func resume(_ session: AgentSessionRecord) {
        do {
            try AgentSessionService.resume(session)
            appState.flash("已在终端恢复会话")
        } catch {
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func deleteSession(_ session: AgentSessionRecord) {
        do {
            try AgentSessionService.delete(session)
            sessions = AgentSessionService.listSessions()
            appState.flash("已删除会话")
        } catch {
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Editor

/// `sheet(item:)` payload — with `sheet(isPresented:)` the content closure captures the
/// view value from before the tap, so editing an existing provider saved a new one.
private struct AgentEditorTarget: Identifiable {
    let id: String
    let agent: AgentKind
    let profile: AgentProviderProfile?

    static func new(agent: AgentKind) -> AgentEditorTarget {
        AgentEditorTarget(id: "new-\(agent.rawValue)", agent: agent, profile: nil)
    }

    static func edit(_ profile: AgentProviderProfile) -> AgentEditorTarget {
        AgentEditorTarget(id: profile.id, agent: profile.agent, profile: profile)
    }
}

private struct AgentProviderEditorSheet: View {
    let agent: AgentKind
    let existing: AgentProviderProfile?
    let defaultEndpoint: String
    let defaultAPIKey: String
    var onSave: (AgentProviderProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var endpoint = ""
    @State private var apiKey = ""
    @State private var models: [AgentModelRole: String] = [:]
    @State private var catalogModels: [String] = []
    @State private var modelOverrides: [String: AgentModelOverride] = [:]
    @State private var notes = ""
    @State private var catalog: [AgentModelCatalogService.Model] = []
    @State private var isFetching = false
    @State private var catalogError: String?
    @State private var claimsOpenAIProvider = false
    @State private var codexSubscriptionOnly = false

    private var isLocalCPA: Bool { existing?.isLocalCPA ?? false }

    /// Catalog entries we know reach an upstream without `/responses/compact`.
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

    @ViewBuilder
    private var supportedEffortHint: some View {
        if AgentModelCapabilityEditor.hasEditableCapabilities(agent) {
            AgentModelCapabilityEditor(
                agent: agent,
                modelID: effortModelID,
                modelOverrides: $modelOverrides
            )
        }
        Text("实际使用的档位请在 \(agent.title) 里调整；启用接入配置不会改写当前思考强度。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    /// Codex decides remote-vs-local compaction once, from the provider name, and never revisits
    /// it — so the switch is paired with the routing guard that keeps its models on an upstream
    /// that can actually serve `/responses/compact`.
    @ViewBuilder
    private var remoteCompactionSection: some View {
        Section {
            Toggle(isOn: $claimsOpenAIProvider) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("远程压缩（写 name = \"OpenAI\"）")
                    Text("Codex 只认 model_providers 里的 name 是否等于 OpenAI 来决定能否远程压缩。开启后由服务端压缩上下文，官方订阅下对长会话质量提升明显。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if claimsOpenAIProvider, !uncompactableModels.isEmpty {
                Label(
                    "这些模型的上游没有 /responses/compact：\(uncompactableModels.joined(separator: "、"))。Codex 远程压缩失败不会退回本地压缩，会话会一直不压缩直到超出上下文。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else if claimsOpenAIProvider {
                Text("服务端必须支持 /responses/compact。经 CPA 接入时，请在「配置 → 同名模型」选择全局来源策略；优先级不会保证压缩端点可用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("远程压缩")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "添加接入配置" : "编辑接入配置")
                .font(.title3.weight(.semibold))
            Text(agent.title)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let existing, AgentProviderStore.loadSettings().currentProviderID(for: agent) == existing.id {
                Text("保存会立即更新本机客户端配置。运行中的客户端是否已重新加载需另行确认。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Form {
                Section {
                    TextField("名称", text: $name)
                        .disabled(isLocalCPA)
                    TextField("Endpoint", text: $endpoint)
                        .disabled(isLocalCPA)
                    SecureField("API Key", text: $apiKey)
                        .disabled(isLocalCPA)
                    TextField("备注", text: $notes)
                        .disabled(isLocalCPA)
                } footer: {
                    if isLocalCPA {
                        Text("本机 CPA 的 Endpoint 与 API Key 跟随配置页，这里只调整模型映射。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                        if agent == .claude {
                            supportedEffortHint
                        }
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
                        .disabled(isFetching || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } footer: {
                    if let catalogError {
                        Text(catalogError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if catalog.isEmpty {
                        Text(modelMappingFooter)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(catalogSummary(catalog))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if agent == .codex {
                    remoteCompactionSection
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 580)
        .onAppear {
            if let existing {
                name = existing.name
                endpoint = existing.endpoint
                apiKey = existing.apiKey
                notes = existing.notes
                for role in AgentModelRole.allCases {
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
                name = "自定义"
                endpoint = defaultEndpoint
                apiKey = defaultAPIKey
                catalogModels = []
                modelOverrides = [:]
            }
        }
    }

    private var modelMappingFooter: String {
        switch agent {
        case .claude:
            return "留空表示不写入该字段，由 Claude Code 自己决定默认模型。勾选「1M 上下文」会在模型名后追加 [1M]（Haiku 无 1M 变体）。点「获取模型」可从 Endpoint 拉列表。"
        case .codex:
            return "可配置多个模型写入 catalog；其中一个为默认（config.toml model）。点「获取模型」从 Endpoint 拉列表，再「添加全部已获取」或逐个添加。"
        }
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
                    let resolutions = AgentModelCatalogService.routingResolutions(from: AppPaths.coreConfigURL)
                    Menu {
                        Button("不指定（不写入配置）") { binding.wrappedValue = "" }
                        Divider()
                        ForEach(AgentModelCatalogService.groups(catalog)) { group in
                            Section(group.title) {
                                ForEach(group.models, id: \.identity) { model in
                                    Button(AgentModelCatalogService.menuRowLabel(
                                        modelID: model.id, resolutions: resolutions
                                    )) {
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

    private func fetchCatalog() {
        isFetching = true
        catalogError = nil
        let target = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let ids = try await AgentModelCatalogService.fetch(endpoint: target, apiKey: key)
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

    private func catalogSummary(_ models: [AgentModelCatalogService.Model]) -> String {
        let groups = AgentModelCatalogService.groups(models)
        let parts = groups.map { group in
            let gpt = group.models.filter { $0.id.lowercased().hasPrefix("gpt-") }.count
            let gptPart = gpt > 0 ? "，其中 GPT \(gpt)" : ""
            return "\(group.title) \(group.models.count)\(gptPart)"
        }
        return "已获取 \(models.count) 个 · " + parts.joined(separator: "；")
    }

    private func commit() {
        let now = Date()
        func value(_ role: AgentModelRole) -> String {
            (models[role] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let modelMappings = Dictionary(
            uniqueKeysWithValues: [.sonnet, .opus, .haiku, .fable, .subagent].map {
                ($0.rawValue, value($0))
            }
        )
        let mainModel = value(.main)
        var savedCatalog = catalogModels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if agent == .codex, !mainModel.isEmpty, !savedCatalog.contains(mainModel) {
            savedCatalog.append(mainModel)
        }
        let profile = AgentProviderProfile(
            id: existing?.id ?? UUID().uuidString,
            agent: agent,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: mainModel,
            fastModel: value(.haiku),
            webSearchModel: value(.webSearch),
            modelMappings: modelMappings,
            catalogModels: agent == .codex ? savedCatalog : [],
            modelOverrides: modelOverrides,
            reasoningEffort: "",
            claimsOpenAIProvider: agent == .codex && claimsOpenAIProvider,
            codexSubscriptionOnly: agent == .codex && codexSubscriptionOnly,
            isLocalCPA: isLocalCPA,
            isDefault: existing?.isDefault ?? false,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        onSave(profile)
        dismiss()
    }
}
