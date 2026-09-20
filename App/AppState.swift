import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {
    /// Weak shared handle for AppDelegate lifecycle (quit cleanup).
    static weak var shared: AppState?

    var selectedPage: AppPage = .home
    var coreStatus: CoreStatus
    var statusError: String?
    var lastActionMessage: String?
    var lastActionIsError: Bool = false
    var isProcessBusy = false
    var installTask = CoreInstallTask()
    var themePreference: AppThemePreference = .system
    var configSettings: CoreConfigSettings
    var platform: CorePlatform?
    var latestCore: CoreLatest?
    var lanIPv4: String?
    var quotaSnapshot = QuotaSnapshot()
    /// Preferred source shown in menu bar title (persisted): a Provider account id.
    var selectedMenuBarQuotaAccountID: String? = UserDefaults.standard.string(forKey: "menuBar.quotaAccountID")

    var usageCollectorStatus: UsageCollectorStatus = .waiting
    var usageRevision: Int = 0
    /// Last auto/manual core update check time.
    var lastCoreUpdateCheckAt: Date?
    /// Quiet background check in progress.
    var isCheckingCoreUpdate = false
    /// Persist preference: auto-check kernel updates (default on).
    var autoCheckCoreUpdates: Bool = UserDefaults.standard.object(forKey: "core.autoCheckUpdates") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoCheckCoreUpdates, forKey: "core.autoCheckUpdates")
            if autoCheckCoreUpdates {
                startCoreUpdateChecker()
            } else {
                coreUpdateTask?.cancel()
                coreUpdateTask = nil
            }
        }
    }

    let guiConfig: GuiConfigStore
    let processService: CoreProcessService
    let installService: CoreInstallService
    let usageCollector = UsageCollector()

    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var quotaTask: Task<Void, Never>?
    @ObservationIgnored
    private var coreUpdateTask: Task<Void, Never>?
    @ObservationIgnored
    private var lastQuotaFetch: Date?

    /// Minimum interval between automatic quota refreshes.
    private let quotaAutoRefreshInterval: TimeInterval = 120
    /// Auto core update check interval (6 hours).
    private let coreUpdateCheckInterval: TimeInterval = 6 * 60 * 60

    /// True when remote latest is newer than installed (or installed is missing).
    var coreUpdateAvailable: Bool {
        guard let latest = latestCore?.version else { return false }
        guard let current = coreStatus.currentVersion else {
            return coreStatus.installed == false
        }
        return AppPaths.normalizeVersion(latest) != AppPaths.normalizeVersion(current)
    }

    init() {
        let store = GuiConfigStore()
        self.guiConfig = store
        self.processService = CoreProcessService()
        self.installService = CoreInstallService()
        let snapshot = store.snapshot()
        self.coreStatus = CoreStatus.empty(installDir: AppPaths.installDirectory.path)
        self.configSettings = snapshot.coreConfigSettings
        self.themePreference = AppThemePreference(rawValue: snapshot.theme) ?? .system
        self.platform = nil
        if let ts = UserDefaults.standard.object(forKey: "core.lastUpdateCheckAt") as? TimeInterval {
            self.lastCoreUpdateCheckAt = Date(timeIntervalSince1970: ts)
        }
        // Debug/docs helper: `open …/MacCLIProxyAPI.app --args --page=quota`
        if let pageArg = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--page=") })?
            .split(separator: "=", maxSplits: 1).last
            .map(String.init),
           let page = AppPage(rawValue: pageArg)
        {
            self.selectedPage = page
        }

        // Lightweight launch: avoid blocking main with process scans until UI is up.
        // Durable keys → core yaml on every launch (repairs wiped api-keys: []).
        let fresh = guiConfig.snapshotFresh()
        try? CoreConfigStore.syncFromGUI(fresh)
        applyConfigSettingsFromGUI(fresh)
        refreshConfigSettings()
        Self.shared = self
        Task { @MainActor [weak self] in
            self?.refreshStatus()
            await self?.refreshInstallMeta()
            self?.startPolling()
            self?.startUsageCollector()
            self?.startCoreUpdateChecker()
            self?.maybeAutoStart()
            self?.maybeRepairCodexSessionsOnLaunch()
        }
    }

    /// Optional one-shot Codex history unify/migrate when GUI flag is on.
    private func maybeRepairCodexSessionsOnLaunch() {
        let gui = guiConfig.snapshot()
        guard gui.codexSessionRepairOnLaunch else { return }
        let agentSettings = AgentProviderStore.loadSettings()
        guard agentSettings.unifyCodexSessionHistory else { return }
        Task.detached(priority: .utility) {
            do {
                // Skip quietly when Codex is live — never fight an active writer on launch.
                if CodexSessionUnifier.isCodexProcessRunning() { return }
                let result = try CodexSessionUnifier.migrateOfficialSessionsToCustom()
                await MainActor.run {
                    // Avoid noisy flash on every launch when nothing changed.
                    if result.jsonlRewritten > 0 || result.sqliteUpdated > 0 {
                        self.flash(
                            "Codex 会话已统一：文件 \(result.jsonlRewritten)，索引 \(result.sqliteUpdated)"
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    // Launch repair is best-effort; surface real failures but not "busy" races as red alerts every boot.
                    let message = error.localizedDescription
                    if message.contains("正在运行") || message.contains("被改动") {
                        return
                    }
                    self.flash("Codex 会话统一失败：\(message)", error: true)
                }
            }
        }
    }

    /// Called from `applicationWillTerminate` — stop orphaned core so ports are released.
    func shutdownCoreOnAppExit() {
        let port = guiConfig.snapshot().port
        processService.stopOnAppExit(port: port)
        usageCollector.stop()
    }

    private func startUsageCollector() {
        usageCollector.onStatusChange = { [weak self] status in
            self?.usageCollectorStatus = status
        }
        usageCollector.onRecordsSaved = { [weak self] in
            self?.usageRevision += 1
        }
        usageCollector.start(
            isCoreRunning: { [weak self] in
                self?.coreStatus.running ?? false
            },
            managementClient: { [weak self] in
                self?.managementClient() ?? ManagementClient(port: AppPaths.defaultPort, secretKey: AppPaths.defaultManagementSecret)
            },
            apiKeys: { [weak self] in
                self?.guiConfig.snapshot().apiKeys ?? []
            }
        )
        usageCollectorStatus = usageCollector.status
    }

    /// Every read below blocks on `UsageDatabase`'s serial queue, so it runs off the main actor.
    /// Aggregations scan the whole selected time range and the page reloads on each collected
    /// batch, which is enough to stutter the UI once the database holds real history.
    private func queryUsage<Result: Sendable>(
        _ body: @escaping @Sendable () throws -> Result
    ) async throws -> Result {
        try await Task.detached(priority: .userInitiated) { try body() }.value
    }

    func usageOverview(range: UsageRange, provider: String? = nil) async throws -> UsageOverview {
        let query = range.makeQuery(provider: provider)
        return try await queryUsage { try UsageDatabase.shared.overview(query: query) }
    }

    func usageAnalysis(range: UsageRange, provider: String? = nil) async throws -> UsageAnalysis {
        let query = range.makeQuery(provider: provider)
        return try await queryUsage { try UsageDatabase.shared.analysis(query: query) }
    }

    func usageEvents(
        range: UsageRange,
        page: Int,
        pageSize: Int = 50,
        provider: String? = nil
    ) async throws -> UsageEventPage {
        var query = range.makeQuery(provider: provider)
        query.page = page
        query.pageSize = pageSize
        return try await queryUsage { try UsageDatabase.shared.events(query: query) }
    }

    func usagePricing(range: UsageRange, provider: String? = nil) async throws -> UsagePricing {
        let query = range.makeQuery(provider: provider)
        return try await queryUsage { try UsageDatabase.shared.pricing(query: query) }
    }

    func usageProviderOptions(range: UsageRange) async throws -> [String] {
        let query = range.makeQuery()
        return try await queryUsage { try UsageDatabase.shared.distinctProviders(query: query) }
    }

    func usageDatabaseSizeBytes() -> Int64 {
        UsageDatabase.shared.databaseSizeBytes()
    }

    func exportUsageCSV(to url: URL, range: UsageRange, provider: String? = nil) throws -> Int {
        try UsageDatabase.shared.exportCSV(to: url, query: range.makeQuery(provider: provider))
    }

    func clearUsageRecords(olderThan date: Date?) throws -> Int {
        let deleted = try UsageDatabase.shared.deleteRecords(olderThan: date)
        usageCollector.refreshTotal()
        usageRevision += 1
        return deleted
    }

    /// Remaining % for the menu bar label.
    var menuBarRemainingPercent: Double? {
        guard coreStatus.running else { return nil }
        return quotaSnapshot.remainingPercent(forAccountID: selectedMenuBarQuotaAccountID)
    }

    /// Compact text for menu bar title (shown next to icon when space allows).
    var menuBarTitle: String {
        if let percent = menuBarRemainingPercent {
            return String(format: "%.0f%%", percent)
        }
        if let account = selectedMenuBarQuotaAccount,
           let text = account.primaryDisplayText
        {
            return text
        }
        if coreStatus.running {
            return "ON"
        }
        return coreStatus.installed ? "OFF" : "—"
    }

    var selectedMenuBarQuotaAccount: AccountQuotaSummary? {
        quotaSnapshot.account(id: selectedMenuBarQuotaAccountID)
    }

    func selectMenuBarQuotaAccount(id: String?) {
        // Always write a new value so Observation publishes to MenuBar label.
        selectedMenuBarQuotaAccountID = id
        if let id, !id.isEmpty {
            UserDefaults.standard.set(id, forKey: "menuBar.quotaAccountID")
        } else {
            selectedMenuBarQuotaAccountID = nil
            UserDefaults.standard.removeObject(forKey: "menuBar.quotaAccountID")
        }
        // Nudge dependents that only read derived title.
        objectWillChangeIfNeeded()
    }

    /// @Observable already tracks property sets; keep a no-op hook for clarity.
    private func objectWillChangeIfNeeded() {}

    /// After refresh, keep selection if still valid; otherwise pick a sensible default.
    func reconcileMenuBarQuotaSelection() {
        let accounts = quotaSnapshot.accounts
        if let id = selectedMenuBarQuotaAccountID,
           accounts.contains(where: { $0.id == id })
        {
            return
        }

        if let preferred = accounts.first(where: { $0.status == .success }) ?? accounts.first {
            selectMenuBarQuotaAccount(id: preferred.id)
            return
        }
        selectMenuBarQuotaAccount(id: nil)
    }

    var coreRunning: Bool { coreStatus.running }

    var preferredColorScheme: ColorScheme? {
        switch themePreference {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    func canOpen(_ page: AppPage) -> Bool {
        !page.requiresCoreRunning || coreRunning
    }

    func select(_ page: AppPage) {
        if canOpen(page) {
            selectedPage = page
        } else {
            selectedPage = .home
            flash("请先启动内核后再打开「\(page.title)」", error: true)
        }
    }

    func refreshStatus() {
        let port = guiConfig.snapshot().port
        let service = processService
        // Process scans (ps/lsof) must not block the main actor.
        Task.detached(priority: .utility) { [weak self] in
            let status = service.currentStatus(port: port)
            await MainActor.run {
                guard let self else { return }
                let wasRunning = self.coreStatus.running
                self.coreStatus = status
                self.statusError = nil
                if self.selectedPage.requiresCoreRunning && !status.running {
                    self.selectedPage = .home
                }
            }
        }
    }

    func refreshConfigSettings() {
        // Always reload GUI file from disk first so relaunch shows the last saved keys.
        guiConfig.reload()
        let gui = guiConfig.snapshot()
        do {
            var fromCore = try CoreConfigStore.readSettings(gui: gui)
            // GUI owns API keys / network — never let stale core yaml "reset" them in the UI.
            fromCore.apiKeys = gui.apiKeys
            fromCore.port = gui.port
            fromCore.allowLan = gui.allowLan
            fromCore.routingStrategy = gui.routingStrategy
            fromCore.proxyUrl = gui.proxyUrl
            fromCore.routingSessionAffinity = gui.routingSessionAffinity
            fromCore.routingSessionAffinityTtl = gui.routingSessionAffinityTtl
            fromCore.routingExcludeCodexOverlappingModels = gui.routingExcludeCodexOverlappingModels
            fromCore.optimizeCodexMultiAgentV2 = gui.optimizeCodexMultiAgentV2
            configSettings = fromCore
        } catch {
            configSettings = gui.coreConfigSettings
        }
        lanIPv4 = localLANIPv4()
    }

    func refreshInstallMeta() async {
        platform = await installService.detectPlatform()
        installTask = await installService.currentTask()
    }

    func startCore() {
        guard !isProcessBusy else { return }
        isProcessBusy = true
        // Fresh disk snapshot so restart never merges with a stale empty key list.
        let gui = guiConfig.snapshotFresh()
        let service = processService
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let status = try service.start(gui: gui)
                await MainActor.run {
                    guard let self else { return }
                    self.coreStatus = status
                    _ = try? self.guiConfig.setRunOnStartup(true)
                    self.applyConfigSettingsFromGUI(self.guiConfig.snapshotFresh())
                    self.flash("内核已启动")
                    self.isProcessBusy = false
                    Task { await self.refreshQuotas(force: true) }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.flash(error.localizedDescription, error: true)
                    self.refreshStatus()
                    self.isProcessBusy = false
                }
            }
        }
    }

    func stopCore() {
        guard !isProcessBusy else { return }
        isProcessBusy = true
        let port = guiConfig.snapshot().port
        let service = processService
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let status = try service.stop(port: port)
                await MainActor.run {
                    guard let self else { return }
                    self.coreStatus = status
                    _ = try? self.guiConfig.setRunOnStartup(false)
                    self.quotaSnapshot = QuotaSnapshot()
                    self.lastQuotaFetch = nil
                    self.flash("内核已停止")
                    self.isProcessBusy = false
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.flash(error.localizedDescription, error: true)
                    self.refreshStatus()
                    self.isProcessBusy = false
                }
            }
        }
    }

    func restartCore() {
        guard !isProcessBusy else { return }
        isProcessBusy = true
        let gui = guiConfig.snapshotFresh()
        let service = processService
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let status = try service.restart(gui: gui)
                await MainActor.run {
                    guard let self else { return }
                    self.coreStatus = status
                    _ = try? self.guiConfig.setRunOnStartup(true)
                    self.applyConfigSettingsFromGUI(self.guiConfig.snapshotFresh())
                    self.flash("内核已重启")
                    self.isProcessBusy = false
                    Task { await self.refreshQuotas(force: true) }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.flash(error.localizedDescription, error: true)
                    self.refreshStatus()
                    self.isProcessBusy = false
                }
            }
        }
    }

    /// Refresh account quotas via management `/api-call`.
    /// - Parameter force: ignore cache interval when true.
    func refreshQuotas(force: Bool = false) async {
        guard coreStatus.running else {
            quotaSnapshot = QuotaSnapshot()
            lastQuotaFetch = nil
            return
        }
        if quotaSnapshot.isRefreshing { return }
        if !force,
           let last = lastQuotaFetch,
           Date().timeIntervalSince(last) < quotaAutoRefreshInterval,
           !quotaSnapshot.accounts.isEmpty
        {
            return
        }

        var loading = quotaSnapshot
        loading.isRefreshing = true
        loading.lastError = nil
        quotaSnapshot = loading

        let client = managementClient()
        let accounts = await QuotaService.loadAll(client: client)

        var next = QuotaSnapshot()
        next.accounts = accounts
        next.isRefreshing = false
        next.lastRefreshedAt = Date()
        if accounts.allSatisfy({ $0.status == .error }), !accounts.isEmpty {
            next.lastError = accounts.first?.error ?? "全部账号配额查询失败"
        }
        quotaSnapshot = next
        lastQuotaFetch = Date()
        reconcileMenuBarQuotaSelection()
    }

    /// Check remote kernel version.
    /// - Parameter silent: when true, only notify if an update is available (used by auto-check).
    func checkLatestCore(silent: Bool = false) async {
        if isCheckingCoreUpdate { return }
        isCheckingCoreUpdate = true
        defer { isCheckingCoreUpdate = false }
        do {
            let latest = try await installService.checkLatest()
            latestCore = latest
            lastCoreUpdateCheckAt = Date()
            UserDefaults.standard.set(lastCoreUpdateCheckAt!.timeIntervalSince1970, forKey: "core.lastUpdateCheckAt")
            refreshStatus()

            let latestVer = AppPaths.normalizeVersion(latest.version)
            let currentVer = coreStatus.currentVersion.map { AppPaths.normalizeVersion($0) }
            if let currentVer, latestVer != currentVer {
                flash("发现内核新版本 v\(latestVer)（当前 v\(currentVer)）")
            } else if currentVer == nil, !coreStatus.installed {
                flash("可安装内核 v\(latestVer)")
            } else if !silent {
                flash("内核已是最新：v\(latestVer)")
            }
        } catch {
            if !silent {
                flash(error.localizedDescription, error: true)
            }
            // Silent auto-check failures stay quiet to avoid noise offline.
        }
    }

    private func startCoreUpdateChecker() {
        coreUpdateTask?.cancel()
        guard autoCheckCoreUpdates else { return }
        coreUpdateTask = Task { [weak self] in
            // Short delay so launch UI settles first.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.runAutoCoreUpdateCheckIfNeeded(force: true)
            while !Task.isCancelled {
                // Wake every hour; only hit network when interval elapsed.
                try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.runAutoCoreUpdateCheckIfNeeded(force: false)
            }
        }
    }

    /// Honours both the 「自动检查」 toggle and the interval, so callers that fire on every page
    /// appearance do not turn into an unthrottled network check.
    func runAutoCoreUpdateCheckIfNeeded(force: Bool) async {
        guard autoCheckCoreUpdates else { return }
        if !force, let last = lastCoreUpdateCheckAt,
           Date().timeIntervalSince(last) < coreUpdateCheckInterval
        {
            return
        }
        await checkLatestCore(silent: true)
    }

    /// Stop managed core if running so install/replace can proceed.
    func prepareForCoreInstall() async throws {
        refreshStatus()
        guard coreStatus.running else { return }
        flash("安装前正在停止内核…")
        let port = guiConfig.snapshot().port
        coreStatus = try await Task.detached(priority: .userInitiated) { [processService] in
            try processService.stop(port: port)
        }.value
        // Wait briefly for binary lock / port release.
        try? await Task.sleep(nanoseconds: 400_000_000)
        refreshStatus()
        if coreStatus.running {
            throw AppError("无法停止正在运行的内核，请先手动停止后再安装")
        }
    }

    func installLatestCore() async {
        do {
            try await prepareForCoreInstall()
            _ = try await installService.installLatest { [weak self] task in
                self?.installTask = task
            }
            refreshStatus()
            await refreshInstallMeta()
            flash("内核安装完成")
            await clearInstallProgressAfterSuccess()
        } catch {
            installTask = await installService.currentTask()
            flash(error.localizedDescription, error: true)
        }
    }

    func installCoreVersion(_ version: String) async {
        do {
            try await prepareForCoreInstall()
            _ = try await installService.installVersion(version) { [weak self] task in
                self?.installTask = task
            }
            refreshStatus()
            await refreshInstallMeta()
            flash("内核 v\(AppPaths.normalizeVersion(version)) 安装完成")
            await clearInstallProgressAfterSuccess()
        } catch {
            installTask = await installService.currentTask()
            flash(error.localizedDescription, error: true)
        }
    }

    func installCoreFromLocalFile(_ url: URL) async {
        do {
            try await prepareForCoreInstall()
            // Security-scoped access for user-selected files.
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            _ = try await installService.installFromLocalFile(url) { [weak self] task in
                self?.installTask = task
            }
            refreshStatus()
            await refreshInstallMeta()
            flash("本地内核安装完成")
            await clearInstallProgressAfterSuccess()
        } catch {
            installTask = await installService.currentTask()
            flash(error.localizedDescription, error: true)
        }
    }

    func cancelInstall() async {
        await installService.cancel()
        installTask = await installService.currentTask()
        // Drop leftover progress UI after cancel settles.
        if !installTask.running {
            installTask = CoreInstallTask()
            await installService.resetTask()
        }
    }

    private func clearInstallProgressAfterSuccess() async {
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        guard !installTask.running else { return }
        installTask = CoreInstallTask()
        await installService.resetTask()
    }

    func saveNetwork(port: UInt16, allowLan: Bool) {
        do {
            let wasRunning = coreStatus.running
            let old = guiConfig.snapshot()
            let updated = try guiConfig.saveNetwork(port: port, allowLan: allowLan)
            try CoreConfigStore.patchNetworkAndRouting(gui: updated)
            refreshConfigSettings()
            if wasRunning && (old.port != port || old.allowLan != allowLan) {
                restartCoreInBackground(gui: updated, successMessage: "网络设置已保存并重启内核")
            } else {
                flash("网络设置已保存")
            }
        } catch {
            flash(error.localizedDescription, error: true)
        }
    }

    /// Restart without blocking the main actor.
    ///
    /// `CoreProcessService.restart` waits on the port with a sleep loop, so calling it inline
    /// froze the window for as long as the kernel took to come back.
    private func restartCoreInBackground(gui: GuiConfigFile, successMessage: String) {
        guard !isProcessBusy else { return }
        isProcessBusy = true
        let service = processService
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let status = try service.restart(gui: gui)
                await MainActor.run {
                    guard let self else { return }
                    self.coreStatus = status
                    self.isProcessBusy = false
                    self.flash(successMessage)
                    self.refreshStatus()
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isProcessBusy = false
                    self.flash(error.localizedDescription, error: true)
                    self.refreshStatus()
                }
            }
        }
    }

