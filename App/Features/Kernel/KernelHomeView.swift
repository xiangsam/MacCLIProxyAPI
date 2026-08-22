import AppKit
import SwiftUI

/// 控制台首页：运行态 hero + 指标 + 本地 API + 快捷入口，填满内容区。
struct KernelHomeView: View {
    @Environment(AppState.self) private var appState
    @State private var showAPIKey = false
    @State private var copiedField: String?

    var body: some View {
        PageContainer(layout: .fill) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    heroBanner
                    if appState.coreUpdateAvailable {
                        coreUpdateBanner
                    }
                    metricsStrip
                    mainGrid
                    shortcutsRow
                }
                .padding(AppDesign.pagePadding)
                .frame(maxWidth: 1120)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("首页")
        .onAppear {
            appState.refreshStatus()
            appState.refreshConfigSettings()
        }
    }

    // MARK: - Hero

    private var heroBanner: some View {
        GlassCard(padding: 0) {
            HStack(alignment: .center, spacing: 0) {
                // Left accent — full height; card clips to continuous corner radius.
                UnevenRoundedRectangle(
                    topLeadingRadius: AppDesign.cardRadius,
                    bottomLeadingRadius: AppDesign.cardRadius,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                .fill(statusColor.gradient)
                .frame(width: 6)
                .frame(maxHeight: .infinity)

                HStack(alignment: .center, spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(statusColor.opacity(0.16))
                            .frame(width: 72, height: 72)
                        Circle()
                            .strokeBorder(statusColor.opacity(0.35), lineWidth: 2)
                            .frame(width: 72, height: 72)
                        Image(systemName: heroIcon)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(statusColor)
                            // Pulsing for as long as the core runs animates forever, which
                            // keeps Core Animation committing frames and costs ~20% CPU in
                            // this process plus WindowServer time. Reserve it for transitions.
                            .symbolEffect(.pulse, isActive: appState.isProcessBusy)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text(appState.coreStatus.message)
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                            StatusPill(
                                text: statusPillText,
                                tone: statusPillTone
                            )
                        }
                        Text(heroSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let version = appState.coreStatus.currentVersion {
                            Label("CLIProxyAPI v\(version)", systemImage: "shippingbox.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 12)

                    heroControls
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, minHeight: 148)
        }
    }

    private var heroIcon: String {
        if !appState.coreStatus.installed { return "arrow.down.circle" }
        return appState.coreStatus.running ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle"
    }

    private var statusPillText: String {
        if !appState.coreStatus.installed { return "未安装" }
        return appState.coreStatus.running ? "运行中" : "已停止"
    }

    private var statusPillTone: StatusPill.Tone {
        if !appState.coreStatus.installed { return .warning }
        return appState.coreStatus.running ? .success : .neutral
    }

    private var heroSubtitle: String {
        if !appState.coreStatus.installed {
            return "安装内核后即可启动本地代理"
        }
        if appState.coreStatus.running {
            let pid = appState.coreStatus.processId.map { "PID \($0)" } ?? ""
            let port = appState.guiConfig.snapshot().port
            return [pid, "监听端口 \(port)", lanLabel]
                .filter { !$0.isEmpty }
                .joined(separator: "  ·  ")
        }
        return "内核已就绪，启动后客户端可连接本地 API"
    }

    private var lanLabel: String {
        let gui = appState.guiConfig.snapshot()
        if gui.allowLan {
            return "局域网 \(appState.lanIPv4 ?? "…")"
        }
        return "仅本机"
    }

    @ViewBuilder
    private var heroControls: some View {
        VStack(spacing: 8) {
            if !appState.coreStatus.installed {
                AppControlButton(
                    title: "前往安装",
                    systemImage: "arrow.down.circle.fill",
                    kind: .primary,
                    isEnabled: !appState.isProcessBusy
                ) {
                    appState.select(.versions)
                }
            } else if appState.coreStatus.running {
                HStack(spacing: 8) {
                    AppControlButton(
                        title: "停止",
                        systemImage: "stop.fill",
                        kind: .danger,
                        isEnabled: !appState.isProcessBusy
                    ) {
                        appState.stopCore()
                    }
                    AppControlButton(
                        title: "重启",
                        systemImage: "arrow.triangle.2.circlepath",
                        kind: .secondary,
                        isEnabled: !appState.isProcessBusy
                    ) {
                        appState.restartCore()
                    }
                }
            } else {
                AppControlButton(
                    title: "启动内核",
                    systemImage: "play.fill",
                    kind: .primary,
                    isEnabled: !appState.isProcessBusy
                ) {
                    appState.startCore()
                }
            }

            AppControlButton(
                title: "刷新",
                systemImage: "arrow.clockwise",
                kind: .ghost
            ) {
                appState.refreshStatus()
                appState.refreshConfigSettings()
            }
        }
        .frame(width: 220)
    }

    private var coreUpdateBanner: some View {
        Button {
            appState.select(.versions)
        } label: {
            GlassCard(padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("内核有可用更新")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text({
                            let cur = appState.coreStatus.currentVersion.map { "v\($0)" } ?? "未安装"
                            let lat = appState.latestCore.map { "v\($0.version)" } ?? ""
                            return "\(cur) → \(lat) · 点击前往版本页"
                        }())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Metrics

    private var metricsStrip: some View {
        let gui = appState.guiConfig.snapshot()
        return LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ],
            spacing: 12
        ) {
            MetricTile(
                title: "安装",
                value: appState.coreStatus.installed ? "已安装" : "未安装",
                tint: appState.coreStatus.installed ? .green : .orange,
                icon: "internaldrive"
            )
            MetricTile(
                title: "端口",
                value: "\(gui.port)",
                tint: .primary,
                icon: "network"
            )
            MetricTile(
                title: "局域网",
                value: gui.allowLan ? "开启" : "关闭",
                tint: gui.allowLan ? .blue : .secondary,
                icon: "wifi"
            )
            MetricTile(
                title: "进程",
                value: appState.coreStatus.processId.map(String.init) ?? "—",
                tint: .primary,
                icon: "cpu"
            )
        }
    }

    // MARK: - Main grid: API + key + env

    private var mainGrid: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                endpointsSection
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                sidePanel
                    .frame(width: 300)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            VStack(alignment: .leading, spacing: 16) {
                endpointsSection
                sidePanel
            }
        }
    }

    private var endpointsSection: some View {
        let gui = appState.guiConfig.snapshot()
        let host = gui.allowLan ? (appState.lanIPv4 ?? "127.0.0.1") : "127.0.0.1"

        return GlassCard(padding: 18, fillHeight: true) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("本地 API", systemImage: "link")
                        .font(.headline)
                    Spacer()
                    Text(gui.allowLan ? "局域网可达" : "本机专用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(ClientApiProfile.all) { profile in
                    endpointRow(
                        title: profile.name,
                        url: profile.endpoint(host: host, port: gui.port),
                        brand: profileBrand(profile.id)
                    )
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func profileBrand(_ id: ClientApiProfile.Kind) -> String {
        switch id {
        case .openai: return "openai"
        case .claude: return "claude"
        case .gemini: return "gemini"
        }
    }

    private func endpointRow(title: String, url: String, brand: String) -> some View {
        HStack(spacing: 12) {
            ProviderIconView(provider: brand, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(url)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            copyChip(url, field: title)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 密钥 + 环境合并为一张侧栏卡，与左侧本地 API 等高。
    private var sidePanel: some View {
        let key = appState.firstAPIKey()
        return GlassCard(padding: 16, fillHeight: true) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("访问密钥", systemImage: "key.fill")
                        .font(.headline)

                    if key.isEmpty {
                        Text("尚未配置 API Key")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("去配置") { appState.select(.config) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else {
                        Text(showAPIKey ? key : maskKey(key))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )

                        HStack(spacing: 8) {
                            Button {
                                showAPIKey.toggle()
                            } label: {
                                Label(
                                    showAPIKey ? "隐藏" : "显示",
                                    systemImage: showAPIKey ? "eye.slash" : "eye"
                                )
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            copyChip(key, field: "apiKey")

                            Spacer(minLength: 0)

                            Button("管理") { appState.select(.config) }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                        }
                    }
                }

                Divider()
                    .padding(.vertical, 14)

                VStack(alignment: .leading, spacing: 12) {
                    Label("环境", systemImage: "folder.fill")
                        .font(.headline)

                    envRow("数据目录", AppPaths.baseDirectory.path)
                    envRow("安装目录", appState.coreStatus.installDir)

                    Spacer(minLength: 8)

                    Button {
                        NSWorkspace.shared.open(AppPaths.baseDirectory)
                    } label: {
                        Label("在 Finder 中打开", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func envRow(_ title: String, _ path: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(path)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    // MARK: - Shortcuts

    private var shortcutsRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快捷入口")
                .font(.headline)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ],
                spacing: 12
            ) {
                shortcutCard("OAuth", "完成提供商授权", "person.badge.key.fill", .oauth, .blue)
                shortcutCard("API 接入", "上游密钥与兼容", "network", .api, .indigo)
                shortcutCard("配额", "账号用量额度", "gauge.with.dots.needle.33percent", .quota, .green)
                shortcutCard("使用记录", "请求与费用分析", "chart.bar.fill", .usageRecords, .orange)
            }
        }
    }

    private func shortcutCard(
        _ title: String,
        _ subtitle: String,
        _ icon: String,
        _ page: AppPage,
        _ tint: Color
    ) -> some View {
        Button {
            appState.select(page)
        } label: {
            GlassCard(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(tint)
                        .frame(width: 36, height: 36)
                        .background(
                            tint.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .topLeading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var statusColor: Color {
        if appState.coreStatus.running { return .green }
        if appState.coreStatus.installed { return .orange }
        return .secondary
    }

    private func maskKey(_ key: String) -> String {
        let n = min(max(key.count, 8), 20)
        return String(repeating: "•", count: n)
    }

    private func copyChip(_ value: String, field: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copiedField = field
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if copiedField == field { copiedField = nil }
            }
        } label: {
            Label(
                copiedField == field ? "已复制" : "复制",
                systemImage: copiedField == field ? "checkmark" : "doc.on.doc"
            )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
