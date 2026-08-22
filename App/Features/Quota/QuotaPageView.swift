import AppKit
import SwiftUI

struct QuotaPageView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        PageContainer(layout: .fill) {
            VStack(spacing: 0) {
                toolbar
                    .padding(.horizontal, AppDesign.pagePadding)
                    .padding(.top, AppDesign.pagePadding)
                    .padding(.bottom, 12)

                Divider().opacity(0.45)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        providerQuotaSection
                    }
                    .padding(AppDesign.pagePadding)
                    .frame(maxWidth: 960)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("配额")
        .task {
            await appState.refreshQuotas(force: false)
        }
    }

    private var toolbar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("配额")
                    .font(.title3.weight(.semibold))
                Text("各 Provider 账号额度")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task {
                    await appState.refreshQuotas(force: true)
                }
            } label: {
                if appState.quotaSnapshot.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .disabled(appState.quotaSnapshot.isRefreshing)
        }
        .frame(maxWidth: 960)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Provider accounts

    @ViewBuilder
    private var providerQuotaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Provider 账号", systemImage: "person.2.fill")
                .font(.headline)

            if !appState.coreStatus.running {
                GlassCard(padding: 18) {
                    Text("启动内核后可查看 OAuth 账号配额")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                }
            } else if appState.quotaSnapshot.isRefreshing && appState.quotaSnapshot.accounts.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if appState.quotaSnapshot.accounts.isEmpty {
                GlassCard(padding: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("暂无 Provider 配额数据")
                            .font(.subheadline.weight(.semibold))
                        Text("完成 OAuth 后在此查看各账号用量")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("刷新") {
                            Task { await appState.refreshQuotas(force: true) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                summaryStrip
                LazyVStack(spacing: 12) {
                    ForEach(appState.quotaSnapshot.accounts) { account in
                        accountCard(account)
                    }
                }
            }
        }
    }

    private var summaryStrip: some View {
        let accounts = appState.quotaSnapshot.accounts
        let low = accounts.filter(\.isLow).count
        let ok = accounts.filter { $0.status == .success }.count
        let avg = appState.quotaSnapshot.overallRemainingPercent

        return LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ],
            spacing: 12
        ) {
            MetricTile(title: "账号", value: "\(accounts.count)", tint: .primary, icon: "person.2")
            MetricTile(title: "正常", value: "\(ok)", tint: .green, icon: "checkmark.circle")
            MetricTile(title: "偏低", value: "\(low)", tint: low > 0 ? .orange : .secondary, icon: "exclamationmark.triangle")
            MetricTile(
                title: "最低剩余",
                value: avg.map { String(format: "%.0f%%", $0) } ?? "—",
                tint: color(for: avg ?? 100),
                icon: "gauge.with.dots.needle.33percent"
            )
        }
    }

    private func accountCard(_ account: AccountQuotaSummary) -> some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ProviderIconView(provider: account.provider.rawValue, size: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(account.displayName)
                                .font(.headline)
                                .lineLimit(1)
                            if let plan = account.plan, !plan.isEmpty {
                                Text(plan)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                        }
                        Text(account.provider.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let percent = account.primaryRemainingPercent {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.0f%%", percent))
                                .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(color(for: percent))
                            Text("剩余")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    } else if let text = account.primaryDisplayText {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(text)
                                .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Text(primaryDisplayCaption(account))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                if account.status == .error {
                    Text(account.error ?? "查询失败")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                ForEach(account.metrics) { metric in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(metric.label)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            if let percent = metric.remainingPercent {
                                Text(String(format: "%.0f%%", percent))
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(color(for: percent))
                            }
                        }
                        if let percent = metric.remainingPercent {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.secondary.opacity(0.12))
                                    Capsule()
                                        .fill(color(for: percent).opacity(0.85))
                                        .frame(width: max(6, geo.size.width * percent / 100))
                                }
                            }
                            .frame(height: 8)
                        }
                        if let detail = metric.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if let reset = metric.reset {
                            Text(reset)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func primaryDisplayCaption(_ account: AccountQuotaSummary) -> String {
        if account.metrics.contains(where: { $0.label.contains("已用") }) {
            return "已用"
        }
        return "余额"
    }

    private func color(for percent: Double) -> Color {
        if percent < 15 { return .red }
        if percent < 35 { return .orange }
        return .green
    }
}
