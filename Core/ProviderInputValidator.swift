import Foundation

enum ProviderInputValidator {
    static func validate(
        name: String?,
        baseURL: String,
        apiKey: String,
        requiresName: Bool
    ) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AppError("API Key 不能为空") }
        guard key.count <= 4096 else { throw AppError("API Key 过长") }
        guard !containsControlCharacters(key) else {
            throw AppError("API Key 不能包含控制字符")
        }

        if requiresName {
            let providerName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !providerName.isEmpty else { throw AppError("Provider 名称不能为空") }
            guard providerName.count <= 128 else { throw AppError("Provider 名称过长") }
            guard !containsControlCharacters(providerName) else {
                throw AppError("Provider 名称不能包含控制字符")
            }
        }

        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return }
        guard base.count <= 2048,
              let components = URLComponents(string: base),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil
        else {
            throw AppError("Base URL 必须是有效的 http 或 https 地址，且不能包含用户名密码")
        }
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
