import AppKit
import SwiftUI

struct OAuthPageView: View {
    @Environment(AppState.self) private var appState
    @State private var activeProvider: OAuthProvider?
    @State private var authURL = ""
    @State private var stateToken = ""
    @State private var callbackURL = ""
    @State private var statusText = ""
    @State private var busyProvider: OAuthProvider?
    @State private var pollTask: Task<Void, Never>?
    @State private var showFlowSheet = false

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 14),
    ]

    var body: some View {
        PageContainer(layout: .fill) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    providerGrid
                    tipCard
                }
                .padding(AppDesign.pagePadding)
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("OAuth")
        .sheet(isPresented: $showFlowSheet) {
            flowSheet
        }
        .onDisappear { pollTask?.cancel() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("提供商授权")
                    .font(.title2.weight(.bold))
                Text("完成后凭证会出现在「认证文件」")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let busy = busyProvider, !statusText.isEmpty, !showFlowSheet {
                StatusPill(text: "\(busy.title) · \(statusText)", tone: statusTone)
            }
        }
    }

    private var providerGrid: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(OAuthProvider.allCases) { provider in
                providerCard(provider)
            }
        }
    }

    private func providerCard(_ provider: OAuthProvider) -> some View {
        let isBusy = busyProvider == provider
        return Button {
            Task { await start(provider) }
        } label: {
            GlassCard(padding: 18) {
                VStack(spacing: 14) {
                    ProviderIconView(provider: provider.brandKey, size: 40)
                    Text(provider.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("授权")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 132)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busyProvider != nil)
        .opacity(busyProvider != nil && !isBusy ? 0.45 : 1)
    }

    private var tipCard: some View {
        GlassCard(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("授权需在浏览器中完成")
                        .font(.subheadline.weight(.medium))
                    Text("部分提供商支持粘贴回调 URL；成功后可在认证文件中管理凭证")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var flowSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                if let p = activeProvider {
                    ProviderIconView(provider: p.brandKey, size: 28)
                    Text("\(p.title) 授权")
                        .font(.title3.weight(.semibold))
                }
                Spacer()
                StatusPill(text: statusText.isEmpty ? "进行中" : statusText, tone: statusTone)
            }

            if !authURL.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("授权链接")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(authURL)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    HStack(spacing: 8) {
                        AppControlButton(title: "打开浏览器", systemImage: "safari", kind: .primary) {
                            if let url = URL(string: authURL) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        AppControlButton(title: "复制链接", systemImage: "doc.on.doc", kind: .secondary) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(authURL, forType: .string)
                        }
                    }
                }
            }

            if activeProvider?.supportsCallbackPaste == true {
                VStack(alignment: .leading, spacing: 8) {
                    Text("手动回调（可选）")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("粘贴回调 URL", text: $callbackURL)
                        .textFieldStyle(.roundedBorder)
                    AppControlButton(
                        title: "提交回调",
                        systemImage: "arrow.up.doc",
                        kind: .secondary,
                        isEnabled: !callbackURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        Task { await submitCallback() }
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button("关闭") {
                    showFlowSheet = false
                    resetFlow(keepStatus: true)
                }
                Spacer()
                Button("检查状态") {
                    Task { await refreshStatus() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(stateToken.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 380)
    }

    private var statusTone: StatusPill.Tone {
        let s = statusText.lowercased()
        if s.contains("成功") { return .success }
        if s.contains("失败") || s.contains("error") { return .danger }
        if s.contains("等待") { return .info }
        return .neutral
    }

    private func start(_ provider: OAuthProvider) async {
        activeProvider = provider
        busyProvider = provider
        statusText = "启动中…"
        authURL = ""
        stateToken = ""
        callbackURL = ""
        do {
            let result = try await OAuthService.start(provider: provider, client: appState.managementClient())
            authURL = result.url
            stateToken = result.state
            statusText = result.opened ? "等待授权…" : "已获取链接"
            showFlowSheet = true
            if !result.state.isEmpty {
                startPolling()
            }
        } catch {
            statusText = error.localizedDescription
            appState.flash(error.localizedDescription, error: true)
            busyProvider = nil
        }
    }

    private func refreshStatus() async {
        guard !stateToken.isEmpty else { return }
        do {
            let result = try await OAuthService.status(state: stateToken, client: appState.managementClient())
            switch OAuthService.classifyStatus(result.status) {
            case .success:
                completeConfirmedSuccess()
                showFlowSheet = false
            case .failure:
                statusText = result.error.map { "失败：\($0)" } ?? "授权失败"
                pollTask?.cancel()
                busyProvider = nil
            case .pending:
                statusText = "等待授权…"
            case .unknown:
                statusText = result.status
            }
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func submitCallback() async {
        guard let provider = activeProvider else { return }
        do {
            try await OAuthService.submitCallback(
                provider: provider,
                redirectURL: callbackURL,
                client: appState.managementClient()
            )
            if !stateToken.isEmpty {
                statusText = "回调已提交，正在确认…"
                await refreshStatus()
                return
            }
            statusText = "回调已提交，请等待内核完成授权"
        } catch {
            statusText = error.localizedDescription
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func completeConfirmedSuccess() {
        let providerName = activeProvider?.title ?? "OAuth"
        pollTask?.cancel()
        statusText = "授权成功"
        appState.flash("\(providerName) 授权成功")
        resetFlow(keepStatus: false)
    }

    private func resetFlow(keepStatus: Bool) {
        pollTask?.cancel()
        authURL = ""
        stateToken = ""
        callbackURL = ""
        busyProvider = nil
        activeProvider = nil
        if !keepStatus {
            statusText = ""
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            for _ in 0..<90 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                await refreshStatus()
                if statusText.contains("成功") {
                    showFlowSheet = false
                    return
                }
            }
            if !Task.isCancelled {
                statusText = "等待超时，请检查授权状态"
                busyProvider = nil
            }
        }
    }
}

private extension OAuthProvider {
    var brandKey: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        case .antigravity: return "antigravity"
        case .kimi: return "kimi"
        case .xai: return "grok"
        }
    }
}
