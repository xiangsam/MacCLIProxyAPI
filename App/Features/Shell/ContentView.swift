import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppDesign.pageBackground)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            // One elegant menu instead of multiple glass capsules.
            ToolbarItem(placement: .primaryAction) {
                coreMenu
            }
        }
        .onChange(of: appState.coreRunning) { _, running in
            if !running, appState.selectedPage.requiresCoreRunning {
                appState.selectedPage = .home
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macCLIShowMainWindow)) { note in
            if let page = note.object as? AppPage {
                appState.select(page)
            }
        }
    }

    /// Compact kernel control: single control, clear state, no multi-capsule clutter.
    @ViewBuilder
    private var coreMenu: some View {
        if !appState.coreStatus.installed {
            Button {
                appState.select(.versions)
            } label: {
                Label("安装内核", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.isProcessBusy)
        } else {
            Menu {
                Section {
                    Label(
                        appState.coreStatus.running ? "状态：运行中" : "状态：已停止",
                        systemImage: appState.coreStatus.running ? "checkmark.circle" : "pause.circle"
                    )
                    if let version = appState.coreStatus.currentVersion {
                        Text("版本 v\(version)")
                    }
                    if let pid = appState.coreStatus.processId {
                        Text("PID \(pid)")
                    }
                }

                Section {
                    if appState.coreStatus.running {
                        Button("停止内核", role: .destructive) {
                            appState.stopCore()
                        }
                        .disabled(appState.isProcessBusy)
                        Button("重启内核") {
                            appState.restartCore()
                        }
                        .disabled(appState.isProcessBusy)
                    } else {
                        Button("启动内核") {
                            appState.startCore()
                        }
                        .disabled(appState.isProcessBusy)
                    }
                    Button("刷新状态") {
                        appState.refreshStatus()
                    }
                }
            } label: {
                // Single capsule: icon + short status.
                Label {
                    Text(appState.coreStatus.running ? "运行中" : "已停止")
                } icon: {
                    Image(systemName: appState.coreStatus.running ? "bolt.horizontal.fill" : "bolt.horizontal")
                }
            }
            .menuIndicator(.visible)
            .disabled(appState.isProcessBusy)
            .help(appState.coreStatus.running ? "内核运行中 — 点击管理" : "内核已停止 — 点击管理")
        }
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { appState.selectedPage },
            set: { appState.select($0 ?? .home) }
        )) {
            Section {
                ForEach([AppPage.home, .versions, .config, .diagnostics], id: \.self) { page in
                    pageRow(page)
                }
            } header: {
                Text("控制台")
            }

            Section {
                ForEach([AppPage.oauth, .api, .authFiles, .quota], id: \.self) { page in
                    pageRow(page)
                }
            } header: {
                Text("接入")
            }

            Section {
                ForEach([AppPage.thinkingAliases, .agents, .remoteSSH, .usageRecords], id: \.self) { page in
                    pageRow(page)
                }
            } header: {
                Text("高级")
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: AppDesign.sidebarIdeal, max: 300)
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
    }

    @ViewBuilder
    private func pageRow(_ page: AppPage) -> some View {
        let enabled = appState.canOpen(page)
        let showUpdateBadge = page == .versions && appState.coreUpdateAvailable
        HStack {
            Label(page.title, systemImage: page.systemImage)
                .symbolRenderingMode(.hierarchical)
            Spacer(minLength: 0)
            if showUpdateBadge {
                Text("更新")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.gradient, in: Capsule())
                    .help(appState.latestCore.map { "可更新到 v\($0.version)" } ?? "有可用内核更新")
            }
        }
        .tag(page)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .opacity(enabled ? 1 : 0.55)
        .help(enabled ? page.title : "需要内核运行")
    }

    @ViewBuilder
    private var detailView: some View {
        if appState.canOpen(appState.selectedPage) {
            switch appState.selectedPage {
            case .home:
                KernelHomeView()
            case .versions:
                KernelVersionsView()
            case .config:
                ConfigPanelView()
            case .oauth:
                OAuthPageView()
            case .api:
                ApiAccessPageView()
            case .authFiles:
                AuthFilesPageView()
            case .quota:
                QuotaPageView()
            case .thinkingAliases:
                ThinkingAliasesPageView()
            case .agents:
                AgentsPageView()
            case .remoteSSH:
                RemoteSSHPageView()
            case .usageRecords:
                UsageRecordsPageView()
            case .diagnostics:
                DiagnosticsPageView()
            }
        } else {
            ContentUnavailableView(
                "需要启动内核",
                systemImage: "bolt.horizontal.circle",
                description: Text("「\(appState.selectedPage.title)」在内核运行后可用。请先在首页启动 CLIProxyAPI。")
            )
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(statusDotColor)
                Text(appState.coreStatus.message)
                    .font(.caption.weight(.medium))
                if let version = appState.coreStatus.currentVersion {
                    Text("v\(version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 4)

            if let message = appState.lastActionMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(appState.lastActionIsError ? Color.red : Color.secondary)
                    .lineLimit(3)
                    .transition(.opacity)
            }

            Picker("主题", selection: Binding(
                get: { appState.themePreference },
                set: { appState.setTheme($0) }
            )) {
                ForEach(AppThemePreference.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Text(versionFooter)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.bar)
    }

    private var versionFooter: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        #if DEBUG
            // Several build outputs coexist under build/; without a stamp there is no
            // way to tell which one is actually running.
            return "MacCLIProxyAPI · v\(version) · Debug \(Self.buildStamp)"
        #else
            return "MacCLIProxyAPI · v\(version)"
        #endif
    }

    /// Link time of the running binary, which is the build time for practical purposes.
    private static let buildStamp: String = {
        guard let url = Bundle.main.executableURL,
            let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
        else { return "?" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }()

    private var statusDotColor: Color {
        if appState.coreStatus.running { return .green }
        if appState.coreStatus.installed { return .orange }
        return .secondary
    }
}
