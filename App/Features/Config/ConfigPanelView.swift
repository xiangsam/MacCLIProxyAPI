import AppKit
import SwiftUI

/// 配置页：网络预览 + 密钥列表 + 路由策略卡片，分区填满内容区。
struct ConfigPanelView: View {
    @Environment(AppState.self) private var appState

    @State private var segment: Segment = .network
    @State private var portText: String = ""
    @State private var allowLan = false
    @State private var routingStrategy = "round-robin"
    @State private var proxyUrl = ""
    @State private var sessionAffinity = false
    @State private var sessionTTL = ""
    @State private var excludeCodexOverlappingModels = false
    @State private var optimizeCodexMultiAgentV2 = true
    @State private var showAddKey = false
    @State private var newKeyValue = ""
    @State private var newKeyRemark = ""
    @State private var revealKeyIDs: Set<String> = []
    @State private var pendingDeleteKey: GuiApiKey?

    private enum Segment: String, CaseIterable, Identifiable {
        case network
        case keys
        case routing

        var id: String { rawValue }

        var title: String {
            switch self {
            case .network: return "网络"
            case .keys: return "密钥"
            case .routing: return "路由"
            }
        }

        var icon: String {
            switch self {
            case .network: return "network"
            case .keys: return "key.fill"
            case .routing: return "arrow.triangle.branch"
            }
        }
    }

