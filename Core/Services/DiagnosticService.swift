import Foundation

enum DiagnosticService {
    static func run(
        coreStatus: CoreStatus,
        gui: GuiConfigFile,
        client: ManagementClient
    ) async -> [DiagnosticCheck] {
        var checks = [
            fileCheck(id: "base-directory", title: "应用数据目录", url: AppPaths.baseDirectory, permissions: 0o700),
            fileCheck(id: "gui-config", title: "GUI 配置", url: AppPaths.guiConfigURL, permissions: 0o600),
            fileCheck(id: "api-keys", title: "API Key 存储", url: AppPaths.apiKeysURL, permissions: 0o600),
            DiagnosticCheck(
                id: "core-install",
                title: "内核安装",
                detail: coreStatus.binaryPath ?? "未找到 cli-proxy-api",
                level: coreStatus.installed ? .pass : .warning
            ),
            DiagnosticCheck(
                id: "core-process",
                title: "内核运行",
                detail: coreStatus.message,
                level: coreStatus.running ? .pass : .warning
            ),
        ]

        let weakKey = gui.apiKeys.contains {
            $0.apiKey == AppPaths.defaultAPIKey || $0.apiKey.count < 16
        }
        checks.append(DiagnosticCheck(
            id: "network-security",
            title: "网络暴露",
            detail: gui.allowLan
                ? (weakKey ? "局域网模式已启用，但存在弱 API Key" : "局域网模式已启用，密钥强度正常")
                : "仅监听本机 127.0.0.1",
            level: gui.allowLan ? (weakKey ? .fail : .warning) : .pass
        ))

        checks.append(fileCheck(
            id: "usage-database",
            title: "使用记录数据库",
            url: UsageDatabase.shared.databaseURL,
            permissions: 0o600,
            missingLevel: .warning
        ))

        if coreStatus.running {
            do {
                _ = try await client.getJSON(path: "auth-files")
                checks.append(DiagnosticCheck(
                    id: "management-api",
                    title: "Management API",
                    detail: "认证和请求均正常",
                    level: .pass
                ))
            } catch {
                checks.append(DiagnosticCheck(
                    id: "management-api",
                    title: "Management API",
                    detail: error.localizedDescription,
                    level: .fail
                ))
            }
        } else {
            checks.append(DiagnosticCheck(
                id: "management-api",
                title: "Management API",
                detail: "内核未运行，未执行接口检查",
                level: .warning
            ))
        }
        return checks
    }

    static func fileCheck(
        id: String,
        title: String,
        url: URL,
        permissions expectedPermissions: Int,
        missingLevel: DiagnosticLevel = .fail
    ) -> DiagnosticCheck {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return DiagnosticCheck(
                id: id,
                title: title,
                detail: "不存在：\(url.path)",
                level: missingLevel
            )
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let actualPermissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue
        let actual = actualPermissions.map { String(format: "%03o", $0) } ?? "未知"
        return DiagnosticCheck(
            id: id,
            title: title,
            detail: "\(url.path) · 权限 \(actual)",
            level: actualPermissions == expectedPermissions ? .pass : .fail
        )
    }
}
