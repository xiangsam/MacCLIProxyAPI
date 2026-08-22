import Foundation

enum AppPage: String, CaseIterable, Identifiable, Hashable {
    case home
    case versions
    case config
    case thinkingAliases
    case oauth
    case api
    case authFiles
    case quota
    case usageRecords
    case agents
    case remoteSSH
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .versions: return "版本"
        case .config: return "配置"
        case .thinkingAliases: return "模型别名"
        case .oauth: return "OAuth"
        case .api: return "API 接入"
        case .authFiles: return "认证文件"
        case .quota: return "配额"
        case .usageRecords: return "使用记录"
        case .agents: return "智能体"
        case .remoteSSH: return "远程 SSH"
        case .diagnostics: return "诊断"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .versions: return "shippingbox"
        case .config: return "gearshape"
        case .thinkingAliases: return "arrow.triangle.branch"
        case .oauth: return "person.badge.key"
        case .api: return "network"
        // Avoid doc.badge.key — often disappears on selected sidebar rows in macOS 26.
        case .authFiles: return "key.fill"
        case .quota: return "gauge.with.dots.needle.33percent"
        case .usageRecords: return "clock.arrow.circlepath"
        case .agents: return "desktopcomputer"
        case .remoteSSH: return "network.badge.shield.half.filled"
        case .diagnostics: return "stethoscope"
        }
    }

    var requiresCoreRunning: Bool {
        switch self {
        // `usageRecords` reads the local SQLite history, not the management API, so past
        // requests stay browsable while the kernel is stopped.
        case .home, .versions, .config, .diagnostics, .agents, .remoteSSH, .usageRecords:
            return false
        default:
            return true
        }
    }
}

struct CoreStatus: Equatable, Sendable {
    var installed: Bool
    var running: Bool
    var managed: Bool
    var processId: Int32?
    var currentVersion: String?
    var installDir: String
    var binaryPath: String?
    var message: String

    static func empty(installDir: String) -> CoreStatus {
        CoreStatus(
            installed: false,
            running: false,
            managed: false,
            processId: nil,
            currentVersion: nil,
            installDir: installDir,
            binaryPath: nil,
            message: "未安装"
        )
    }
}

struct CorePlatform: Equatable, Sendable {
    var os: String
    var arch: String
    var assetOS: String
    var assetArch: String
    var archiveKind: String

    var displayName: String {
        "\(os)/\(arch)"
    }
}

struct CoreLatest: Equatable, Sendable {
    var version: String
    var assetName: String
    var downloadURL: URL?
}

struct CoreInstallResult: Equatable, Sendable {
    var version: String
    var assetName: String
    var installDir: String
    var binaryPath: String?
}

struct CoreInstallTask: Equatable, Sendable {
    var running: Bool = false
    var cancellable: Bool = false
    var phase: String = ""
    var downloaded: Int64 = 0
    var total: Int64?
    var percent: Double?
    var message: String?
    var result: CoreInstallResult?
}

struct GuiApiKey: Identifiable, Equatable, Codable, Sendable {
    var id: String { apiKey }
    var apiKey: String
    var remark: String
}

struct GuiSettings: Equatable, Sendable {
    var port: UInt16
    var allowLan: Bool
    var runOnStartup: Bool
}

struct CoreConfigSettings: Equatable, Sendable {
    var apiKeys: [GuiApiKey]
    var port: UInt16
    var allowLan: Bool
    var routingStrategy: String
    var proxyUrl: String
    var routingSessionAffinity: Bool
    var routingSessionAffinityTtl: String
    var routingExcludeCodexOverlappingModels: Bool
    /// CPA `codex.optimize-multi-agent-v2` — rewrite plaintext agent encrypted_content to input_text.
    var optimizeCodexMultiAgentV2: Bool
    var managementSecretConfigured: Bool
}

struct ClientApiProfile: Identifiable, Equatable, Sendable {
    enum Kind: String { case openai, claude, gemini }
    var id: Kind
    var name: String
    var pathSuffix: String

    static let all: [ClientApiProfile] = [
        .init(id: .openai, name: "OpenAI 兼容", pathSuffix: "/v1"),
        .init(id: .claude, name: "Claude 兼容", pathSuffix: ""),
        .init(id: .gemini, name: "Gemini 兼容", pathSuffix: ""),
    ]

    func endpoint(host: String, port: UInt16) -> String {
        "http://\(host):\(port)\(pathSuffix)"
    }
}

enum AppThemePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

struct AppError: LocalizedError, Identifiable {
    let id = UUID()
    let message: String

    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }
}
