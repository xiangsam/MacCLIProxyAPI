import Foundation

struct ManagementClient: Sendable {
    var port: UInt16
    var secretKey: String
    var session: URLSession = .shared

    init(port: UInt16, secretKey: String, session: URLSession = .shared) {
        self.port = port
        self.secretKey = secretKey
        self.session = session
    }

    init(gui: GuiConfigFile, session: URLSession = .shared) {
        self.init(port: gui.port, secretKey: gui.managementSecretKey, session: session)
    }

    func getJSON(path: String, query: [String: String] = [:]) async throws -> Any {
        try await request(method: "GET", path: path, query: query, body: nil)
    }

    func sendJSON(method: String, path: String, query: [String: String] = [:], body: Any? = nil) async throws -> Any {
        try await request(method: method, path: path, query: query, body: body)
    }

    /// GET config.yaml as raw text (thinking aliases / full config ops).
    func getConfigYAML() async throws -> String {
        try await requestText(
            method: "GET",
            path: "config.yaml",
            accept: "application/yaml,text/yaml,text/plain,*/*",
            contentType: nil,
            body: nil
        )
    }

    /// PUT full config.yaml text.
    func putConfigYAML(_ content: String) async throws {
        _ = try await requestText(
            method: "PUT",
            path: "config.yaml",
            accept: "application/json,application/yaml,text/plain,*/*",
            contentType: "application/yaml",
            body: Data(content.utf8)
        )
    }

    func request(method: String, path: String, query: [String: String], body: Any?) async throws -> Any {
        let data = try await requestData(
            method: method,
            path: path,
            query: query,
            accept: "application/json",
            contentType: body == nil ? nil : "application/json",
            body: body.map { try JSONSerialization.data(withJSONObject: $0, options: []) }
        )
        if data.isEmpty { return NSNull() }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func requestText(
        method: String,
        path: String,
        accept: String,
        contentType: String?,
        body: Data?
    ) async throws -> String {
        let data = try await requestData(
            method: method,
            path: path,
            query: [:],
            accept: accept,
            contentType: contentType,
            body: body
        )
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func requestData(
        method: String,
        path: String,
        query: [String: String],
        accept: String,
        contentType: String?,
        body: Data?
    ) async throws -> Data {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, !trimmed.contains("://"), !trimmed.contains("..") else {
            throw AppError("无效的管理 API 路径")
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/v0/management/\(trimmed)"
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw AppError("构造管理 API URL 失败")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        request.setValue("Bearer \(secretKey)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError("管理 API 无响应")
        }
        if !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AppError("管理 API \(http.statusCode): \(text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: http.statusCode) : text)")
        }
        return data
    }

    func uploadAuthFile(name: String, data: Data) async throws -> Any {
        let fileName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fileName.lowercased().hasSuffix(".json") else {
            throw AppError("认证文件名必须以 .json 结尾")
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/v0/management/auth-files"
        components.queryItems = [URLQueryItem(name: "name", value: fileName)]
        guard let url = components.url else {
            throw AppError("构造上传 URL 失败")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(secretKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(data: responseData, encoding: .utf8) ?? ""
            throw AppError("上传认证文件失败: \(text)")
        }
        if responseData.isEmpty { return NSNull() }
        return try JSONSerialization.jsonObject(with: responseData, options: [.fragmentsAllowed])
    }
}

enum OAuthProvider: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude
    case antigravity
    case kimi
    case xai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        case .kimi: return "Kimi"
        case .xai: return "xAI"
        }
    }

    var supportsCallbackPaste: Bool {
        switch self {
        case .codex, .claude, .antigravity, .xai:
            return true
        case .kimi:
            return false
        }
    }
}
