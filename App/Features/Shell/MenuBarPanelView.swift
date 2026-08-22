import AppKit
import SwiftUI

/// Compact panel shown when clicking the menu bar status item.
struct MenuBarPanelView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.45)
            quotaSection
            Divider().opacity(0.45)
            controls
        }
        .frame(width: 340)
        .background {
            if #available(macOS 26.0, *) {
                Rectangle().fill(.regularMaterial)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .task {
            appState.refreshStatus()
            // 打开小窗时强制刷一次，避免账号列表为空仍显示旧状态。
            await appState.refreshQuotas(force: true)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.16))
                    .frame(width: 40, height: 40)
                Image(systemName: appState.coreStatus.running
                      ? "bolt.horizontal.circle.fill"
                      : "bolt.horizontal.circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("MacCLIProxyAPI")
                    .font(.headline)
                Text(coreStatusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            StatusPill(
                text: appState.coreStatus.running ? "运行中" : (appState.coreStatus.installed ? "已停止" : "未安装"),
                tone: appState.coreStatus.running ? .success : (appState.coreStatus.installed ? .neutral : .warning)
            )
        }
        .padding(14)
    }

    private var coreStatusLine: String {
        var parts: [String] = []
        if let version = appState.coreStatus.currentVersion {
            parts.append("v\(version)")
        }
        if let pid = appState.coreStatus.processId {
            parts.append("PID \(pid)")
        }
        return parts.isEmpty ? appState.coreStatus.message : parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        if appState.coreStatus.running { return .green }
        if appState.coreStatus.installed { return .orange }
        return .secondary
    }

    // MARK: - Quota

    @ViewBuilder
    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Provider 额度")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if appState.quotaSnapshot.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await appState.refreshQuotas(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!appState.coreStatus.running || appState.quotaSnapshot.isRefreshing)
                .help("刷新 Provider 额度")
            }

            if !appState.coreStatus.running {
                emptyHint(systemImage: "bolt.horizontal.circle", text: "启动内核后可查看额度")
            } else if appState.quotaSnapshot.isRefreshing && appState.quotaSnapshot.accounts.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("加载中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else if appState.quotaSnapshot.accounts.isEmpty {
                emptyHint(
                    systemImage: "gauge.with.dots.needle.33percent",
                    text: appState.quotaSnapshot.lastError ?? "暂无额度账号 · 完成 OAuth 后重试"
                )
            } else {
                // 不用 ScrollView 零高度塌缩：菜单栏窗口对 maxHeight-only 的 ScrollView 会挤没内容。
                let accounts = appState.quotaSnapshot.accounts
                Group {
                    if accounts.count > 4 {
                        ScrollView {
                            accountList(accounts)
                        }
                        .frame(height: 232)
                    } else {
                        accountList(accounts)
                    }
                }
            }
        }
        .padding(14)
    }

    private func accountList(_ accounts: [AccountQuotaSummary]) -> some View {
        VStack(spacing: 8) {
            ForEach(accounts) { account in
                accountCard(account)
            }
        }
    }

    private func emptyHint(systemImage: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func accountCard(_ account: AccountQuotaSummary) -> some View {
        let selected = appState.selectedMenuBarQuotaAccountID == account.id
        return Button {
            appState.selectMenuBarQuotaAccount(id: account.id)
        } label: {
            HStack(spacing: 10) {
                ProviderIconView(provider: account.provider.rawValue, size: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(account.provider.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let plan = account.plan, !plan.isEmpty {
                            Text(plan)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        if account.status == .error {
                            Text(account.error ?? "失败")
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 4)

                if let percent = account.primaryRemainingPercent {
                    Text(String(format: "%.0f%%", percent))
                        .font(.body.monospacedDigit().weight(.bold))
                        .foregroundStyle(color(for: percent))
                } else if let text = account.primaryDisplayText {
                    Text(text)
                        .font(.body.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                } else {
                    Text("—")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.35))
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                selected ? Color.accentColor.opacity(0.45) : Color.clear,
                                lineWidth: 1.5
                            )
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            if appState.coreStatus.installed {
                if appState.coreStatus.running {
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
            }

            HStack(spacing: 8) {
                AppControlButton(
                    title: "主界面",
                    systemImage: "macwindow",
                    kind: .secondary
                ) {
                    openMain(page: .home)
                }
                AppControlButton(
                    title: "配额",
                    systemImage: "gauge.with.dots.needle.33percent",
                    kind: .secondary
                ) {
                    openMain(page: .quota)
                }
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("退出")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
    }

    private func openMain(page: AppPage) {
        appState.select(page)

        if AppDelegate.hasMainWindow() {
            AppDelegate.showMainWindow()
            DispatchQueue.main.async {
                appState.select(page)
            }
            return
        }

        openWindow(id: "main")
        NotificationCenter.default.post(name: .macCLIShowMainWindow, object: page)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            appState.select(page)
            AppDelegate.showMainWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            appState.select(page)
            AppDelegate.showMainWindow()
        }
    }

    private func color(for percent: Double) -> Color {
        if percent < 15 { return .red }
        if percent < 35 { return .orange }
        return .green
    }
}
