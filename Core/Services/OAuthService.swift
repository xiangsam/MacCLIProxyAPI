import AppKit
import Foundation

struct OAuthStartResult: Sendable {
    var url: String
    var state: String
    var opened: Bool
    var openError: String?
}

struct OAuthStatusResult: Sendable {
    var status: String
    var error: String?
}

enum OAuthFlowState: Equatable, Sendable {
    case success
    case failure
    case pending
    case unknown
}

enum OAuthService {
    /// Management API provider key used in paths like `{key}-auth-url`.
    static func managementKey(for provider: OAuthProvider) -> String {
        switch provider {
        case .claude: return "anthropic"
        case .codex: return "codex"
        case .antigravity: return "antigravity"
        case .kimi: return "kimi"
        case .xai: return "xai"
        }
    }

    static func usesWebUICallback(_ provider: OAuthProvider) -> Bool {
        switch provider {
        case .codex, .claude, .antigravity, .xai:
            return true
        case .kimi:
            return false
        }
    }

    /// GET /v0/management/{provider}-auth-url?is_webui=true
    static func start(provider: OAuthProvider, client: ManagementClient) async throws -> OAuthStartResult {
        let key = managementKey(for: provider)
        var query: [String: String] = [:]
        if usesWebUICallback(provider) {
            query["is_webui"] = "true"
        }

        let json = try await client.getJSON(path: "\(key)-auth-url", query: query)
        guard let result = parseStart(json) else {
            // Surface payload errors if present.
            if let dict = json as? [String: Any] {
                if let err = stringValue(dict["error"]) ?? stringValue(dict["error_message"]) ?? stringValue(dict["message"]) {
                    throw AppError(err)
                }
            }
            throw AppError("内核未返回 OAuth 登录链接")
        }

        var opened = false
        var openError: String?
        if let url = URL(string: result.url) {
            opened = NSWorkspace.shared.open(url)
            if !opened { openError = "无法打开浏览器" }
        }

        return OAuthStartResult(
            url: result.url,
            state: result.state,
            opened: opened,
            openError: openError
        )
    }

    /// GET /v0/management/get-auth-status?state=...
    static func status(state: String, client: ManagementClient) async throws -> OAuthStatusResult {
        let trimmed = state.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppError("OAuth state 不能为空") }

        let json = try await client.getJSON(path: "get-auth-status", query: ["state": trimmed])
        guard let dict = json as? [String: Any] else {
            return OAuthStatusResult(status: "wait", error: nil)
        }
        let status = (stringValue(dict["status"]) ?? "wait").lowercased()
        let error = stringValue(dict["error"]) ?? stringValue(dict["error_message"])
        return OAuthStatusResult(status: status, error: error)
    }

    static func classifyStatus(_ rawStatus: String) -> OAuthFlowState {
        let status = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["ok", "success", "completed", "done", "authorized", "finish", "finished"].contains(status) {
            return .success
        }
        if ["error", "failed", "fail", "denied", "cancelled", "canceled", "expired"].contains(status) {
            return .failure
        }
        if ["wait", "pending", "waiting", "running", "processing"].contains(status) {
            return .pending
        }
        return .unknown
    }

    /// POST /v0/management/oauth-callback { provider, redirect_url }
    static func submitCallback(provider: OAuthProvider, redirectURL: String, client: ManagementClient) async throws {
        let redirect = redirectURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !redirect.isEmpty else { throw AppError("回调链接不能为空") }

        let body: [String: Any] = [
            "provider": managementKey(for: provider),
            "redirect_url": redirect,
        ]
        _ = try await client.sendJSON(method: "POST", path: "oauth-callback", body: body)
    }

    private static func parseStart(_ json: Any) -> (url: String, state: String)? {
        guard let dict = json as? [String: Any] else { return nil }
        let url = stringValue(dict["url"])
            ?? stringValue(dict["auth_url"])
            ?? stringValue(dict["authorization_url"])
            ?? ""
        // state may be absent for some providers; still allow start if URL exists.
        let state = stringValue(dict["state"])
            ?? stringValue(dict["session_id"])
            ?? ""
        guard !url.isEmpty else { return nil }
        return (url, state)
    }

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = any as? NSNumber {
            return n.stringValue
        }
        return nil
    }
}
