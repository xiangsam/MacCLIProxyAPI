import AppKit
import Foundation

struct AgentConfigStatus: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var installed: Bool
    var configPath: String?
    var configExists: Bool
    var configured: Bool
    var currentModel: String?
    var executablePath: String?
    var message: String
    var supportsConfiguration: Bool
    var supportsLaunch: Bool
}

enum AgentService {
    static func detectAll(port: UInt16, apiKey: String) -> [AgentConfigStatus] {
        [
            detectClaudeCode(port: port, apiKey: apiKey),
            detectClaudeDesktop(port: port, apiKey: apiKey),
            detectCodex(port: port, apiKey: apiKey),
            detectOpenCode(port: port, apiKey: apiKey),
            detectOpenClaw(port: port, apiKey: apiKey),
            detectHermes(port: port, apiKey: apiKey),
        ]
    }

    static func apply(id: String, model: String, port: UInt16, apiKey: String) throws -> AgentConfigStatus {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError("API Key 不能为空")
        }
        switch id {
        case "claude-code":
            try applyClaudeCode(model: model, port: port, apiKey: apiKey)
            return detectClaudeCode(port: port, apiKey: apiKey)
        case "codex":
            try applyCodex(model: model, port: port, apiKey: apiKey)
            return detectCodex(port: port, apiKey: apiKey)
        case "opencode":
            try applyOpenCode(model: model, port: port, apiKey: apiKey)
            return detectOpenCode(port: port, apiKey: apiKey)
        default:
            throw AppError("暂不支持一键配置：\(id)（可手动指向 http://127.0.0.1:\(port)）")
        }
    }

    static func launch(id: String) throws {
        switch id {
        case "claude-desktop":
            let app = URL(fileURLWithPath: "/Applications/Claude.app")
            guard FileManager.default.fileExists(atPath: app.path) else {
                throw AppError("未找到 Claude.app")
            }
            NSWorkspace.shared.open(app)
        case "codex":
            if which("codex") != nil {
                openTerminal(command: "codex")
            } else {
                throw AppError("未找到 codex 命令")
            }
        case "claude-code":
            if which("claude") != nil {
                openTerminal(command: "claude")
            } else {
                throw AppError("未找到 claude 命令")
            }
        default:
            throw AppError("暂不支持启动 \(id)")
        }
    }

    // MARK: - Detectors

    private static func detectClaudeCode(port: UInt16, apiKey: String) -> AgentConfigStatus {
        let settings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        let installed = which("claude") != nil || FileManager.default.fileExists(atPath: settings.path)
        var configured = false
        var model: String?
        if let data = try? Data(contentsOf: settings),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            let env = json["env"] as? [String: Any]
            let base = (env?["ANTHROPIC_BASE_URL"] as? String) ?? ""
            let token = (env?["ANTHROPIC_AUTH_TOKEN"] as? String) ?? ""
            configured = base.contains(":\(port)") && token == apiKey
            model = env?["ANTHROPIC_MODEL"] as? String
        }
        return AgentConfigStatus(
            id: "claude-code",
            name: "Claude Code",
            installed: installed,
            configPath: settings.path,
            configExists: FileManager.default.fileExists(atPath: settings.path),
            configured: configured,
            currentModel: model,
            executablePath: which("claude"),
            message: configured ? "已指向本地代理" : (installed ? "已安装，未配置" : "未检测到"),
            supportsConfiguration: true,
            supportsLaunch: true
        )
    }

    private static func detectClaudeDesktop(port: UInt16, apiKey: String) -> AgentConfigStatus {
        _ = apiKey
        let app = "/Applications/Claude.app"
        let installed = FileManager.default.fileExists(atPath: app)
        return AgentConfigStatus(
            id: "claude-desktop",
            name: "Claude Desktop",
            installed: installed,
            configPath: nil,
            configExists: false,
            configured: false,
            currentModel: nil,
            executablePath: installed ? app : nil,
            message: installed ? "已安装（桌面端配置因版本而异）" : "未安装",
            supportsConfiguration: false,
            supportsLaunch: true
        )
    }

    private static func detectCodex(port: UInt16, apiKey: String) -> AgentConfigStatus {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
        let installed = which("codex") != nil || FileManager.default.fileExists(atPath: config.path)
        var configured = false
        if let text = try? String(contentsOf: config, encoding: .utf8) {
            configured = text.contains(":\(port)") && (text.contains(apiKey) || text.contains("OPENAI_API_KEY"))
        }
        return AgentConfigStatus(
            id: "codex",
            name: "Codex",
            installed: installed,
            configPath: config.path,
            configExists: FileManager.default.fileExists(atPath: config.path),
            configured: configured,
            currentModel: nil,
            executablePath: which("codex"),
            message: configured ? "已指向本地代理" : (installed ? "已安装，未配置" : "未检测到"),
            supportsConfiguration: true,
            supportsLaunch: true
        )
    }

    private static func detectOpenCode(port: UInt16, apiKey: String) -> AgentConfigStatus {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode/config.json")
        let installed = which("opencode") != nil || FileManager.default.fileExists(atPath: config.path)
        var configured = false
        if let data = try? Data(contentsOf: config),
           let text = String(data: data, encoding: .utf8)
        {
            configured = text.contains(":\(port)") && text.contains(apiKey)
        }
        return AgentConfigStatus(
            id: "opencode",
            name: "OpenCode",
            installed: installed,
            configPath: config.path,
            configExists: FileManager.default.fileExists(atPath: config.path),
            configured: configured,
            currentModel: nil,
            executablePath: which("opencode"),
            message: configured ? "已指向本地代理" : (installed ? "已安装，未配置" : "未检测到"),
            supportsConfiguration: true,
            supportsLaunch: false
        )
    }

    private static func detectOpenClaw(port: UInt16, apiKey: String) -> AgentConfigStatus {
        _ = port
        _ = apiKey
        let installed = which("openclaw") != nil
        return AgentConfigStatus(
            id: "openclaw",
            name: "OpenClaw",
            installed: installed,
            configPath: nil,
            configExists: false,
            configured: false,
            currentModel: nil,
            executablePath: which("openclaw"),
            message: installed ? "已安装（请手动配置 base URL）" : "未检测到",
            supportsConfiguration: false,
            supportsLaunch: false
        )
    }

    private static func detectHermes(port: UInt16, apiKey: String) -> AgentConfigStatus {
        _ = port
        _ = apiKey
        let installed = which("hermes") != nil
        return AgentConfigStatus(
            id: "hermes",
            name: "Hermes Agent",
            installed: installed,
            configPath: nil,
            configExists: false,
            configured: false,
            currentModel: nil,
            executablePath: which("hermes"),
            message: installed ? "已安装（请手动配置）" : "未检测到",
            supportsConfiguration: false,
            supportsLaunch: false
        )
    }

    // MARK: - Apply

    private static func applyClaudeCode(model: String, port: UInt16, apiKey: String) throws {
        let settings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settings),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            root = json
        }
        var env = (root["env"] as? [String: Any]) ?? [:]
        env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:\(port)"
        env["ANTHROPIC_AUTH_TOKEN"] = apiKey
        if !model.isEmpty {
            env["ANTHROPIC_MODEL"] = model
            env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = model
            env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = model
        }
        root["env"] = env
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try backupIfExists(settings)
        try data.write(to: settings, options: .atomic)
    }

    private static func applyCodex(model: String, port: UInt16, apiKey: String) throws {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try backupIfExists(config)
        var text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        // Simple append/replace managed section.
        let markerStart = "# BEGIN MacCLIProxyAPI"
        let markerEnd = "# END MacCLIProxyAPI"
        if let start = text.range(of: markerStart), let end = text.range(of: markerEnd) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        let block = """

        \(markerStart)
        model_provider = "maccliproxy"
        \(model.isEmpty ? "" : "model = \"\(model)\"")
        [model_providers.maccliproxy]
        name = "MacCLIProxyAPI"
        base_url = "http://127.0.0.1:\(port)/v1"
        env_key = "OPENAI_API_KEY"
        \(markerEnd)

        """
        // Ensure env key note
        _ = apiKey
        text += block
        try text.write(to: config, atomically: true, encoding: .utf8)
        // Export hint file for shell
        let envFile = config.deletingLastPathComponent().appendingPathComponent("maccliproxy.env")
        try "export OPENAI_API_KEY=\(apiKey)\nexport OPENAI_BASE_URL=http://127.0.0.1:\(port)/v1\n"
            .write(to: envFile, atomically: true, encoding: .utf8)
    }

    private static func applyOpenCode(model: String, port: UInt16, apiKey: String) throws {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode/config.json")
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: config),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            root = json
        }
        root["baseURL"] = "http://127.0.0.1:\(port)/v1"
        root["apiKey"] = apiKey
        if !model.isEmpty {
            root["model"] = model
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try backupIfExists(config)
        try data.write(to: config, options: .atomic)
    }

    private static func backupIfExists(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let backup = url.appendingPathExtension("maccliproxy.bak")
        if FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.removeItem(at: backup)
        }
        try FileManager.default.copyItem(at: url, to: backup)
    }

    private static func which(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func openTerminal(command: String) {
        let script = """
        tell application "Terminal"
          activate
          do script "\(command)"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}
