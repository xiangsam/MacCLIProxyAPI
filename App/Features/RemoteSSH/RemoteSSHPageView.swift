import AppKit
import SwiftUI

struct RemoteSSHPageView: View {
    @Environment(AppState.self) private var appState

    @State private var hosts: [RemoteSSHHost] = []
    @State private var selectedID: String?
    @State private var editorTarget: RemoteSSHHost?
    @State private var showSSHImport = false
    @State private var selectedAgent: AgentKind = .codex
    @State private var providerState = RemoteAgentProviderStore.State.empty
    @State private var providerEditor: ProviderEditorTarget?
    @State private var isBusy = false
    @State private var lastApplySummary = ""
    @State private var pendingDelete: RemoteSSHHost?
    @State private var pendingDeleteProvider: AgentProviderProfile?
    @State private var pendingRemoteWrite: RemoteWrite?
    @State private var pendingCodexRestart: RemoteSSHHost?

    /// A change that only takes effect once files on the remote host are overwritten over SSH.
    private enum RemoteWrite {
        case enable(AgentProviderProfile, RemoteSSHHost)
        case pushLive(AgentProviderProfile, RemoteSSHHost)
        case unifyHistory(RemoteSSHHost)
        case migrateSessions(RemoteSSHHost)

        var isUnifyHistory: Bool {
            if case .unifyHistory = self { return true }
            return false
        }

        var isMigrateSessions: Bool {
            if case .migrateSessions = self { return true }
            return false
        }
    }

    private struct ProviderEditorTarget: Identifiable, Equatable {
        var host: RemoteSSHHost
        var agent: AgentKind
        var profile: AgentProviderProfile?
        var id: String { "\(host.id)-\(agent.rawValue)-\(profile?.id ?? "new")" }
    }

    private var selectedHost: RemoteSSHHost? {
        hosts.first(where: { $0.id == selectedID }) ?? hosts.first
    }

    private var filteredProviders: [AgentProviderProfile] {
        providerState.profiles
            .filter { $0.agent == selectedAgent }
            .sorted(by: AgentProviderStore.providerSort)
    }