    var body: some View {
        ListPageScaffold {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    ForEach(Segment.allCases) { item in
                        segmentChip(item)
                    }
                    Spacer()
                    if segment == .keys {
                        Button {
                            showAddKey = true
                        } label: {
                            Label("添加密钥", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        } bodyContent: {
            Group {
                switch segment {
                case .network:
                    networkPane
                case .keys:
                    keysPane
                case .routing:
                    routingPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle("配置")
        .sheet(isPresented: $showAddKey) {
            addKeySheet
        }
        .confirmDestructive(
            $pendingDeleteKey,
            title: "删除 API Key？",
            confirmLabel: { _ in "删除密钥" },
            message: { _ in deleteKeyConfirmationMessage },
            action: { appState.deleteAPIKey($0.apiKey) }
        )
        .onAppear(perform: load)
        .onChange(of: segment) { _, _ in
            load()
        }
    }

    private func segmentChip(_ item: Segment) -> some View {
        let selected = segment == item
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { segment = item }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                Text(item.title)
                    .fontWeight(selected ? .semibold : .regular)
                if item == .keys {
                    Text("\(appState.configSettings.apiKeys.count)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            (selected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.15)),
                            in: Capsule()
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                selected ? Color.accentColor : Color.secondary.opacity(0.12),
                in: Capsule()
            )
            .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Network

    private var networkPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 等高双卡：较高一侧决定行高，两侧 maxHeight 拉满
                HStack(alignment: .top, spacing: 16) {
                    networkForm
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    networkPreview
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .fixedSize(horizontal: false, vertical: true)

                networkTips
            }
            .padding(.bottom, 16)
        }
    }

    private var networkForm: some View {
        GlassCard(padding: 22, fillHeight: true) {
            VStack(alignment: .leading, spacing: 20) {
                Label("监听设置", systemImage: "network")
                    .font(.title3.weight(.semibold))

                VStack(alignment: .leading, spacing: 8) {
                    Text("端口")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("8317", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                        .frame(maxWidth: 160)
                }

                Divider()

                Toggle(isOn: $allowLan) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("允许局域网访问")
                            .font(.body.weight(.medium))
                        Text(allowLan
                              ? "其他设备可通过 \(appState.lanIPv4 ?? "局域网 IP") 连接"
                              : "仅本机 127.0.0.1 可访问")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Spacer(minLength: 12)

                Button {
                    guard let port = UInt16(portText), port > 0 else {
                        appState.flash("端口无效", error: true)
                        return
                    }
                    appState.saveNetwork(port: port, allowLan: allowLan)
                } label: {
                    Label("保存网络设置", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                        .frame(height: AppDesign.controlHeight)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var networkPreview: some View {
        let port = UInt16(portText) ?? appState.configSettings.port
        let host = allowLan ? (appState.lanIPv4 ?? "127.0.0.1") : "127.0.0.1"

        return GlassCard(padding: 22, fillHeight: true) {
            VStack(alignment: .leading, spacing: 16) {
                Label("连接预览", systemImage: "eye")
                    .font(.title3.weight(.semibold))

                previewLine(title: "Base URL", value: "http://\(host):\(port)")
                previewLine(title: "OpenAI", value: "http://\(host):\(port)/v1")
                previewLine(title: "作用域", value: allowLan ? "局域网 + 本机" : "仅本机")

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Image(systemName: allowLan ? "wifi" : "lock.fill")
                        .foregroundStyle(allowLan ? Color.blue : Color.secondary)
                    Text(allowLan ? "局域网模式" : "本机锁定")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: AppDesign.controlHeight + 8, alignment: .leading)
                .background(
                    (allowLan ? Color.blue : Color.secondary).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func previewLine(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .textSelection(.enabled)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var networkTips: some View {
        GlassCard(padding: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("修改端口或局域网后需重启内核生效")
                        .font(.subheadline.weight(.medium))
                    Text("客户端请使用上方预览地址，并配置对应 API Key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Keys

    private var keysPane: some View {
        Group {
            if appState.configSettings.apiKeys.isEmpty {
                CenteredEmptyState(
                    systemImage: "key.slash",
                    title: "暂无 API Key",
                    message: "客户端调用本地代理时需要携带密钥",
                    actionTitle: "添加密钥"
                ) {
                    showAddKey = true
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        HStack {
                            Text("共 \(appState.configSettings.apiKeys.count) 个密钥")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        ForEach(appState.configSettings.apiKeys) { key in
                            keyCard(key)
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func keyCard(_ key: GuiApiKey) -> some View {
        let revealed = revealKeyIDs.contains(key.id)
        return GlassCard(padding: 16) {
            HStack(spacing: 14) {
                Image(systemName: "key.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .frame(width: 40, height: 40)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(revealed ? key.apiKey : maskKey(key.apiKey))
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .textSelection(.enabled)
                        .lineLimit(1)
                    if key.remark.isEmpty {
                        Text("无备注")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(key.remark)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                Button {
                    if revealed {
                        revealKeyIDs.remove(key.id)
                    } else {
                        revealKeyIDs.insert(key.id)
                    }
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealed ? "隐藏" : "显示")

                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key.apiKey, forType: .string)
                    appState.flash("已复制")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("删除", role: .destructive) {
                    pendingDeleteKey = key
                }
                .controlSize(.small)
            }
        }
    }

    private var addKeySheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加 API Key")
                .font(.title3.weight(.semibold))

            TextField("密钥内容", text: $newKeyValue)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            TextField("备注（可选）", text: $newKeyRemark)
                .textFieldStyle(.roundedBorder)

            Text("可自定义密钥，或随机生成一串安全值")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let msg = appState.lastActionMessage, appState.lastActionIsError {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            HStack {
                Button("随机生成") {
                    if appState.addAPIKey(remark: newKeyRemark) {
                        newKeyRemark = ""
                        newKeyValue = ""
                        showAddKey = false
                    }
                }
                Spacer()
                Button("取消") { showAddKey = false }
                Button("添加") {
                    if appState.addAPIKey(value: newKeyValue, remark: newKeyRemark) {
                        newKeyValue = ""
                        newKeyRemark = ""
                        showAddKey = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newKeyValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 280)
    }

    // MARK: - Routing

    private var routingPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GlassCard(padding: 20) {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("路由策略", systemImage: "arrow.triangle.branch")
                            .font(.title3.weight(.semibold))

                        HStack(spacing: 12) {
                            strategyCard(
                                id: "round-robin",
                                title: "轮询",
                                subtitle: "round-robin",
                                detail: "在可用账号间均匀分配请求",
                                icon: "arrow.triangle.2.circlepath"
                            )
                            strategyCard(
                                id: "fill-first",
                                title: "优先填满",
                                subtitle: "fill-first",
                                detail: "优先用满当前账号再切换",
                                icon: "arrow.down.to.line.compact"
                            )
                        }
                    }
                }

                GlassCard(padding: 20) {
                    VStack(alignment: .leading, spacing: 18) {
                        Label("兼容修复与上游", systemImage: "checkmark.shield")
                            .font(.title3.weight(.semibold))

                        VStack(alignment: .leading, spacing: 6) {
                            Text("上游代理 URL")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                            TextField("可选，例如 http://127.0.0.1:7890", text: $proxyUrl)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                GlassCard(padding: 20) {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Session Affinity", systemImage: "link")
                            .font(.title3.weight(.semibold))

                        Toggle(isOn: $sessionAffinity) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("会话亲和")
                                Text("同一会话尽量落到同一上游账号；开启后会覆盖 fill-first 优先级")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)

                        if sessionAffinity {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("TTL")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                                TextField("例如 30s / 30m / 1h", text: $sessionTTL)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 220)
                                Text("需带单位；纯数字会按秒处理（30 → 30s）")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }

                GlassCard(padding: 20) {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("同名模型", systemImage: "arrow.triangle.branch")
                            .font(.title3.weight(.semibold))

                        Toggle(isOn: $excludeCodexOverlappingModels) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("GPT 同名模型完全不走 Codex 订阅")
                                Text("默认关闭：同名 GPT 的 API Provider 优先级更高时会优先命中它，失败才掉落订阅。开启后写入 oauth-excluded-models，该 Provider 不可用时直接 503。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }

                GlassCard(padding: 20) {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Codex 多智能体", systemImage: "person.3")
                            .font(.title3.weight(.semibold))

                        Toggle(isOn: $optimizeCodexMultiAgentV2) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("优化多智能体请求")
                                Text("默认开启：把 agent_message 里的明文 encrypted_content 改写成 input_text，并去掉协作工具的加密标记，避免子代理回写污染会话后重试失败。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }

                Button {
                    appState.saveRouting(
                        strategy: routingStrategy,
                        proxyUrl: proxyUrl,
                        sessionAffinity: sessionAffinity,
                        sessionTTL: sessionTTL,
                        excludeCodexOverlappingModels: excludeCodexOverlappingModels,
                        optimizeCodexMultiAgentV2: optimizeCodexMultiAgentV2
                    )
                } label: {
                    Label("保存路由设置", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text(
                    appState.coreRunning
                        ? "保存后会自动重启内核，进行中的请求会中断。"
                        : "保存后写入 config.yaml，下次启动内核生效。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.bottom, 16)
        }
    }

    private func strategyCard(
        id: String,
        title: String,
        subtitle: String,
        detail: String,
        icon: String
    ) -> some View {
        let selected = routingStrategy == id
        return Button {
            routingStrategy = id
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.45))
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                selected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06),
                                lineWidth: selected ? 1.5 : 1
                            )
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func load() {
        appState.refreshConfigSettings()
        appState.refreshStatus()
        let settings = appState.configSettings
        portText = String(settings.port)
        allowLan = settings.allowLan
        routingStrategy = settings.routingStrategy
        proxyUrl = settings.proxyUrl
        sessionAffinity = settings.routingSessionAffinity
        sessionTTL = settings.routingSessionAffinityTtl
        excludeCodexOverlappingModels = settings.routingExcludeCodexOverlappingModels
        optimizeCodexMultiAgentV2 = settings.optimizeCodexMultiAgentV2
    }

    private func maskKey(_ key: String) -> String {
        guard key.count > 10 else { return String(repeating: "•", count: max(key.count, 6)) }
        return String(key.prefix(4)) + String(repeating: "•", count: 8) + String(key.suffix(4))
    }

    private var deleteKeyConfirmationMessage: String {
        guard let key = pendingDeleteKey else { return "" }
        let remark = key.remark.isEmpty ? maskKey(key.apiKey) : key.remark
        if appState.configSettings.apiKeys.count == 1 {
            return "「\(remark)」是最后一个 API Key。删除后所有客户端请求都会失去可用密钥。"
        }
        return "确认删除「\(remark)」？同步到内核后，使用该密钥的客户端会被拒绝。"
    }
}
