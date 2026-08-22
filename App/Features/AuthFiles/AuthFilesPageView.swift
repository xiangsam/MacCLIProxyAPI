import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AuthFilesPageView: View {
    @Environment(AppState.self) private var appState
    @State private var files: [AuthFileInfo] = []
    @State private var search = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var pendingDeleteName: String?

    var body: some View {
        ListPageScaffold {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索文件名或提供商", text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 8) {
                    Text("\(filtered.count) / \(files.count) 个文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("刷新") { Task { await reload() } }.disabled(busy)
                    Button("打开目录") { appState.openAuthDirectory() }
                    Button {
                        pickAndUpload()
                    } label: {
                        Label("上传", systemImage: "plus")
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
            if busy && files.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                CenteredEmptyState(
                    systemImage: "key.fill",
                    title: files.isEmpty ? "暂无认证文件" : "无匹配结果",
                    message: files.isEmpty ? "完成 OAuth 或上传凭证文件" : nil,
                    actionTitle: files.isEmpty ? "上传文件" : nil,
                    action: files.isEmpty ? { pickAndUpload() } : nil
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filtered) { file in fileRow(file) }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .navigationTitle("认证文件")
        .confirmDestructive(
            $pendingDeleteName,
            title: "删除认证文件？",
            confirmLabel: { "删除「\($0)」" },
            message: { _ in "删除后该账号凭证将不再可用，此操作不能自动撤销。" },
            action: { name in Task { await delete(name: name) } }
        )
        .task { await reload() }
    }

    private var filtered: [AuthFileInfo] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return files }
        return files.filter { "\($0.name) \($0.provider)".lowercased().contains(query) }
    }

    private func fileRow(_ file: AuthFileInfo) -> some View {
        GlassCard(padding: 14) {
            HStack(spacing: 12) {
                ProviderIconView(provider: file.provider, size: 28)
                    .frame(width: 40, height: 40)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(file.name).font(.headline).lineLimit(1)
                    HStack(spacing: 8) {
                        Text(ProviderBrand.resolve(file.provider).label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Menu {
                            Button("默认 (0)") {
                                Task { await setPriority(name: file.name, priority: 0) }
                            }
                            ForEach([1, 5, 10, 50, 100], id: \.self) { value in
                                Button("P\(value)") {
                                    Task { await setPriority(name: file.name, priority: value) }
                                }
                            }
                        } label: {
                            Text(file.priority.map { "P\($0)" } ?? "优先级")
                                .font(.caption2.monospaced().weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    (file.priority ?? 0) > 0
                                        ? Color.accentColor.opacity(0.15)
                                        : Color.secondary.opacity(0.12),
                                    in: Capsule()
                                )
                                .foregroundStyle((file.priority ?? 0) > 0 ? Color.accentColor : Color.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .help("fill-first 时数字越大越优先；用于同名模型指定订阅或其他上游优先级")
                        StatusPill(
                            text: file.disabled ? "已禁用" : "启用中",
                            tone: file.disabled ? .warning : .success
                        )
                    }
                }
                Spacer(minLength: 8)
                Button(file.disabled ? "启用" : "禁用") {
                    Task { await setDisabled(name: file.name, disabled: !file.disabled) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("删除", role: .destructive) { pendingDeleteName = file.name }
                    .controlSize(.small)
            }
        }
    }

    private func reload() async {
        busy = true
        defer { busy = false }
        errorMessage = nil
        do {
            files = normalize(try await appState.managementClient().getJSON(path: "auth-files"))
        } catch {
            files = []
            errorMessage = error.localizedDescription
        }
    }

    private func setDisabled(name: String, disabled: Bool) async {
        do {
            _ = try await appState.managementClient().sendJSON(
                method: "PATCH",
                path: "auth-files/status",
                body: ["name": name, "disabled": disabled]
            )
            await reload()
        } catch {
            do {
                _ = try await appState.managementClient().sendJSON(
                    method: "PATCH",
                    path: "auth-files/fields",
                    body: ["name": name, "disabled": disabled]
                )
                await reload()
            } catch {
                appState.flash(error.localizedDescription, error: true)
            }
        }
    }

    private func setPriority(name: String, priority: Int) async {
        do {
            var body: [String: Any] = ["name": name]
            // CPA: priority 0 clears the attribute (same as unset).
            body["priority"] = priority
            _ = try await appState.managementClient().sendJSON(
                method: "PATCH",
                path: "auth-files/fields",
                body: body
            )
            appState.flash(priority > 0 ? "已设置优先级 P\(priority)" : "已恢复默认优先级")
            await reload()
        } catch {
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func delete(name: String) async {
        do {
            _ = try await appState.managementClient().sendJSON(
                method: "DELETE",
                path: "auth-files",
                query: ["name": name],
                body: nil
            )
            appState.flash("已删除")
            await reload()
        } catch {
            appState.flash(error.localizedDescription, error: true)
        }
    }

    private func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
                guard fileSize <= 5 * 1024 * 1024 else {
                    throw AppError("认证文件过大（最大 5 MB）")
                }
                let data = try Data(contentsOf: url)
                guard (try JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                    throw AppError("认证文件必须是 JSON 对象")
                }
                _ = try await appState.managementClient().uploadAuthFile(
                    name: url.lastPathComponent,
                    data: data
                )
                appState.flash("已上传")
                await reload()
            } catch {
                appState.flash(error.localizedDescription, error: true)
            }
        }
    }

    private func normalize(_ json: Any) -> [AuthFileInfo] {
        let rows: [[String: Any]]
        if let list = json as? [[String: Any]] {
            rows = list
        } else if let dict = json as? [String: Any] {
            rows = (dict["files"] as? [[String: Any]])
                ?? (dict["items"] as? [[String: Any]])
                ?? (dict["data"] as? [[String: Any]])
                ?? []
        } else {
            rows = []
        }
        return rows.compactMap(AuthFileInfo.init(raw:))
    }
}
