import AppKit
import SwiftUI

struct DiagnosticsPageView: View {
    @Environment(AppState.self) private var appState
    @State private var checks: [DiagnosticCheck] = []
    @State private var running = false

    var body: some View {
        PageContainer(layout: .feed, maxWidth: 960) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("系统诊断").font(.title2.bold())
                        Text("检查内核、管理接口、文件权限和本地数据")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await runChecks() }
                    } label: {
                        running ? AnyView(ProgressView().controlSize(.small))
                            : AnyView(Label("重新检查", systemImage: "arrow.clockwise"))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(running)
                }

                ForEach(checks) { check in
                    GlassCard(padding: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: icon(check.level))
                                .font(.title3)
                                .foregroundStyle(color(check.level))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(check.title).font(.headline)
                                Text(check.detail)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            StatusPill(text: label(check.level), tone: tone(check.level))
                        }
                    }
                }

                HStack {
                    Button("打开数据目录") {
                        NSWorkspace.shared.open(AppPaths.baseDirectory)
                    }
                    Button("打开使用记录目录") {
                        NSWorkspace.shared.open(AppPaths.usageDatabaseURL.deletingLastPathComponent())
                    }
                    Spacer()
                    Text(summary)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(summaryColor)
                }
            }
        }
        .navigationTitle("诊断")
        .task { await runChecks() }
    }

    private func runChecks() async {
        running = true
        appState.refreshStatus()
        checks = await DiagnosticService.run(
            coreStatus: appState.coreStatus,
            gui: appState.guiConfig.snapshotFresh(),
            client: appState.managementClient()
        )
        running = false
    }

    private var summary: String {
        let failed = checks.filter { $0.level == .fail }.count
        let warnings = checks.filter { $0.level == .warning }.count
        return failed > 0 ? "\(failed) 项失败" : (warnings > 0 ? "\(warnings) 项提醒" : "全部正常")
    }

    private var summaryColor: Color {
        checks.contains(where: { $0.level == .fail }) ? .red
            : (checks.contains(where: { $0.level == .warning }) ? .orange : .green)
    }

    private func icon(_ level: DiagnosticLevel) -> String {
        switch level {
        case .pass: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        }
    }

    private func color(_ level: DiagnosticLevel) -> Color {
        switch level {
        case .pass: return .green
        case .warning: return .orange
        case .fail: return .red
        }
    }

    private func label(_ level: DiagnosticLevel) -> String {
        switch level {
        case .pass: return "正常"
        case .warning: return "提醒"
        case .fail: return "失败"
        }
    }

    private func tone(_ level: DiagnosticLevel) -> StatusPill.Tone {
        switch level {
        case .pass: return .success
        case .warning: return .warning
        case .fail: return .danger
        }
    }
}
