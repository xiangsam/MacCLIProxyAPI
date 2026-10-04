import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ModelCapabilitiesPageView: View {
    @Environment(AppState.self) private var appState
    @State private var snapshot: ModelCapabilitySnapshot?
    @State private var search = ""
    @State private var reasoningOnly = false
    @State private var imageInputOnly = false
    @State private var refreshing = false
    @State private var errorMessage: String?
    @State private var selected: ModelCapabilityRecord?

    init(initialSnapshot: ModelCapabilitySnapshot? = nil) {
        _snapshot = State(initialValue: initialSnapshot)
    }

    private var filtered: [ModelCapabilityRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (snapshot?.models ?? []).filter { model in
            (!reasoningOnly || model.reasoning == true)
                && (!imageInputOnly || model.inputModalities?.contains("image") == true)
                && (query.isEmpty || "\(model.id) \(model.name)".localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("搜索模型名称或规范 ID", text: $search).textFieldStyle(.roundedBorder)
                Toggle("支持思考", isOn: $reasoningOnly)
                Toggle("图片输入", isOn: $imageInputOnly)
                Button("同步 models.dev") { Task { await refresh() } }.disabled(refreshing)
                Menu("JSON") {
                    Button("复制完整列表路径") { copy(ModelCapabilityStore.cacheURL.path) }
                    Button("导出筛选结果…") { exportFiltered() }
                }.disabled(snapshot == nil)
            }
            if let snapshot {
                Text("\(filtered.count) / \(snapshot.models.count) 个模型 · 同步于 \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("一个规范模型一条记录。思考等级为各接入方声明的合集，实际参数请查看详情；上下文与模态显示模型本身的资料，具体上游可能有限制。未提供的字段不做推测。")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.orange) }
            if refreshing { ProgressView().controlSize(.small) }
            if snapshot == nil && !refreshing {
                CenteredEmptyState(systemImage: "list.bullet.rectangle", title: "尚无模型能力缓存",
                    message: "同步 models.dev 后可离线查看，也可将 JSON 提供给 harness agent。",
                    actionTitle: "同步模型能力") { Task { await refresh() } }
            } else {
                Table(filtered, selection: Binding<Set<String>>(
                    get: { Set(selected.map { [$0.id] } ?? []) },
                    set: { ids in selected = filtered.first { ids.contains($0.id) } }
                )) {
                    TableColumn("模型") { model in
                        VStack(alignment: .leading) {
                            Text(model.name)
                            Text(model.id).font(.caption).foregroundStyle(.secondary)
                        }
                    }.width(min: 200, ideal: 280)
                    TableColumn("上下文（tokens）") { Text(tokenText($0.contextWindow)) }.width(110)
                    TableColumn("输入模态") { Text($0.inputModalities?.joined(separator: ", ") ?? "未提供") }
                    TableColumn("思考等级／控制") { Text($0.reasoningSummary).lineLimit(2) }
                    TableColumn("详情") { model in
                        Button("查看") { selected = model }.buttonStyle(.borderless)
                    }.width(50)
                }
            }
            HStack {
                Link("来源：models.dev", destination: URL(string: "https://models.dev/models/")!)
                Spacer()
                Text("本地 JSON 不包含账号、密钥或客户端配置")
                    .foregroundStyle(.secondary)
            }.font(.caption)
        }
        .padding(AppDesign.pagePadding)
        .navigationTitle("模型能力")
        .task {
            guard snapshot == nil else { return }
            do { snapshot = try ModelCapabilityStore.load() }
            catch { errorMessage = error.localizedDescription }
        }
        .sheet(item: $selected) { model in detail(model) }
    }

    private func detail(_ model: ModelCapabilityRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text(model.name).font(.title2.bold())
                    Text(model.id).font(.caption.monospaced()).textSelection(.enabled)
                }
                Spacer()
                Button("复制记录 JSON") {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    if let data = try? encoder.encode(model), let text = String(data: data, encoding: .utf8) { copy(text) }
                }
                Button("关闭") { selected = nil }.keyboardShortcut(.cancelAction)
            }
            Text("上下文 \(tokenText(model.contextWindow)) · 最大输入 \(tokenText(model.maxInputTokens)) · 最大输出 \(tokenText(model.maxOutputTokens)) tokens")
            Text("输入：\(model.inputModalities?.joined(separator: ", ") ?? "未提供")；输出：\(model.outputModalities?.joined(separator: ", ") ?? "未提供")")
            Text("工具调用：\(booleanText(model.toolCall)) · 结构化输出：\(booleanText(model.structuredOutput)) · 来源更新：\(model.sourceUpdatedAt ?? "未提供")")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let description = model.description { Text(description).textSelection(.enabled) }
                    Text("接入方能力差异").font(.headline)
                    if model.providerVariants.isEmpty { Text("来源没有提供关联的接入方记录。") }
                    ForEach(model.providerVariants) { variant in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(variant.providerName) · \(variant.providerModelID)").font(.subheadline.bold())
                            Text("思考：\(booleanText(variant.reasoning)) · \(controls(variant))")
                            Text("上下文 \(tokenText(variant.contextWindow)) · 最大输入 \(tokenText(variant.maxInputTokens)) · 最大输出 \(tokenText(variant.maxOutputTokens))")
                            Text("输入 \(variant.inputModalities?.joined(separator: ", ") ?? "未提供") · 输出 \(variant.outputModalities?.joined(separator: ", ") ?? "未提供")")
                        }.font(.caption).textSelection(.enabled)
                        Divider()
                    }
                }
            }
            if let url = URL(string: model.sourceURL) { Link("查看 models.dev 原始模型页", destination: url) }
        }
        .padding(24).frame(width: 780, height: 580)
    }

    private func controls(_ variant: ModelCapabilityVariant) -> String {
        guard let options = variant.reasoningOptions else { return "未提供控制参数" }
        return options.isEmpty ? "来源未列出可配置档位" : options.map(\.summary).joined(separator: "；")
    }
    private func tokenText(_ count: Int?) -> String { count.map { $0.formatted() } ?? "未提供" }
    private func booleanText(_ value: Bool?) -> String { value.map { $0 ? "支持" : "不支持" } ?? "未提供" }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appState.flash("已复制")
    }
    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            snapshot = try await ModelCapabilityStore.refresh()
            errorMessage = nil
            appState.flash("已同步 \(snapshot?.models.count ?? 0) 个规范模型，JSON 已保存")
        } catch { errorMessage = "同步失败，已有缓存保持不变：\(error.localizedDescription)" }
    }
    private func exportFiltered() {
        guard var export = snapshot else { return }
        export.models = filtered
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "model-capabilities.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ModelCapabilityStore.encoded(export).write(to: url, options: .atomic)
            appState.flash("已导出 \(export.models.count) 条模型记录")
        } catch { appState.flash(error.localizedDescription, error: true) }
    }
}
