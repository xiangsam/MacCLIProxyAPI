import Foundation

enum ProviderConnectionTester {
    static func test(
        kind: ProviderKind,
        provider: ProviderConfig,
        session: URLSession = .shared
    ) async throws -> String {
        try ProviderInputValidator.validate(
            name: provider.name,
            baseURL: provider.baseURL,
            apiKey: provider.apiKey,
            requiresName: kind.requiresName
        )

        let request = try makeRequest(kind: kind, provider: provider)
        let started = Date()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError("Provider 无 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = responseMessage(data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw AppError("HTTP \(http.statusCode)：\(message)")
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        return "\(http.statusCode) · \(elapsed) ms"
    }

    static func makeRequest(kind: ProviderKind, provider: ProviderConfig) throws -> URLRequest {
        let base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultBase: String
        let path: String
        switch kind {
        case .codex, .openai:
            defaultBase = ProviderKind.openAIDefaultBaseURL
            path = "models"
        case .claude:
            defaultBase = "https://api.anthropic.com"
            path = "v1/models"
        case .gemini:
            defaultBase = "https://generativelanguage.googleapis.com"
            path = "v1beta/models"
        }

        let resolvedBase = base.isEmpty ? defaultBase : base
        guard let baseURL = URL(string: resolvedBase),
              var components = URLComponents(
                  url: endpointURL(baseURL: baseURL, path: path),
                  resolvingAgainstBaseURL: false
              )
        else {
            throw AppError("无法构造 Provider 测试地址")
        }

        if kind == .gemini {
            components.queryItems = [URLQueryItem(name: "key", value: provider.apiKey)]
        }
        guard let url = components.url else {
            throw AppError("无法构造 Provider 测试地址")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        switch kind {
        case .codex, .openai:
            request.httpMethod = "GET"
            request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        case .claude:
            request.httpMethod = "GET"
            request.setValue(provider.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            request.httpMethod = "GET"
        }
        return request
    }

    private static func endpointURL(baseURL: URL, path: String) -> URL {
        let existingPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let targetPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // If user saved full chat URL as base, don't append again.
        if existingPath.hasSuffix(targetPath) || existingPath.hasSuffix("/" + targetPath) {
            return baseURL
        }
        if !existingPath.isEmpty,
           targetPath.hasPrefix(existingPath + "/")
        {
            let remaining = String(targetPath.dropFirst(existingPath.count + 1))
            return baseURL.appendingPathComponent(remaining)
        }
        return baseURL.appendingPathComponent(targetPath)
    }

    private static func responseMessage(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                return message
            }
            if let msg = json["error_msg"] as? String { return msg }
            if let message = json["message"] as? String { return message }
            if let msg = json["msg"] as? String { return msg }
        }
        return String(data: data.prefix(300), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