@discardableResult
    func addAPIKey(remark: String) -> Bool {
        let key = "sk-" + randomToken(length: 32)
        return addAPIKey(value: key, remark: remark)
    }

    /// Add a user-specified API key. Returns `true` when persisted to GUI config.
    /// Does **not** block on core restart — applies live via management API in the background.
    @discardableResult
    func addAPIKey(value: String, remark: String) -> Bool {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            flash("API Key 不能为空", error: true)
            return false
        }
        if key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            flash("API Key 不能包含控制字符", error: true)
            return false
        }
        if key.count > 512 {
            flash("API Key 过长（最多 512 字符）", error: true)
            return false
        }
        do {
            let existing = guiConfig.snapshot().apiKeys.map(\.apiKey)
            if existing.contains(key) {
                flash("该 API Key 已存在", error: true)
                return false
            }
            let updated = try guiConfig.update {
                $0.apiKeys.append(
                    GuiApiKey(
                        apiKey: key,
                        remark: remark.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                )
            }
            // Instant UI update from GUI (source of truth).
            applyConfigSettingsFromGUI(updated)
            flash("已添加 API Key")
            Task { await pushAPIKeysToCore(updated, successNote: "密钥已同步到内核") }
            return true
        } catch {
            flash(error.localizedDescription, error: true)
            return false
        }
    }

    func updateAPIKeyRemark(apiKey: String, remark: String) {
        do {
            let updated = try guiConfig.update { cfg in
                if let idx = cfg.apiKeys.firstIndex(where: { $0.apiKey == apiKey }) {
                    cfg.apiKeys[idx].remark = remark
                }
            }
            applyConfigSettingsFromGUI(updated)
        } catch {
            flash(error.localizedDescription, error: true)
        }
    }

    func deleteAPIKey(_ apiKey: String) {
        do {
            let updated = try guiConfig.update { cfg in
                cfg.apiKeys.removeAll { $0.apiKey == apiKey }
            }
            applyConfigSettingsFromGUI(updated)
            let scope = updated.apiKeys.isEmpty ? "全部 API Key" : "API Key"
            // The key only stops working once the kernel reloads config.yaml, which happens in the
            // task below — so don't claim it is already rejected.
            flash(coreStatus.running ? "已删除\(scope)，正在同步到内核…" : "已删除\(scope)")
            Task { await pushAPIKeysToCore(updated, successNote: "已删除的密钥已在内核失效") }
        } catch {
            flash(error.localizedDescription, error: true)
        }
    }

    /// Mirror GUI-owned fields into `configSettings` for immediate UI refresh.
    private func applyConfigSettingsFromGUI(_ gui: GuiConfigFile) {
        var next = configSettings
        next.apiKeys = gui.apiKeys
        next.port = gui.port
        next.allowLan = gui.allowLan
        next.routingStrategy = gui.routingStrategy
        next.proxyUrl = gui.proxyUrl
        next.routingSessionAffinity = gui.routingSessionAffinity
        next.routingSessionAffinityTtl = gui.routingSessionAffinityTtl
        next.routingExcludeCodexOverlappingModels = gui.routingExcludeCodexOverlappingModels
        next.optimizeCodexMultiAgentV2 = gui.optimizeCodexMultiAgentV2
        configSettings = next
    }

    /// Write keys into core config.yaml and hot-reload via management API when possible.
    /// Falls back to a background process restart only if live update fails.
    private func pushAPIKeysToCore(_ gui: GuiConfigFile, successNote: String) async {
        // Always re-read durable store before writing into core yaml.
        let fresh = guiConfig.snapshotFresh()
        let merged = withKeys(from: fresh, into: gui)
        do {
            try CoreConfigStore.writeAPIKeys(merged.apiKeys, gui: merged)
            try CoreConfigStore.syncFromGUI(merged)
        } catch {
            flash("密钥已保存，但写入内核配置失败：\(error.localizedDescription)", error: true)
            return
        }

        guard coreStatus.running else { return }

        // Prefer hot-reload — avoids multi-second main-thread restart freeze.
        do {
            let yaml = try String(contentsOf: AppPaths.coreConfigURL, encoding: .utf8)
            try await managementClient().putConfigYAML(yaml)
            flash(successNote)
            return
        } catch {
            // Fall through to restart.
        }

        flash("正在后台重启内核以应用密钥…")
        let ok = await restartCoreInBackground(gui: merged)
        if ok {
            flash("密钥已生效（内核已重启）")
        } else {
            flash("密钥已保存；内核重启失败，请手动重启", error: true)
        }
    }

    private func withKeys(from source: GuiConfigFile, into base: GuiConfigFile) -> GuiConfigFile {
        var next = base
        if next.apiKeys.isEmpty, !source.apiKeys.isEmpty {
            next.apiKeys = source.apiKeys
        }
        return next
    }

    /// Run process restart off the main actor so the UI stays responsive.
    private func restartCoreInBackground(gui: GuiConfigFile) async -> Bool {
        guard !isProcessBusy else { return false }
        isProcessBusy = true
        defer { isProcessBusy = false }
        // Prefer keys currently on disk over a possibly stale captured snapshot.
        let fresh = guiConfig.snapshotFresh()
        var payload = gui
        if payload.apiKeys.isEmpty {
            payload.apiKeys = fresh.apiKeys
        }
        let service = processService
        do {
            let status = try await Task.detached(priority: .userInitiated) {
                try service.restart(gui: payload)
            }.value
            coreStatus = status
            applyConfigSettingsFromGUI(guiConfig.snapshotFresh())
            return status.running
        } catch {
            refreshStatus()
            return false
        }
    }

    func saveRouting(
        strategy: String,
        proxyUrl: String,
        sessionAffinity: Bool,
        sessionTTL: String,
        excludeCodexOverlappingModels: Bool,
        optimizeCodexMultiAgentV2: Bool
    ) {
        do {
            let normalizedTTL = CoreConfigStore.normalizeSessionAffinityTTL(sessionTTL)
            let updated = try guiConfig.update {
                $0.routingStrategy = strategy
                $0.proxyUrl = proxyUrl
                $0.routingSessionAffinity = sessionAffinity
                $0.routingSessionAffinityTtl = normalizedTTL
                $0.routingExcludeCodexOverlappingModels = excludeCodexOverlappingModels
                $0.optimizeCodexMultiAgentV2 = optimizeCodexMultiAgentV2
            }
            try CoreConfigStore.patchNetworkAndRouting(gui: updated)
            refreshConfigSettings()
            // Routing lives in config.yaml, which the kernel only re-reads on boot.
            if coreStatus.running {
                restartCoreInBackground(gui: updated, successMessage: "路由设置已保存，内核已重启生效")
            } else {
                flash("路由设置已保存，下次启动内核生效")
            }
        } catch {
            flash(error.localizedDescription, error: true)
        }
    }

    func setTheme(_ theme: AppThemePreference) {
        themePreference = theme
        _ = try? guiConfig.update { $0.theme = theme.rawValue }
    }

    func managementClient() -> ManagementClient {
        ManagementClient(gui: guiConfig.snapshot())
    }

    /// Converge the core's per-credential exclusions onto a newly live Codex profile.
    ///
    /// Shared by the local Agents page and Remote SSH: a remote agent reaches this same core over
    /// the LAN, so its 「只走 Codex 订阅」 switch has to move the very same routing.
    func syncCodexSubscriptionIsolation(for profile: AgentProviderProfile) async {
        let globalExclusion = guiConfig.snapshot().routingExcludeCodexOverlappingModels
        do {
            let outcome = try await CodexSubscriptionIsolation.sync(
                for: profile,
                globalExclusionEnabled: globalExclusion,
                client: managementClient()
            )
            switch outcome {
            case .unchanged:
                break
            case .applied:
                flash("同名 GPT 模型已隔离到 Codex 订阅（其他 Provider 暂不参与路由）")
            case .reverted:
                flash("已恢复同名 GPT 模型的正常路由")
            case .conflictsWithGlobalExclusion:
                flash(
                    "配置页的「GPT 同名模型完全不走 Codex 订阅」仍开着，两边会把同名模型同时排除，请关掉那个开关。",
                    error: true
                )
            }
        } catch {
            flash("同名模型隔离未生效：\(error.localizedDescription)", error: true)
        }
    }

    func firstAPIKey() -> String {
        // Prefer live GUI list; do not invent the historical default "123456" if empty.
        guiConfig.snapshot().apiKeys.first?.apiKey ?? ""
    }

    func openAuthDirectory() {
        let gui = guiConfig.snapshot()
        let dir = AppPaths.resolveAuthDirectory(authDir: gui.authDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    func flash(_ message: String, error: Bool = false) {
        lastActionMessage = message
        lastActionIsError = error
    }

    /// No main window means the app is menu-bar only and nobody is watching a dashboard.
    ///
    /// The status poll shells out to `ps` and `lsof`, and the quota poll calls the upstream API
    /// once per auth file, so both keep waking a backgrounded app. Opening the menu bar panel
    /// forces a refresh of its own, and `refreshOnForeground()` covers reopening the window.
    private var isMenuBarOnly: Bool {
        NSApp.activationPolicy() == .accessory
    }

    private var statusPollSeconds: UInt64 { isMenuBarOnly ? 1800 : 10 }
    private var quotaPollSeconds: UInt64 { isMenuBarOnly ? 600 : 120 }

    private func startPolling() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let seconds = await self?.statusPollSeconds else { return }
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                await MainActor.run {
                    self?.refreshStatus()
                }
            }
        }

        quotaTask?.cancel()
        quotaTask = Task { [weak self] in
            // Initial delay so core can settle after auto-start.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                if self.coreStatus.running {
                    await self.refreshQuotas(force: false)
                }
                try? await Task.sleep(nanoseconds: self.quotaPollSeconds * 1_000_000_000)
            }
        }
    }

    /// Catch up after the window comes back, since the background intervals are long.
    func refreshOnForeground() {
        refreshStatus()
        Task { await refreshQuotas(force: false) }
    }

    private func maybeAutoStart() {
        let gui = guiConfig.snapshot()
        let service = processService
        Task.detached(priority: .userInitiated) { [weak self] in
            let status = service.currentStatus(port: gui.port)
            await MainActor.run {
                guard let self else { return }
                self.coreStatus = status
                guard gui.runOnStartup else {
                    if status.running {
                        Task { await self.refreshQuotas(force: true) }
                    }
                    return
                }
                guard status.installed, !status.running else {
                    if status.running {
                        Task { await self.refreshQuotas(force: true) }
                    }
                    return
                }
                self.startCore()
            }
        }
    }

    private func randomToken(length: Int) -> String {
        SecureToken.generate(length: length)
    }
}
