import AppKit
import SwiftUI

/// 使用记录：分析仪表盘 — KPI、Token 构成、柱状趋势、分类占比、事件时间线、定价。
struct UsageRecordsPageView: View {
    @Environment(AppState.self) private var appState

    @State private var tab: Tab = .overview
    @State private var range: UsageRange = .twentyFourHours
    /// Raw provider key; empty = all.
    @State private var providerFilter = ""
    @State private var providerOptions: [String] = []
    @State private var overview = UsageOverview()
    @State private var analysis = UsageAnalysis()
    @State private var events = UsageEventPage()
    @State private var pricing = UsagePricing()
    @State private var eventPage = 1
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var showMaintenance = false
    @State private var pendingCleanup: CleanupAction?
    /// Skips the debounce on the first load so opening the page is not delayed.
    @State private var hasLoadedOnce = false

    private var activeProvider: String? {
        let p = providerFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? nil : p
    }

    private enum CleanupAction {
        case olderThan30Days
        case all
    }

    private enum Tab: String, CaseIterable, Identifiable {
        case overview, analysis, events, pricing
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return "概览"
            case .analysis: return "分析"
            case .events: return "事件"
            case .pricing: return "定价"
            }
        }
        var icon: String {
            switch self {
            case .overview: return "chart.bar.fill"
            case .analysis: return "chart.pie.fill"
            case .events: return "list.bullet.rectangle"
            case .pricing: return "dollarsign.circle.fill"
            }
        }
    }

    var body: some View {
        PageContainer(layout: .fill) {
            VStack(spacing: 0) {
                toolbar
                    .padding(.horizontal, AppDesign.pagePadding)
                    .padding(.top, AppDesign.pagePadding)
                    .padding(.bottom, 12)

                Divider().opacity(0.5)

                Group {
                    switch tab {
                    case .overview: overviewBody
                    case .analysis: analysisBody
                    case .events: eventsBody
                    case .pricing: pricingBody
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(AppDesign.pagePadding)
            }
        }
        .navigationTitle("使用记录")
        .sheet(isPresented: $showMaintenance) {
            maintenanceSheet
        }
        .confirmDestructive(
            $pendingCleanup,
            title: "清理使用记录？",
            confirmLabel: { _ in cleanupButtonTitle },
            message: { _ in "清理后无法恢复，建议先导出 CSV。" },
            action: { performCleanup($0) }
        )
        .task(id: "\(range.rawValue)-\(tab.rawValue)-\(appState.usageRevision)-\(eventPage)-\(providerFilter)") {
            await reload()
        }
        .onChange(of: providerFilter) { _, _ in
            eventPage = 1
        }
        .onChange(of: range) { _, _ in
            eventPage = 1
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                collectorBadge
                Spacer()
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Button {
                    Task { await reload() }
                } label: {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isLoading)
                Menu {
                    Button("导出当前范围 CSV") { exportCSV() }
                    Button("打开数据库目录") {
                        NSWorkspace.shared.open(AppPaths.usageDatabaseURL.deletingLastPathComponent())
                    }
                    Divider()
                    Button("数据管理…") { showMaintenance = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }

            HStack(spacing: 12) {
                Picker("范围", selection: $range) {
                    ForEach(UsageRange.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 160)

                Picker("Provider", selection: $providerFilter) {
                    Text("全部 Provider").tag("")
                    ForEach(providerOptions, id: \.self) { label in
                        Text(label).tag(label)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
                .layoutPriority(-1)
                .help("按归属过滤：API Provider 含其聊天与原生 GPT 两条腿，Codex 订阅只含订阅")

                HStack(spacing: 6) {
                    ForEach(Tab.allCases) { item in
                        tabChip(item)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)

                Spacer(minLength: 0)

                if let activeProvider {
                    Text(activeProvider)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .frame(maxWidth: 1100)
        .frame(maxWidth: .infinity)
    }

    private func tabChip(_ item: Tab) -> some View {
        let selected = tab == item
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) { tab = item }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: item.icon)
                    .font(.caption)
                Text(item.title)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                selected ? Color.accentColor : Color.secondary.opacity(0.12),
                in: Capsule()
            )
            .foregroundStyle(selected ? Color.white : Color.primary)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
    }

    private var collectorBadge: some View {
        let status = appState.usageCollectorStatus
        return HStack(spacing: 8) {
            Circle()
                .fill(collectorColor(status.state))
                .frame(width: 8, height: 8)
            Text(status.message)
                .font(.subheadline.weight(.medium))
            Text("\(status.totalRecords) 条")
                .font(.caption.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
    }

    // MARK: - Overview

    private var overviewBody: some View {
        Group {
            if overview.totalRequests == 0 && !isLoading {
                CenteredEmptyState(
                    systemImage: "chart.bar",
                    title: "暂无请求数据",
                    message: "内核有流量后，这里会显示用量、趋势与费用"
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        kpiGrid
                        HStack(alignment: .top, spacing: 16) {
                            tokenComposition
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            secondaryStats
                                .frame(width: 260)
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        if activeProvider == nil {
                            providerBreakdownCard
                        }
                        timelineCard
                    }
                    .frame(maxWidth: 1100)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private var kpiGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ],
            spacing: 12
        ) {
            kpi("请求", "\(overview.totalRequests)", "arrow.left.arrow.right", .primary)
            kpi("成功率", String(format: "%.1f%%", overview.successRate), "checkmark.seal.fill", .green)
            kpi("总 Token", formatInt(overview.totalTokens), "number", .primary)
            kpi("费用", String(format: "$%.3f", overview.estimatedCost), "dollarsign.circle", .orange)
            kpi("RPM", String(format: "%.1f", overview.rpm), "speedometer", .blue)
            kpi("均延迟", String(format: "%.0f ms", overview.averageLatencyMs), "clock", .secondary)
        }
    }

    private func kpi(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(tint.opacity(0.85))
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        }
    }

    /// Denominator for composition charts: sum of displayed parts (not totalTokens,
    /// which can be lower when reasoning/cache are counted separately).
    private var tokenCompositionTotal: Int {
        max(
            overview.inputTokens
                + overview.outputTokens
                + overview.reasoningTokens
                + overview.cacheReadTokens,
            1
        )
    }

    private var tokenComposition: some View {
        let parts: [(String, Int, Color)] = [
            ("输入", overview.inputTokens, .blue),
            ("输出", overview.outputTokens, .green),
            ("推理", overview.reasoningTokens, .purple),
            ("缓存读", overview.cacheReadTokens, .cyan),
        ]
        return GlassCard(padding: 18, fillHeight: true) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Token 构成")
                        .font(.headline)
                    Spacer()
                    Text("合计 \(formatInt(tokenCompositionTotal))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                tokenBar(parts: parts)
                    .frame(height: 14)
                    .clipShape(Capsule())

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 10
                ) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        tokenStat(part.0, part.1, part.2)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func tokenStat(_ title: String, _ value: Int, _ color: Color) -> some View {
        let denom = tokenCompositionTotal
        let pct = Double(value) / Double(denom) * 100
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", pct))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(formatInt(value))
                .font(.body.monospacedDigit().weight(.semibold))

            // Per-category share bar (relative to composition sum).
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(color.opacity(0.85))
                        .frame(width: max(value > 0 ? 4 : 0, geo.size.width * CGFloat(value) / CGFloat(denom)))
                }
            }
            .frame(height: 5)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func tokenBar(parts: [(String, Int, Color)]) -> some View {
        let denom = max(tokenCompositionTotal, 1)
        let visible = parts.filter { $0.1 > 0 }
        return GeometryReader { geo in
            let gap: CGFloat = visible.count > 1 ? 2 : 0
            let usable = max(0, geo.size.width - gap * CGFloat(max(visible.count - 1, 0)))
            HStack(spacing: gap) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, part in
                    // Strict proportion of composition sum — never exceeds container width.
                    let w = usable * CGFloat(part.1) / CGFloat(denom)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(part.2.opacity(0.9))
                        .frame(width: max(w, 0))
                        .help("\(part.0)：\(formatInt(part.1))")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
    }

    private var secondaryStats: some View {
        GlassCard(padding: 18, fillHeight: true) {
            VStack(alignment: .leading, spacing: 14) {
                Text("吞吐 · 缓存")
                    .font(.headline)
                statLine("TPM", String(format: "%.0f", overview.tpm))
                statLine("TPS", String(format: "%.1f", overview.tps))
                statLine("缓存命中", String(format: "%.1f%%", overview.cacheHitRate))
                statLine("缓存读", formatInt(overview.cacheReadTokens))
                statLine("缓存写", formatInt(overview.cacheCreationTokens))
                statLine("成功 / 失败", "\(overview.successCount) / \(overview.failureCount)")
                statLine("有价请求", "\(overview.pricedRequests)")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var providerBreakdownCard: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("按 Provider", systemImage: "building.2")
                        .font(.headline)
                    Spacer()
                    Text("点击可筛选")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if overview.providers.isEmpty {
                    Text("暂无 Provider 数据")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                } else {
                    let maxReq = max(overview.providers.map(\.requests).max() ?? 1, 1)
                    ForEach(overview.providers.prefix(8)) { item in
                        Button {
                            providerFilter = item.key
                            eventPage = 1
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(item.label)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(item.requests) 次")
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                    Text(formatInt(item.tokens))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 10) {
                                    Text(String(format: "成功率 %.0f%%", item.successRate))
                                    Text(String(format: "缓存命中 %.1f%%", item.cacheHitRate))
                                    if item.cacheReadTokens > 0 {
                                        Text("cache \(formatInt(item.cacheReadTokens))")
                                    }
                                }
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)

                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.primary.opacity(0.06))
                                        Capsule()
                                            .fill(Color.accentColor.opacity(0.75))
                                            .frame(
                                                width: max(
                                                    4,
                                                    geo.size.width * CGFloat(item.requests) / CGFloat(maxReq)
                                                )
                                            )
                                    }
                                }
                                .frame(height: 5)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func statLine(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
        }
    }

    private var timelineCard: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("请求趋势")
                        .font(.headline)
                    Spacer()
                    Text("\(overview.timeline.count) 个时段")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if overview.timeline.isEmpty {
                    Text("暂无时间序列")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
                } else {
                    timelineChart
                        .frame(height: 168)
                }
            }
        }
    }

    private var timelineChart: some View {
        let points = Array(overview.timeline.suffix(24))
        let maxReq = max(points.map(\.requests).max() ?? 1, 1)
        let sparse = points.count <= 3

        return GeometryReader { geo in
            let count = max(points.count, 1)
            let spacing: CGFloat = sparse ? 12 : 6
            // Cap bar width so a single bucket never becomes a full-width slab.
            let natural = (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
            let barWidth = min(sparse ? 40 : 28, max(8, natural))
            let chartHeight = geo.size.height - 28 // room for labels

            VStack(spacing: 0) {
                // Baseline grid
                ZStack(alignment: .bottom) {
                    VStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { i in
                            if i > 0 { Spacer(minLength: 0) }
                            Rectangle()
                                .fill(Color.primary.opacity(0.05))
                                .frame(height: 1)
                        }
                    }
                    .frame(height: chartHeight)

                    HStack(alignment: .bottom, spacing: spacing) {
                        ForEach(points) { point in
                            let ratio = CGFloat(point.requests) / CGFloat(maxReq)
                            let h = max(point.requests > 0 ? 8 : 2, chartHeight * 0.82 * ratio)
                            VStack(spacing: 4) {
                                if point.requests > 0 {
                                    Text("\(point.requests)")
                                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color.accentColor.opacity(0.95),
                                                Color.accentColor.opacity(0.55),
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .frame(width: barWidth, height: h)
                                    .help("\(point.hour)：\(point.requests) 次")
                            }
                            .frame(width: barWidth, height: chartHeight, alignment: .bottom)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: sparse ? .center : .leading)
                }
                .frame(height: chartHeight)

                // X labels
                HStack(spacing: spacing) {
                    ForEach(points) { point in
                        Text(shortHourLabel(point.hour))
                            .font(.system(size: 9).monospaced())
                            .foregroundStyle(.tertiary)
                            .frame(width: barWidth)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: sparse ? .center : .leading)
                .padding(.top, 8)
            }
        }
    }

    private func shortHourLabel(_ hour: String) -> String {
        // Accept "2026-07-30 19:00" or "19:00" or trailing hour tokens.
        if hour.count >= 5, hour.contains(":") {
            return String(hour.suffix(5))
        }
        return hour
    }

    // MARK: - Analysis

    private var analysisBody: some View {
        Group {
            if analysis.models.isEmpty && analysis.providers.isEmpty && !isLoading {
                CenteredEmptyState(systemImage: "chart.pie", title: "暂无分析数据")
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                        spacing: 14
                    ) {
                        categoryCard("模型", "cpu", analysis.models, showCache: true)
                        categoryCard(
                            "Provider",
                            "building.2",
                            analysis.providers,
                            showCache: true,
                            filterableProvider: true
                        )
                        categoryCard("来源", "arrow.triangle.branch", analysis.sources)
                        categoryCard("API Key", "key.fill", analysis.apiKeys, showCache: true)
                    }
                    .frame(maxWidth: 1100)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func categoryCard(
        _ title: String,
        _ icon: String,
        _ items: [UsageCategory],
        showCache: Bool = false,
        filterableProvider: Bool = false
    ) -> some View {
        let maxReq = max(items.map(\.requests).max() ?? 1, 1)
        return GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: icon)
                    .font(.headline)

                if items.isEmpty {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                } else {
                    ForEach(items.prefix(8)) { item in
                        Button {
                            if filterableProvider {
                                providerFilter = item.key
                                eventPage = 1
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.label)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(item.requests)")
                                        .font(.subheadline.monospacedDigit().weight(.semibold))
                                    Text(formatInt(item.tokens))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 56, alignment: .trailing)
                                }
                                if showCache {
                                    HStack(spacing: 8) {
                                        Text(String(format: "成功率 %.0f%%", item.successRate))
                                        Text(String(format: "缓存 %.1f%%", item.cacheHitRate))
                                        if item.cacheReadTokens > 0 {
                                            Text("读 \(formatInt(item.cacheReadTokens))")
                                        }
                                    }
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                }
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.secondary.opacity(0.12))
                                        Capsule()
                                            .fill(Color.accentColor.opacity(0.75))
                                            .frame(
                                                width: max(
                                                    4,
                                                    geo.size.width * CGFloat(item.requests) / CGFloat(maxReq)
                                                )
                                            )
                                    }
                                }
                                .frame(height: 5)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!filterableProvider)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        }
    }

    // MARK: - Events

    private var eventsBody: some View {
        VStack(spacing: 12) {
            HStack {
                Text("\(events.total) 条事件")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    eventPage = max(1, eventPage - 1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(eventPage <= 1)
                Text("\(events.page) / \(max(events.totalPages, 1))")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 48)
                Button {
                    eventPage = min(max(events.totalPages, 1), eventPage + 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(eventPage >= events.totalPages)
            }
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)

            if events.items.isEmpty && !isLoading {
                CenteredEmptyState(systemImage: "list.bullet", title: "暂无事件")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(events.items) { item in
                            eventRow(item)
                        }
                    }
                    .frame(maxWidth: 1100)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func eventRow(_ item: UsageRecord) -> some View {
        GlassCard(padding: 12) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(item.failed ? Color.red : Color.green)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(item.model)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if item.failed {
                            Text("失败")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.red.opacity(0.12), in: Capsule())
                        }
                        Spacer()
                        Text(item.timestamp)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        if !item.provider.isEmpty {
                            chip(item.providerDisplayName)
                                .help(item.provider)
                        }
                        if !item.source.isEmpty {
                            chip(item.sourceDisplay)
                        }
                        Spacer()
                        Text("\(item.latencyMs) ms")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(latencyColor(item.latencyMs))
                        Text("in \(formatInt(item.tokens.inputTokens)) · out \(formatInt(item.tokens.outputTokens))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if item.tokens.cacheReadTokens > 0 {
                            Text(String(
                                format: "cache %@ · %.0f%%",
                                formatInt(item.tokens.cacheReadTokens),
                                item.cacheHitRatePercent
                            ))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.cyan)
                        }
                    }
                }
            }
        }
    }

    private func latencyColor(_ ms: Int) -> Color {
        if ms >= 5000 { return .red }
        if ms >= 2000 { return .orange }
        return .secondary
    }

    // MARK: - Pricing

    private var pricingBody: some View {
        Group {
            if pricing.rows.isEmpty && !isLoading {
                CenteredEmptyState(systemImage: "dollarsign.circle", title: "暂无定价数据")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12),
                            ],
                            spacing: 12
                        ) {
                            kpi("总费用", String(format: "$%.4f", pricing.totalCost), "dollarsign.circle.fill", .orange)
                            kpi("有价请求", "\(pricing.pricedRequests)", "checkmark.circle", .primary)
                            kpi("模型数", "\(pricing.rows.count)", "square.stack.3d.up", .primary)
                        }

                        ForEach(pricing.rows) { row in
                            GlassCard(padding: 14) {
                                HStack(spacing: 14) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 8) {
                                            Text(row.model)
                                                .font(.subheadline.weight(.semibold))
                                            chip(row.providerDisplayName)
                                                .help(row.provider)
                                        }
                                        Text("\(row.requests) 次 · \(formatInt(row.totalTokens)) tokens")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        HStack(spacing: 10) {
                                            Text("in \(formatInt(row.inputTokens))")
                                            Text("out \(formatInt(row.outputTokens))")
                                            if row.cacheReadTokens > 0 {
                                                Text(String(
                                                    format: "cache %@ · %.0f%%",
                                                    formatInt(row.cacheReadTokens),
                                                    row.cacheHitRate
                                                ))
                                            }
                                        }
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    Text(String(format: "$%.4f", row.estimatedCost))
                                        .font(.title3.monospacedDigit().weight(.bold))
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 1100)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    // MARK: - Shared

    private var maintenanceSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("使用记录管理").font(.title3.bold())
            HStack {
                Text("数据库大小")
                Spacer()
                Text(ByteCountFormatter.string(
                    fromByteCount: appState.usageDatabaseSizeBytes(),
                    countStyle: .file
                ))
                .monospacedDigit()
            }
            .padding(12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

            Text("可以导出当前筛选范围，或清理过期记录。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("导出当前范围 CSV") { exportCSV() }
                .buttonStyle(.borderedProminent)

            Divider()

            Button("清理 30 天以前的记录", role: .destructive) {
                pendingCleanup = .olderThan30Days
                showMaintenance = false
            }
            Button("删除全部使用记录", role: .destructive) {
                pendingCleanup = .all
                showMaintenance = false
            }
            Spacer()
            HStack {
                Spacer()
                Button("关闭") { showMaintenance = false }
            }
        }
        .padding(24)
        .frame(minWidth: 440, minHeight: 300)
    }

    private var cleanupButtonTitle: String {
        switch pendingCleanup {
        case .olderThan30Days: return "清理 30 天以前记录"
        case .all: return "删除全部记录"
        case nil: return "清理"
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let providerSuffix = activeProvider.map { "-\($0)" } ?? ""
        panel.nameFieldStringValue = "maccliproxy-usage-\(range.rawValue)\(providerSuffix).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // The menu item says 「当前范围」, which the UI presents as time range + provider.
            let count = try appState.exportUsageCSV(to: url, range: range, provider: activeProvider)
            let scope = activeProvider.map { "（\($0)）" } ?? ""
            appState.flash("已导出 \(count) 条使用记录\(scope)")
        } catch {
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func performCleanup(_ action: CleanupAction?) {
        do {
            let cutoff: Date?
            switch action {
            case .olderThan30Days:
                cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
            case .all:
                cutoff = nil
            case nil:
                return
            }
            let deleted = try appState.clearUsageRecords(olderThan: cutoff)
            appState.flash("已清理 \(deleted) 条使用记录")
            Task { await reload() }
        } catch {
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    private func reload() async {
        // The collector bumps `usageRevision` on every saved batch, and `task(id:)` cancels the
        // previous run, so waiting here collapses a burst of arrivals into one set of queries.
        if hasLoadedOnce {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
        }
        isLoading = true
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        errorMessage = nil
        do {
            // Keep filter options for the selected time range (unscoped by provider).
            providerOptions = try await appState.usageProviderOptions(range: range)
            if !providerFilter.isEmpty, !providerOptions.contains(providerFilter) {
                providerFilter = ""
            }
            let provider = activeProvider
            switch tab {
            case .overview:
                overview = try await appState.usageOverview(range: range, provider: provider)
            case .analysis:
                analysis = try await appState.usageAnalysis(range: range, provider: provider)
            case .events:
                events = try await appState.usageEvents(
                    range: range,
                    page: eventPage,
                    provider: provider
                )
            case .pricing:
                pricing = try await appState.usagePricing(range: range, provider: provider)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func collectorColor(_ state: String) -> Color {
        switch state {
        case "collecting": return .green
        case "error": return .red
        default: return .orange
        }
    }

    private func formatInt(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
