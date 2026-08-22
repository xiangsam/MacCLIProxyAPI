import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 版本页：对比舞台 + 安装操作区 + 平台/路径信息 + 高级安装，整页铺满。
struct KernelVersionsView: View {
    @Environment(AppState.self) private var appState
    @State private var isChecking = false
    @State private var isInstalling = false
    @State private var manualVersion = ""
    @State private var showAdvanced = false
    @State private var pendingInstall: PendingInstall?
    @State private var pendingAdvancedInstall: PendingInstall?

    /// What the user asked to install, held until they confirm.
    enum PendingInstall: Equatable {
        case latest
        case version(String)
        case localArchive(URL)
    }

    var body: some View {
        PageContainer(layout: .fill) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    comparisonStage
                    if showsInstallProgress {
                        progressPanel
                    }
                    actionPanel
                    infoGrid
                    advancedEntry
                }
                .padding(AppDesign.pagePadding)
                .frame(maxWidth: 960)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("版本")
        .sheet(isPresented: $showAdvanced) {
            advancedSheet
        }
        .confirmDestructive(
            $pendingInstall,
            title: confirmTitle,
            confirmLabel: confirmLabel,
            message: confirmMessage,
            action: { run($0) }
        )
        .task {
            await appState.refreshInstallMeta()
            // Opening the page used to always hit the network, which made 「自动检查」 look
            // broken: the toggle silences the background checker but the user still got an
            // update prompt on every visit. 「检查更新」 stays available for a manual check.
            await appState.runAutoCoreUpdateCheckIfNeeded(force: false)
            if manualVersion.isEmpty {
                if let latest = appState.latestCore {
                    manualVersion = latest.version
                } else if let pinned = AppPaths.readBundledCoreVersion() {
                    manualVersion = pinned
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("内核版本")
                    .font(.title2.weight(.bold))
                Text("安装或更新 CLIProxyAPI 核心，管理本地代理能力")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let at = appState.lastCoreUpdateCheckAt {
                    Text("上次检查 \(at.formatted(date: .omitted, time: .shortened)) · 自动检查已\(appState.autoCheckCoreUpdates ? "开启" : "关闭")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    if appState.isCheckingCoreUpdate {
                        ProgressView().controlSize(.mini)
                    }
                    StatusPill(text: updateStatusText, tone: updateStatusTone)
                }
                Toggle(isOn: Binding(
                    get: { appState.autoCheckCoreUpdates },
                    set: { appState.autoCheckCoreUpdates = $0 }
                )) {
                    Text("自动检查")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("启动后与每隔约 6 小时自动检查 GitHub 最新内核")
            }
        }
    }

    private var updateStatusText: String {
        if !appState.coreStatus.installed { return "需要安装" }
        guard let latest = appState.latestCore?.version,
              let current = appState.coreStatus.currentVersion
        else {
            return appState.latestCore == nil ? "未检查更新" : "可安装"
        }
        if latest == current { return "已是最新" }
        return "有可用更新"
    }

    private var updateStatusTone: StatusPill.Tone {
        if !appState.coreStatus.installed { return .warning }
        guard let latest = appState.latestCore?.version,
              let current = appState.coreStatus.currentVersion
        else { return .info }
        return latest == current ? .success : .warning
    }

    // MARK: - Comparison

    private var comparisonStage: some View {
        GlassCard(padding: 28) {
            VStack(spacing: 22) {
                HStack(spacing: 0) {
                    versionColumn(
                        badge: "当前",
                        version: appState.coreStatus.currentVersion.map { "v\($0)" } ?? "—",
                        detail: appState.coreStatus.installed ? "本机已安装" : "尚未安装",
                        accent: appState.coreStatus.installed ? Color.primary : Color.secondary,
                        highlight: false
                    )

                    VStack(spacing: 8) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.title2.weight(.medium))
                            .foregroundStyle(.tertiary)
                        if needsUpdate {
                            Text("更新")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(width: 72)

                    versionColumn(
                        badge: "最新",
                        version: appState.latestCore.map { "v\($0.version)" } ?? "—",
                        detail: latestDetail,
                        accent: Color.accentColor,
                        highlight: true
                    )
                }

                if appState.coreStatus.running {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("内核运行中，安装或更新前请先停止")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("停止内核") { appState.stopCore() }
                            .controlSize(.small)
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private func versionColumn(
        badge: String,
        version: String,
        detail: String,
        accent: Color,
        highlight: Bool
    ) -> some View {
        VStack(spacing: 12) {
            Text(badge)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12), in: Capsule())

            Text(version)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            if highlight {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().fill(Color.accentColor).frame(width: 4, height: 4))
            } else {
                Color.clear.frame(height: 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background {
            if highlight {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(0.06))
            }
        }
    }

    private var needsUpdate: Bool {
        guard let latest = appState.latestCore?.version,
              let current = appState.coreStatus.currentVersion
        else { return !appState.coreStatus.installed }
        return latest != current
    }

    private var latestDetail: String {
        if appState.latestCore == nil { return "点击检查更新" }
        if needsUpdate { return "可下载安装" }
        return "与当前一致"
    }

    // MARK: - Progress

    /// Only show while actively installing, or briefly after success (before state is cleared).
    private var showsInstallProgress: Bool {
        let task = appState.installTask
        if task.running { return true }
        // Idle completed leftovers should not stick forever — AppState clears them.
        return task.percent != nil && !task.phase.isEmpty
    }

    private var installFinished: Bool {
        !appState.installTask.running
            && appState.installTask.percent == 100
            && (appState.installTask.phase == "完成" || (appState.installTask.message?.contains("完成") == true))
    }

    private var progressPanel: some View {
        let finished = installFinished
        return GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    if appState.installTask.running {
                        ProgressView()
                            .controlSize(.small)
                    } else if finished {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Text(appState.installTask.phase.isEmpty
                         ? (appState.installTask.running ? "安装进行中" : "安装")
                         : appState.installTask.phase)
                        .font(.headline)
                        .foregroundStyle(finished ? Color.green : Color.primary)
                    Spacer()
                    if appState.installTask.running {
                        Button("取消", role: .destructive) {
                            Task { await appState.cancelInstall() }
                        }
                        .controlSize(.small)
                    }
                }

                if let percent = appState.installTask.percent {
                    ProgressView(value: percent, total: 100)
                        .tint(finished ? .green : .accentColor)
                    HStack {
                        Text(String(format: "%.0f%%", percent))
                            .font(.caption.monospacedDigit().weight(.semibold))
                        Spacer()
                        if let message = appState.installTask.message {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } else if appState.installTask.running {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let message = appState.installTask.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let message = appState.installTask.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private var installBusy: Bool {
        isInstalling || appState.installTask.running
    }

    private var actionPanel: some View {
        GlassCard(padding: 20) {
            VStack(spacing: 14) {
                if appState.coreStatus.running {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.orange)
                        Text("安装/更新会先自动停止内核，完成后再按需启动")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Button {
                    pendingInstall = .latest
                } label: {
                    Label(
                        appState.coreStatus.installed ? "更新到最新版本" : "安装最新版本",
                        systemImage: "arrow.down.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(installBusy)

                HStack(spacing: 12) {
                    Button {
                        Task {
                            isChecking = true
                            await appState.checkLatestCore()
                            if let latest = appState.latestCore {
                                manualVersion = latest.version
                            }
                            isChecking = false
                        }
                    } label: {
                        Label(isChecking ? "检查中…" : "检查更新", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(isChecking || installBusy)
                }
            }
        }
    }

    // MARK: - Info (only useful facts)

    private var infoGrid: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                infoCard(
                    title: "本机平台",
                    icon: "laptopcomputer",
                    value: appState.platform.map { "\($0.assetOS) / \($0.assetArch)" } ?? "检测中…",
                    caption: "下载资源时匹配的系统架构"
                )
                infoCard(
                    title: "安装目录",
                    icon: "folder",
                    value: shortPath(appState.coreStatus.installDir),
                    caption: appState.coreStatus.installDir,
                    monospaced: true
                )
            }
        }
    }

    private func infoCard(
        title: String,
        icon: String,
        value: String,
        caption: String? = nil,
        monospaced: Bool = false
    ) -> some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(monospaced ? .system(.body, design: .monospaced).weight(.semibold) : .title3.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                if let caption, caption != value {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        }
    }

    // MARK: - Advanced

    private var advancedEntry: some View {
        Button {
            showAdvanced = true
        } label: {
            GlassCard(padding: 16) {
                HStack(spacing: 14) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("高级安装")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("指定 GitHub 版本号，或选择本机 .tar.gz")
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

    private var advancedSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("高级安装")
                .font(.title3.weight(.semibold))

            if appState.coreStatus.running {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("当前内核正在运行。点安装后会先自动停止，安装完成不会自动再启动。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("指定版本")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("从 GitHub Release 下载对应 darwin 架构包，例如 7.2.110")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 10) {
                    TextField("7.2.110", text: $manualVersion)
                        .textFieldStyle(.roundedBorder)
                    Button(appState.coreStatus.running ? "停止并安装" : "安装") {
                        pendingAdvancedInstall = .version(
                            manualVersion.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        installBusy
                            || manualVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("本地安装包")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("选择已下载的 CLIProxyAPI_*.tar.gz（需与本机架构匹配）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button {
                    pickLocalArchive()
                } label: {
                    Label(
                        appState.coreStatus.running ? "停止并选择 .tar.gz…" : "选择 .tar.gz 文件…",
                        systemImage: "doc.badge.plus"
                    )
                    .frame(maxWidth: .infinity)
                }
                .disabled(installBusy)
            }

            Spacer(minLength: 0)

            HStack {
                if installBusy {
                    ProgressView().controlSize(.small)
                    Text("安装进行中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { showAdvanced = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 340)
        .confirmDestructive(
            $pendingAdvancedInstall,
            title: confirmTitle,
            confirmLabel: confirmLabel,
            message: confirmMessage,
            action: { pending in
                showAdvanced = false
                run(pending)
            }
        )
    }

    private func pickLocalArchive() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "选择 CLIProxyAPI 的 darwin 安装包（.tar.gz）"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "gz") ?? .data,
            UTType(filenameExtension: "tgz") ?? .data,
            UTType(filenameExtension: "tar") ?? .data,
            .gzip,
            .archive,
            .data,
        ]
        panel.allowsOtherFileTypes = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingAdvancedInstall = .localArchive(url)
    }

    // MARK: - Install confirmation

    private var confirmTitle: String {
        appState.coreStatus.installed ? "更新内核？" : "安装内核？"
    }

    private func confirmLabel(_ pending: PendingInstall) -> String {
        switch pending {
        case .latest:
            return appState.coreStatus.installed ? "更新到最新版本" : "安装最新版本"
        case .version(let version):
            return "安装 v\(AppPaths.normalizeVersion(version))"
        case .localArchive(let url):
            return "安装 \(url.lastPathComponent)"
        }
    }

    /// Spell out what the user loses and what the app will do about it.
    private func confirmMessage(_ pending: PendingInstall) -> String {
        var lines: [String] = []

        if appState.coreStatus.running {
            lines.append("会先停止正在运行的内核，安装完成后不会自动启动。")
        }

        return lines.joined(separator: "\n\n")
    }

    private func run(_ pending: PendingInstall) {
        Task {
            isInstalling = true
            switch pending {
            case .latest:
                await appState.installLatestCore()
            case .version(let version):
                await appState.installCoreVersion(version)
            case .localArchive(let url):
                await appState.installCoreFromLocalFile(url)
            }
            isInstalling = false
        }
    }

    private func shortPath(_ path: String) -> String {
        if path.count <= 36 { return path }
        return "…" + path.suffix(32)
    }

}
