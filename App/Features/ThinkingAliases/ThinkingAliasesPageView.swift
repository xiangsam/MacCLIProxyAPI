import SwiftUI

struct ThinkingAliasesPageView: View {
    @Environment(AppState.self) private var appState
    @State private var aliases: [ThinkingAliasEntry] = []
    @State private var channel: ThinkingAliasService.AliasChannel = .codexOAuth
    @State private var aliasName = ""
    @State private var sourceModel = ""
    @State private var effort = "high"
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var showCreate = false
    @State private var pendingDeleteAlias: String?

    private let efforts = ["low", "medium", "high", "xhigh", "max"]

    var body: some View {
        ListPageScaffold {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("模型别名")
                            .font(.title3.weight(.semibold))
                        Text("为客户端创建可见模型名，并映射推理强度")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("刷新") { Task { await reload() } }
                        .disabled(busy)
                    Button {
                        showCreate = true
                    } label: {
                        Label("创建别名", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } bodyContent: {
            if busy && aliases.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if aliases.isEmpty {
                CenteredEmptyState(
                    systemImage: "arrow.triangle.branch",
                    title: "暂无模型别名",
                    message: "创建后客户端可直接选择别名模型",
                    actionTitle: "创建别名"
                ) {
                    showCreate = true
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(aliases) { item in
                            aliasCard(item)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .navigationTitle("模型别名")
        .sheet(isPresented: $showCreate) {
            createSheet
        }
        .confirmDestructive(
            $pendingDeleteAlias,
            title: "删除模型别名？",
            confirmLabel: { "删除「\($0)」" },
            message: { _ in "引用该别名的客户端配置可能停止工作，此操作不能自动撤销。" },
            action: { alias in Task { await delete(alias: alias) } }
        )
        .task { await reload() }
    }

    private func aliasCard(_ item: ThinkingAliasEntry) -> some View {
        let brand = item.kind.contains("openai") ? "openai" : "codex"
        return GlassCard(padding: 16) {
            HStack(spacing: 14) {
                ProviderIconView(provider: brand, size: 28)
                    .frame(width: 44, height: 44)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.alias)
                        .font(.headline)
                    HStack(spacing: 8) {
                        metaChip(item.sourceModel)
                        if let effort = item.effort {
                            metaChip(effort.uppercased())
                        }
                        metaChip(item.provider)
                    }
                }

                Spacer(minLength: 8)

                Button("删除", role: .destructive) {
                    pendingDeleteAlias = item.alias
                }
                .disabled(busy)
                .controlSize(.small)
            }
        }
    }

    private func metaChip(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .foregroundStyle(.secondary)
    }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("创建别名")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("渠道")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(ThinkingAliasService.AliasChannel.allCases) { item in
                        channelChip(item)
                    }
                }
            }

            TextField("别名（客户端可见名）", text: $aliasName)
                .textFieldStyle(.roundedBorder)
            TextField("源模型", text: $sourceModel)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 8) {
                Text("Effort")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(efforts, id: \.self) { level in
                        effortChip(level)
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button("取消") { showCreate = false }
                Spacer()
                Button("创建") {
                    Task { await create() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(aliasName.isEmpty || sourceModel.isEmpty || busy)
            }
        }
        .padding(24)
        .frame(minWidth: 440, minHeight: 380)
    }

    private func channelChip(_ item: ThinkingAliasService.AliasChannel) -> some View {
        let selected = channel == item
        return Button {
            channel = item
        } label: {
            Text(item.title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    selected ? Color.accentColor : Color.secondary.opacity(0.12),
                    in: Capsule()
                )
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func effortChip(_ level: String) -> some View {
        let selected = effort == level
        return Button {
            effort = level
        } label: {
            Text(level)
                .font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10),
                    in: Capsule()
                )
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .overlay {
                    Capsule()
                        .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func reload() async {
        busy = true
        defer { busy = false }
        errorMessage = nil
        do {
            aliases = try await ThinkingAliasService.list(client: appState.managementClient())
        } catch {
            aliases = []
            errorMessage = error.localizedDescription
        }
    }

    private func create() async {
        busy = true
        defer { busy = false }
        do {
            aliases = try await ThinkingAliasService.createAlias(
                client: appState.managementClient(),
                channel: channel,
                sourceModel: sourceModel,
                alias: aliasName,
                effort: effort
            )
            aliasName = ""
            sourceModel = ""
            showCreate = false
            appState.flash("已创建")
        } catch {
            errorMessage = error.localizedDescription
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func delete(alias: String) async {
        busy = true
        defer { busy = false }
        do {
            aliases = try await ThinkingAliasService.delete(client: appState.managementClient(), alias: alias)
            appState.flash("已删除")
        } catch {
            errorMessage = error.localizedDescription
            appState.flash(error.localizedDescription, error: true)
        }
    }
}