    var body: some View {
        ListPageScaffold {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("远程 SSH")
                        .font(.title3.weight(.semibold))
                    Text("配置 SSH 主机，用 Provider 列表切换远程 Claude / Codex（与本地智能体相同）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .help("正在通过 SSH 操作远程主机…")
                }
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isBusy)
                .help("刷新主机列表")
                Button {
                    showSSHImport = true
                } label: {
                    Label("从 SSH 导入", systemImage: "square.and.arrow.down")
                }
                .disabled(isBusy)
                .help("读取 ~/.ssh/config 中的 Host")
                Button {
                    editorTarget = RemoteSSHHost.makeNew()
                } label: {
                    Label("添加主机", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }
        } bodyContent: {
            if hosts.isEmpty {
                GlassCard {
                    VStack(spacing: 16) {
                        CenteredEmptyState(
                            systemImage: "network.badge.shield.half.filled",
                            title: "尚未配置远程主机",
                            message: "从 ~/.ssh/config 导入，或手动添加主机后一键写入远程智能体配置"
                        )
                        .frame(minHeight: 180)
                        HStack(spacing: 10) {
                            Button {
                                showSSHImport = true
                            } label: {
                                Label("从 SSH 导入", systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(.borderedProminent)
                            Button {
                                editorTarget = RemoteSSHHost.makeNew()
                            } label: {
                                Label("手动添加", systemImage: "plus")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    hostList
                        .frame(width: 260)
                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .navigationTitle("远程 SSH")
        .onAppear(perform: reload)
        .sheet(item: $editorTarget) { host in
            RemoteSSHHostEditorSheet(host: host) { saved in
                saveHost(saved)
            }
        }
        .sheet(isPresented: $showSSHImport) {
            SSHConfigImportSheet(existingHosts: hosts) { result in
                hosts = result.hosts
                if let first = result.hosts.first, selectedID == nil || !result.hosts.contains(where: { $0.id == selectedID }) {
                    selectedID = first.id
                }
                if result.imported > 0 {
                    appState.flash("已导入 \(result.imported) 台主机" + (result.skipped > 0 ? "（跳过 \(result.skipped) 台已存在）" : ""))
                } else if result.skipped > 0 {
                    appState.flash("所选主机均已存在，未导入新项")
                }
                reloadProviders()
            }
        }
        .sheet(item: $providerEditor) { target in
            RemoteAgentProviderEditorSheet(
                host: target.host,
                agent: target.agent,
                existing: target.profile
            ) { saved in
                saveProvider(saved, host: target.host)
            }
        }
        .confirmDestructive(
            $pendingDelete,
            title: "删除远程主机？",
            confirmLabel: { _ in "删除" },
            message: { "将删除「\($0.name)」（\($0.displayTarget)），不影响该主机上的文件。" },
            action: deleteHost
        )
        .confirmDestructive(
            $pendingDeleteProvider,
            title: "删除远程 Provider？",
            confirmLabel: { _ in "删除" },
            message: deleteRemoteProviderWarning,
            action: { profile in
                guard let host = selectedHost else { return }
                deleteProvider(profile, host: host)
            }
        )
        .confirmDestructive(
            $pendingRemoteWrite,
            title: "将修改远程主机上的文件",
            confirmLabel: remoteWriteLabel,
            message: remoteWriteWarning,
            action: performRemoteWrite
        )
        .confirmDestructive(
            $pendingCodexRestart,
            title: "重启远程 Codex 服务？",
            confirmLabel: { _ in "重启" },
            message: { host in
                "「\(host.name)」上的 codex app-server 在启动时读过一次模型列表，之后一直没变，"
                    + "所以 /model 还是切换前的那份。重启会结束当前的远程 Codex 会话，下次连接时自动拉起。"
            },
            action: restartRemoteCodexAppServer
        )
        .onChange(of: selectedID) { _, _ in
            reloadProviders()
        }
    }

    // MARK: - Host list

    private var hostList: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("主机")
                    .font(.headline)
                ForEach(hosts) { host in
                    Button {
                        selectedID = host.id
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "server.rack")
                                .foregroundStyle(selectedHost?.id == host.id ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(host.displayTarget)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if let ok = host.lastTestOK {
                                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(ok ? Color.green : Color.red)
                                    .font(.caption)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            selectedHost?.id == host.id
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let host = selectedHost {
            ScrollView {
                VStack(alignment: .leading, spacing: AppDesign.pageStackSpacing) {
                    hostSummaryCard(host)
                    remoteAgentPicker
                    if selectedAgent == .codex {
                        remoteCodexSettingsCard(host)
                        remoteCompactionNote
                    }
                    providersCard(host)
                    if !lastApplySummary.isEmpty {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("最近操作")
                                    .font(.headline)
                                Text(lastApplySummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }

    private var remoteAgentPicker: some View {
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
    }

    private func hostSummaryCard(_ host: RemoteSSHHost) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(host.name)
                            .font(.title3.weight(.semibold))
                        Text(host.displayTarget + (host.port == 22 ? "" : ":\(host.port)"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("编辑") {
                        editorTarget = host
                    }
                    .disabled(isBusy)
                    Button("删除", role: .destructive) {
                        pendingDelete = host
                    }
                    .disabled(isBusy)
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("私钥").foregroundStyle(.secondary)
                        Text(host.identityFile.isEmpty ? "默认 / ssh-agent" : host.identityFile)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    GridRow {
                        Text("CPA 可达地址").foregroundStyle(.secondary)
                        Text(cpaReachableDisplay(for: host))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    if !host.notes.isEmpty {
                        GridRow {
                            Text("备注").foregroundStyle(.secondary)
                            Text(host.notes)
                                .font(.caption)
                        }
                    }
                    if let tested = host.lastTestedAt {
                        GridRow {
                            Text("上次测试").foregroundStyle(.secondary)
                            Text("\(host.lastTestOK == true ? "成功" : "失败") · \(tested.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                        }
                    }
                }
                .font(.subheadline)

                HStack {
                    Button {
                        testHost(host)
                    } label: {
                        Label("测试连接", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(isBusy)
                    Spacer()
                }
            }
        }
    }

    /// Explains a per-Provider switch that lives in the editor, because its effect is invisible
    /// from the outside: nothing in Codex reports which compaction it chose.
    @ViewBuilder
    private var remoteCompactionNote: some View {
        let live = providerState.profiles.first {
            $0.id == providerState.currentProviderID(for: .codex) && $0.agent == .codex
        }
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.caption)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("远程压缩：由服务端压缩上下文，Codex 只在 model_providers 的 name 等于 OpenAI 时才启用，逐个 Provider 在编辑里开。")
                Text(remoteCompactionStateText(live))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func remoteCompactionStateText(_ live: AgentProviderProfile?) -> String {
        guard let live else { return "此主机当前没有启用中的 Codex Provider。" }
        guard live.claimsOpenAIProvider else {
            return "当前「\(live.name)」未开启，走 Codex 自带的本地压缩。"
        }
        return live.codexSubscriptionOnly
            ? "当前「\(live.name)」已开启，且同名 GPT 模型已在本机 CPA 隔离到 Codex 订阅。"
            : "当前「\(live.name)」已开启；未隔离同名模型，压缩可能落到没有压缩端点的上游。"
    }

    private func remoteCodexSettingsCard(_ host: RemoteSSHHost) -> some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("统一会话历史")
                            .font(.headline)
                        Text("把远程 ~/.codex/config.toml 的 model_provider 固定为 custom。本应用写入的 Provider 本来就在 custom 桶，这个开关针对的是远端 Codex 自带的默认配置（含「默认」Provider）——它原本写进 openai 桶。关闭只停止迁移，不会改回 openai。「迁移已有」会把远程 openai 旧会话改标签并入同一桶（SSH 拉取→本机改写→写回，备份在本机）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        // Reading the pending write keeps the switch on the position the user
                        // just chose, and snaps it back if they cancel.
                        get: {
                            pendingRemoteWrite?.isUnifyHistory == true
                                || providerState.unifyCodexSessionHistory
                        },
                        set: { enabled in
                            // Turning it off changes nothing on the host, so it needs no dialog.
                            if enabled {
                                pendingRemoteWrite = .unifyHistory(host)
                            } else {
                                setRemoteUnify(host, enabled: false)
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(isBusy)
                }
                Divider().opacity(0.4)
                HStack(spacing: 20) {
                    Toggle("迁移已有 openai 会话", isOn: Binding(
                        get: {
                            pendingRemoteWrite?.isMigrateSessions == true
                                || providerState.migrateCodexSessionsOnUnify
                        },
                        set: { enabled in
                            // Only ticking it rewrites remote session files.
                            if enabled, providerState.unifyCodexSessionHistory {
                                pendingRemoteWrite = .migrateSessions(host)
                            } else {
                                setRemoteMigrate(host, enabled: enabled)
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(isBusy || !providerState.unifyCodexSessionHistory)
                    Spacer()
                }
                .font(.caption)
            }
        }
    }

    private func providersCard(_ host: RemoteSSHHost) -> some View {
        let currentID = providerState.currentProviderID(for: selectedAgent)
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Provider")
                        .font(.headline)
                    Text("\(filteredProviders.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        providerEditor = .init(host: host, agent: selectedAgent, profile: nil)
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    .disabled(isBusy)
                }

                Text("与本地智能体相同：点「启用」切换远程配置。首次启用非「默认」会把远端现有文件存为「默认」；每次写入还会在 ~/.maccliproxy-agent-backups/ 留时间戳备份。多次配置可随时切回「默认」或其它 Provider。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                prerequisitesHint

                if filteredProviders.isEmpty {
                    CenteredEmptyState(
                        systemImage: "server.rack",
                        title: "暂无 Provider",
                        message: "刷新或测试连接后会自动加入本机 CPA；也可手动添加"
                    )
                    .frame(minHeight: 120)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredProviders) { profile in
                            remoteProviderCard(profile, host: host, isCurrent: currentID == profile.id)
                        }
                    }
                }
            }
        }
    }

    private func remoteProviderCard(
        _ profile: AgentProviderProfile,
        host: RemoteSSHHost,
        isCurrent: Bool
    ) -> some View {
        let iconName: String = {
            if profile.isDefault { return "arrow.uturn.backward.circle.fill" }
            if profile.isOfficial { return "shield.checkmark.fill" }
            if profile.isLocalCPA { return "bolt.horizontal.circle.fill" }
            return "server.rack"
        }()
        let endpointText: String = {
            if profile.isDefault { return "启用前的远程配置快照" }
            if profile.isOfficial {
                return profile.agent == .claude
                    ? "Anthropic 官方直连（无代理端点）"
                    : "OpenAI 官方直连（ChatGPT OAuth）"
            }
            return profile.endpoint.isEmpty ? "（无 Endpoint）" : profile.endpoint
        }()

        return HStack(alignment: .center, spacing: 14) {
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
                        Text("默认")
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
                        Text("当前")
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

            Spacer(minLength: 8)

            if profile.isDefault {
                Menu {
                    Button("删除快照", role: .destructive) {
                        pendingDeleteProvider = profile
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .disabled(isBusy)
            } else if profile.isOfficial {
                // Built-in official profile is fixed: no edit/delete menu
            } else {
                Menu {
                    Button(profile.isLocalCPA ? "编辑模型映射" : "编辑") {
                        providerEditor = .init(host: host, agent: selectedAgent, profile: profile)
                    }
                    if !profile.isLocalCPA {
                        Divider()
                        Button("删除", role: .destructive) {
                            pendingDeleteProvider = profile
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .disabled(isBusy)
            }

            if isCurrent {
                Button {} label: {
                    Label("已启用", systemImage: "checkmark.circle.fill")
                        .frame(minWidth: 72)
                }
                .buttonStyle(.bordered)
                .disabled(true)
            } else {
                Button {
                    pendingRemoteWrite = .enable(profile, host)
                } label: {
                    Label("启用", systemImage: "checkmark.circle")
                        .frame(minWidth: 72)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var prerequisitesHint: some View {
        let gui = appState.guiConfig.snapshot()
        let hasKey = !(gui.apiKeys.first?.apiKey ?? "").isEmpty
        let allowLan = gui.allowLan
        return VStack(alignment: .leading, spacing: 4) {
            Label(
                hasKey ? "已配置 API Key" : "请先在配置页添加 API Key",
                systemImage: hasKey ? "checkmark.circle" : "exclamationmark.triangle"
            )
            .foregroundStyle(hasKey ? Color.secondary : Color.orange)
            Label(
                allowLan
                    ? "局域网访问已开启（\(appState.lanIPv4 ?? "检测中…")）"
                    : "建议开启局域网访问，或手动填写「远程访问 CPA 地址」",
                systemImage: allowLan ? "checkmark.circle" : "info.circle"
            )
            .foregroundStyle(allowLan ? Color.secondary : Color.orange)
        }
        .font(.caption)
    }

    private func modelSummary(_ profile: AgentProviderProfile) -> String? {
        if profile.isDefault { return nil }
        if profile.agent == .codex {
            let main = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let catalog = profile.resolvedCodexCatalogModels
            if main.isEmpty, catalog.isEmpty { return nil }
            if catalog.isEmpty { return "模型 \(main)" }
            if main.isEmpty { return "目录 \(catalog.count) 个模型" }
            return "模型 \(main) · 目录 \(catalog.count)"
        }
        let parts = profile.agent.modelRoles.compactMap { role -> String? in
            let value = profile.model(for: role).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            if profile.agent.modelRoles.count == 1 { return value }
            return "\(role.title(for: profile.agent)): \(value)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func reload() {
        hosts = RemoteSSHStore.loadHosts()
        if selectedID == nil || !hosts.contains(where: { $0.id == selectedID }) {
            selectedID = hosts.first?.id
        }
        appState.lanIPv4 = localLANIPv4()
        reloadProviders()
    }

    private func reloadProviders() {
        guard let host = selectedHost else {
            providerState = .empty
            return
        }
        for agent in AgentKind.allCases where RemoteAgentDefaultSnapshot.hasSnapshot(hostID: host.id, agent: agent) {
            _ = try? RemoteAgentProviderStore.ensureDefaultProfile(hostID: host.id, agent: agent)
        }
        _ = try? RemoteAgentProviderStore.ensureOfficialProfiles(hostID: host.id)
        let gui = appState.guiConfig.snapshot()
        let key = gui.apiKeys.first?.apiKey ?? ""
        if !key.isEmpty,
           let cpaHost = try? RemoteAgentConfigurator.resolveCPAReachableHost(
               sshHost: host,
               lanIPv4: appState.lanIPv4 ?? localLANIPv4(),
               allowLan: gui.allowLan
           )
        {
            _ = try? RemoteAgentProviderStore.ensureLocalCPAProfiles(
                hostID: host.id,
                cpaHost: cpaHost,
                cpaPort: gui.port,
                apiKey: key
            )
        }
        providerState = RemoteAgentProviderStore.load(hostID: host.id)
    }

    private func saveHost(_ host: RemoteSSHHost) {
        do {
            var next = host
            next.updatedAt = Date()
            hosts = try RemoteSSHStore.upsert(next)
            selectedID = next.id
            reloadProviders()
            appState.flash("已保存 \(next.name)")
        } catch {
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func deleteHost(_ host: RemoteSSHHost) {
        do {
            hosts = try RemoteSSHStore.delete(id: host.id)
            RemoteAgentProviderStore.deleteHostData(hostID: host.id)
            if selectedID == host.id {
                selectedID = hosts.first?.id
            }
            reloadProviders()
            appState.flash("已删除 \(host.name)")
        } catch {
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func testHost(_ host: RemoteSSHHost) {
        guard !isBusy else { return }
        isBusy = true
        Task.detached(priority: .userInitiated) {
            do {
                let result = try RemoteSSHClient.testConnection(host)
                var updated = host
                updated.lastTestedAt = Date()
                updated.lastTestOK = result.succeeded
                updated.lastTestMessage = result.combinedOutput
                updated.updatedAt = Date()
                let saved = try RemoteSSHStore.upsert(updated)
                await MainActor.run {
                    self.hosts = saved
                    self.reloadProviders()
                    self.isBusy = false
                    if result.succeeded {
                        self.appState.flash("SSH 连接成功：\(host.displayTarget)")
                    } else {
                        self.appState.flash(
                            result.combinedOutput.isEmpty
                                ? "SSH 连接失败（exit \(result.exitCode)）"
                                : result.combinedOutput,
                            error: true
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.appState.flash(error.localizedDescription, error: true)
                }
            }
        }
    }

    private func enableProvider(_ profile: AgentProviderProfile, on host: RemoteSSHHost) {
        guard !isBusy else { return }
        isBusy = true
        let gui = appState.guiConfig.snapshot()
        let lan = appState.lanIPv4 ?? localLANIPv4()
        let apiKey = gui.apiKeys.first?.apiKey ?? ""
        let hadDefaultBefore = providerState.profiles.contains {
            $0.agent == profile.agent && $0.isDefault
        }
        let hostID = host.id
        let hostName = host.name
        let shouldUnify = providerState.unifyCodexSessionHistory
        let shouldMigrate = profile.agent == .codex
            && shouldUnify
            && providerState.migrateCodexSessionsOnUnify
            && !profile.isDefault

        Task.detached(priority: .userInitiated) {
            do {
                var next = profile
                if next.isLocalCPA {
                    guard !apiKey.isEmpty else { throw AppError("请先在配置页添加 API Key") }
                    let cpaHost = try RemoteAgentConfigurator.resolveCPAReachableHost(
                        sshHost: host,
                        lanIPv4: lan,
                        allowLan: gui.allowLan
                    )
                    let refreshed = try RemoteAgentProviderStore.ensureLocalCPAProfiles(
                        hostID: hostID,
                        cpaHost: cpaHost,
                        cpaPort: gui.port,
                        apiKey: apiKey
                    )
                    if let latest = refreshed.profiles.first(where: { $0.id == next.id }) {
                        next = latest
                    }
                }

                let result = try RemoteAgentConfigurator.enable(
                    profile: next,
                    sshHost: host,
                    cpaPort: gui.port,
                    apiKey: apiKey,
                    lanIPv4: lan,
                    allowLan: gui.allowLan,
                    unifyCodexSessionHistory: shouldUnify
                )

                var migrateNote = ""
                if shouldMigrate {
                    let migrated = try RemoteCodexSessionUnifier.migrateOfficialSessionsToCustom(sshHost: host)
                    if migrated.jsonlRewritten == 0, migrated.sqliteUpdated == 0 {
                        migrateNote = "；远程会话无需迁移"
                    } else {
                        migrateNote =
                            "；已迁移远程会话 \(migrated.jsonlRewritten) 文件 / \(migrated.sqliteUpdated) 索引"
                    }
                }

                if !next.isDefault {
                    _ = try? RemoteAgentProviderStore.ensureDefaultProfile(hostID: hostID, agent: next.agent)
                }
                _ = try RemoteAgentProviderStore.setCurrent(
                    hostID: hostID,
                    agent: next.agent,
                    providerID: next.id
                )
                let loaded = RemoteAgentProviderStore.load(hostID: hostID)
                let createdDefault = !hadDefaultBefore
                    && !next.isDefault
                    && loaded.profiles.contains { $0.agent == next.agent && $0.isDefault }
                let suffix = createdDefault ? "（已保存启用前配置为「默认」）" : ""
                let summary = "\(result.message)\(migrateNote)\n→ \(result.remotePath)"

                let applied = next
                await MainActor.run {
                    self.providerState = loaded
                    self.lastApplySummary = summary
                    self.isBusy = false
                    self.appState.flash("\(hostName)：已启用 \(next.name) → \(next.agent.title)\(suffix)\(migrateNote)")
                    if result.codexAppServerHoldsStaleCatalog {
                        self.pendingCodexRestart = host
                    }
                }
                await self.appState.syncCodexSubscriptionIsolation(for: applied)
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.appState.flash(error.localizedDescription, error: true)
                }
            }
        }
    }

    private func setRemoteUnify(_ host: RemoteSSHHost, enabled: Bool) {
        do {
            let migrate = enabled ? providerState.migrateCodexSessionsOnUnify : false
            providerState = try RemoteAgentProviderStore.updateCodexHistorySettings(
                hostID: host.id,
                unify: enabled,
                migrate: migrate
            )
            guard enabled else {
                appState.flash("已关闭远程统一会话历史：远程 live 配置仍写入 custom 桶，仅不再迁移 openai 旧会话")
                return
            }
            pinRemoteCodexSessionBucket(host, thenMigrate: migrate)
        } catch {
            appState.flash(error.localizedDescription, error: true)
        }
    }

    /// Point the remote Codex config at the shared `custom` bucket, then verify.
    ///
    /// Same shape as the local page: only Codex's own default config needs this, because every
    /// Provider we write already lands in `custom`. So this edits `model_provider` in place
    /// rather than re-pushing a whole Provider, and needs no enabled Provider to work.
    private func pinRemoteCodexSessionBucket(_ host: RemoteSSHHost, thenMigrate: Bool) {
        guard !isBusy else { return }
        isBusy = true
        let hostID = host.id
        let hostName = host.name

        Task.detached(priority: .userInitiated) {
            do {
                try RemoteAgentConfigurator.repinOfficialCodexBucket(sshHost: host)
                let landed = try RemoteAgentConfigurator.remoteCodexProviderID(sshHost: host)
                guard landed == CodexStableProvider.id else {
                    throw AppError(
                        "远程 ~/.codex/config.toml 的 model_provider 是 \(landed ?? "未设置")，指向第三方 provider。"
                        + "改桶会让它已有的历史对不上，因此未改动；在此主机启用一个 Codex Provider 即可进入共享桶。"
                    )
                }

                var migrateNote = ""
                if thenMigrate {
                    let migrated = try RemoteCodexSessionUnifier.migrateOfficialSessionsToCustom(sshHost: host)
                    if migrated.jsonlRewritten == 0, migrated.sqliteUpdated == 0 {
                        migrateNote = "；远程没有需要迁移的 openai 会话"
                    } else {
                        migrateNote =
                            "；已迁移远程会话 \(migrated.jsonlRewritten) 文件 / \(migrated.sqliteUpdated) 索引"
                    }
                }

                await MainActor.run {
                    self.isBusy = false
                    self.lastApplySummary = "远程 model_provider = \(CodexStableProvider.id)\(migrateNote)"
                    self.appState.flash(
                        "\(hostName)：已固定远程新会话到 \(CodexStableProvider.id) 桶\(migrateNote)"
                    )
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    // Keep the toggle in sync with what actually happened on the host.
                    self.providerState = (try? RemoteAgentProviderStore.updateCodexHistorySettings(
                        hostID: hostID,
                        unify: false,
                        migrate: false
                    )) ?? self.providerState
                    self.appState.flash(error.localizedDescription, error: true)
                }
            }
        }
    }

    private func setRemoteMigrate(_ host: RemoteSSHHost, enabled: Bool) {
        do {
            providerState = try RemoteAgentProviderStore.updateCodexHistorySettings(
                hostID: host.id,
                unify: providerState.unifyCodexSessionHistory,
                migrate: enabled
            )
            if enabled, providerState.unifyCodexSessionHistory {
                runRemoteMigrate(host)
            } else {
                appState.flash(enabled ? "已勾选迁移已有会话" : "已取消迁移已有会话")
            }
        } catch {
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func runRemoteMigrate(_ host: RemoteSSHHost) {
        guard !isBusy else { return }
        isBusy = true
        let hostName = host.name
        let hostID = host.id
        let unify = providerState.unifyCodexSessionHistory
        Task.detached(priority: .userInitiated) {
            do {
                let result = try RemoteCodexSessionUnifier.migrateOfficialSessionsToCustom(sshHost: host)
                let message: String
                if result.jsonlRewritten == 0, result.sqliteUpdated == 0 {
                    message = "\(hostName)：远程没有需要迁移的 openai 会话"
                } else {
                    let backup = result.backupDirectory.map { "；本机备份：\($0)" } ?? ""
                    message =
                        "\(hostName)：已迁移远程会话 \(result.jsonlRewritten) 文件 / \(result.sqliteUpdated) 索引\(backup)"
                }
                await MainActor.run {
                    self.isBusy = false
                    self.lastApplySummary = message
                    self.appState.flash(message)
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    // Migration failed, so the checkbox must not keep claiming it is on.
                    self.providerState = (try? RemoteAgentProviderStore.updateCodexHistorySettings(
                        hostID: hostID,
                        unify: unify,
                        migrate: false
                    )) ?? self.providerState
                    self.appState.flash(error.localizedDescription, error: true)
                }
            }
        }
    }

    // MARK: - Remote write confirmation

    private func deleteRemoteProviderWarning(_ profile: AgentProviderProfile) -> String {
        guard let host = selectedHost else { return "将删除「\(profile.name)」" }
        guard !profile.isDefault else {
            return "「默认」保存的是接管前 \(host.name) 上的 \(profile.agent.liveConfigPathHint)。"
                + "删除快照后将无法再把该主机还原到那份配置。"
        }
        guard providerState.currentProviderID(for: profile.agent) == profile.id else {
            return "仅删除应用内保存的这套接入配置，不改动 \(host.name)。"
        }
        let hasSnapshot = RemoteAgentDefaultSnapshot.hasSnapshot(hostID: host.id, agent: profile.agent)
        return hasSnapshot
            ? "「\(profile.name)」正在 \(host.name) 上生效，删除后会通过 SSH 把该主机还原为「默认」快照。"
            : "「\(profile.name)」正在 \(host.name) 上生效，且没有「默认」快照可还原，"
                + "删除后该主机仍保留它写入的配置。"
    }

    private func remoteWriteLabel(_ write: RemoteWrite) -> String {
        switch write {
        case let .enable(profile, _):
            return profile.isDefault ? "还原为默认" : "启用并写入"
        case .pushLive:
            return "同步到远程"
        case .unifyHistory:
            return "开启并写入"
        case .migrateSessions:
            return "开始迁移"
        }
    }

    private func remoteWriteWarning(_ write: RemoteWrite) -> String {
        switch write {
        case let .enable(profile, host):
            let path = profile.agent.liveConfigPathHint
            return profile.isDefault
                ? "将通过 SSH 把 \(host.name) 的 \(path) 还原为接管前的快照，覆盖当前内容。"
                    + "写入前会在远端留一份带时间戳的备份。"
                : "将通过 SSH 用「\(profile.name)」覆盖 \(host.name) 的 \(path)。"
                    + "写入前会在远端留一份带时间戳的备份。"
        case let .pushLive(profile, host):
            return "「\(profile.name)」正在 \(host.name) 上生效，改动会立即覆盖该主机的 "
                + "\(profile.agent.liveConfigPathHint)。取消则只保存在本机，远程保持原样。"
        case let .unifyHistory(host):
            return "将通过 SSH 把 \(host.name) 的 ~/.codex/config.toml 中 model_provider 改为 custom。"
        case let .migrateSessions(host):
            return "将拉取 \(host.name) 上的 openai 旧会话，改写标签后写回并更新远程会话索引。"
                + "备份保存在本机。"
        }
    }

    private func performRemoteWrite(_ write: RemoteWrite) {
        switch write {
        case let .enable(profile, host):
            enableProvider(profile, on: host)
        case let .pushLive(profile, host):
            pushLiveProvider(profile, host: host)
        case let .unifyHistory(host):
            setRemoteUnify(host, enabled: true)
        case let .migrateSessions(host):
            setRemoteMigrate(host, enabled: true)
        }
    }

    private func saveProvider(_ profile: AgentProviderProfile, host: RemoteSSHHost) {
        do {
            providerState = try RemoteAgentProviderStore.upsert(hostID: host.id, profile: profile)
            let isLive = !profile.isDefault
                && providerState.currentProviderID(for: profile.agent) == profile.id
            guard isLive else {
                appState.flash("已保存 \(profile.name)")
                return
            }
            // Saved locally either way; overwriting the host is a separate, confirmed step.
            pendingRemoteWrite = .pushLive(profile, host)
        } catch {
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func restartRemoteCodexAppServer(_ host: RemoteSSHHost) {
        guard !isBusy else { return }
        isBusy = true
        Task.detached(priority: .userInitiated) {
            do {
                let stopped = try RemoteAgentConfigurator.stopCodexAppServer(sshHost: host)
                await MainActor.run {
                    self.isBusy = false
                    self.appState.flash(
                        stopped
                            ? "已重启远程 Codex 服务，下次连接会读取新的模型列表"
                            : "远程 Codex 服务未在运行，下次连接即读取新的模型列表"
                    )
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.appState.flash(error.localizedDescription, error: true)
                }
            }
        }
    }

    private func pushLiveProvider(_ profile: AgentProviderProfile, host: RemoteSSHHost) {
        guard !isBusy else { return }
        isBusy = true
        let gui = appState.guiConfig.snapshot()
        let lan = appState.lanIPv4 ?? localLANIPv4()
        let apiKey = gui.apiKeys.first?.apiKey ?? ""
        Task.detached(priority: .userInitiated) {
            do {
                let result = try RemoteAgentConfigurator.enable(
                    profile: profile,
                    sshHost: host,
                    cpaPort: gui.port,
                    apiKey: apiKey,
                    lanIPv4: lan,
                    allowLan: gui.allowLan
                )
                let summary = "\(result.message)\n→ \(result.remotePath)"
                await MainActor.run {
                    self.lastApplySummary = summary
                    self.isBusy = false
                    self.appState.flash("已保存 \(profile.name)，并同步到远程 \(profile.agent.title)")
                    if result.codexAppServerHoldsStaleCatalog {
                        self.pendingCodexRestart = host
                    }
                }
                await self.appState.syncCodexSubscriptionIsolation(for: profile)
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.appState.flash(error.localizedDescription, error: true)
                }
            }
        }
    }

    private func deleteProvider(_ profile: AgentProviderProfile, host: RemoteSSHHost) {
        // Deleting the live provider would leave the remote agent pointed at a profile that no
        // longer exists here, so restore the 「默认」 snapshot over SSH before dropping it.
        let wasLive = !profile.isDefault
            && providerState.currentProviderID(for: profile.agent) == profile.id
        let hasSnapshot = RemoteAgentDefaultSnapshot.hasSnapshot(hostID: host.id, agent: profile.agent)
        do {
            providerState = try RemoteAgentProviderStore.delete(hostID: host.id, id: profile.id)
        } catch {
            appState.flash(error.localizedDescription, error: true)
            return
        }
        guard wasLive else {
            appState.flash("已删除 \(profile.name)")
            return
        }
        guard hasSnapshot, !isBusy else {
            appState.flash(
                "已删除 \(profile.name)，但没有可还原的「默认」快照，远程 \(profile.agent.title) 仍是它的配置",
                error: true
            )
            return
        }
        isBusy = true
        let agent = profile.agent
        let name = profile.name
        let unify = providerState.unifyCodexSessionHistory
        Task.detached(priority: .userInitiated) {
            do {
                let result = try RemoteAgentConfigurator.restoreDefault(
                    agent: agent,
                    sshHost: host,
                    unifyCodexSessionHistory: unify
                )
                await MainActor.run {
                    self.isBusy = false
                    self.lastApplySummary = "\(result.message)\n→ \(result.remotePath)"
                    self.appState.flash("已删除 \(name)，远程 \(agent.title) 已还原为「默认」")
                }
            } catch {
                await MainActor.run {
                    self.isBusy = false
                    self.appState.flash(
                        "已删除 \(name)，但还原远程「默认」失败：\(error.localizedDescription)",
                        error: true
                    )
                }
            }
        }
    }

    private func cpaReachableDisplay(for host: RemoteSSHHost) -> String {
        let explicit = host.cpaReachableHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        if let lan = appState.lanIPv4, !lan.isEmpty {
            return "\(lan)（自动局域网）"
        }
        return "未设置"
    }
}

// MARK: - Import from ~/.ssh/config

private struct SSHConfigImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    let existingHosts: [RemoteSSHHost]
    let onImported: ((hosts: [RemoteSSHHost], imported: Int, skipped: Int)) -> Void

    @State private var entries: [SSHConfigHostEntry] = []
    @State private var selectedIDs: Set<String> = []
    @State private var query = ""
    @State private var loadError = ""

    private var filtered: [SSHConfigHostEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.alias.lowercased().contains(q)
                || $0.hostName.lowercased().contains(q)
                || $0.user.lowercased().contains(q)
                || $0.displayTarget.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("从 ~/.ssh/config 导入")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("导入 \(selectedIDs.count) 台") { importSelected() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedIDs.isEmpty)
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                TextField("搜索 Host / 主机名 / 用户", text: $query)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("全选") {
                        selectedIDs = Set(filtered.map(\.id))
                    }
                    .disabled(filtered.isEmpty)
                    Button("清除") {
                        selectedIDs.removeAll()
                    }
                    .disabled(selectedIDs.isEmpty)
                    Spacer()
                    Text("\(entries.count) 个可导入 Host")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !loadError.isEmpty {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if filtered.isEmpty {
                    ContentUnavailableView(
                        entries.isEmpty ? "未找到 Host" : "无匹配项",
                        systemImage: "magnifyingglass",
                        description: Text(entries.isEmpty
                            ? "~/.ssh/config 中没有可导入的具体 Host（已忽略 * 与通配符）"
                            : "换个关键词试试")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered, selection: $selectedIDs) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: alreadyImported(entry) ? "checkmark.circle.fill" : "server.rack")
                                .foregroundStyle(alreadyImported(entry) ? Color.green : Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.alias)
                                    .font(.subheadline.weight(.semibold))
                                Text(entry.displayTarget + (entry.port == 22 ? "" : ":\(entry.port)"))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    Text(entry.source)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    if alreadyImported(entry) {
                                        Text("已导入")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    }
                                    if !entry.identityFile.isEmpty {
                                        Text((entry.identityFile as NSString).lastPathComponent)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        .tag(entry.id)
                    }
                    .listStyle(.inset)
                }
            }
            .padding()
        }
        .frame(width: 560, height: 520)
        .onAppear(perform: reload)
    }

    private func alreadyImported(_ entry: SSHConfigHostEntry) -> Bool {
        let candidate = entry.toRemoteSSHHost()
        return existingHosts.contains {
            $0.name == candidate.name
                && $0.host == candidate.host
                && $0.username == candidate.username
                && $0.port == candidate.port
        }
    }

    private func reload() {
        let loaded = SSHConfigReader.loadImportableHosts()
        entries = loaded
        let configURL = SSHConfigReader.defaultConfigURL
        if !FileManager.default.fileExists(atPath: configURL.path) {
            loadError = "未找到 ~/.ssh/config"
        } else if loaded.isEmpty {
            loadError = "~/.ssh/config 中没有可导入的具体 Host（已忽略 * 与通配符）"
        } else {
            loadError = ""
        }
        selectedIDs = Set(loaded.filter { !alreadyImported($0) }.map(\.id))
    }

    private func importSelected() {
        let chosen = entries.filter { selectedIDs.contains($0.id) }
        guard !chosen.isEmpty else { return }
        do {
            let result = try RemoteSSHStore.importEntries(chosen)
            onImported(result)
            dismiss()
        } catch {
            appState.flash(error.localizedDescription, error: true)
        }
    }
}

// MARK: - Editor

private struct RemoteSSHHostEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: RemoteSSHHost
    let onSave: (RemoteSSHHost) -> Void

    init(host: RemoteSSHHost, onSave: @escaping (RemoteSSHHost) -> Void) {
        _draft = State(initialValue: host)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(draft.name.isEmpty ? "编辑主机" : draft.name)
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()

            Divider()

            Form {
                Section("基本信息") {
                    TextField("名称", text: $draft.name)
                    TextField("主机 / IP", text: $draft.host)
                    TextField("用户名", text: $draft.username)
                    TextField("端口", value: $draft.port, format: .number)
                }
                Section("认证") {
                    HStack {
                        TextField("私钥路径（可选）", text: $draft.identityFile)
                        Button("选择…") { pickIdentity() }
                    }
                    Text("留空则使用 ssh-agent 或默认密钥（~/.ssh/id_*）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("CPA 可达性") {
                    TextField("远程访问本机 CPA 的地址", text: $draft.cpaReachableHost)
                    Text("留空则使用本机局域网 IP（需在配置页开启局域网访问）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("备注") {
                    TextField("备注", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .formStyle(.grouped)
            .padding(.bottom, 8)
        }
        .frame(width: 520, height: 520)
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.port > 0
    }

    private func save() {
        guard canSave else { return }
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.identityFile = draft.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.cpaReachableHost = draft.cpaReachableHost.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(draft)
        dismiss()
    }

    private func pickIdentity() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        panel.message = "选择 SSH 私钥"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.identityFile = url.path
    }
}
