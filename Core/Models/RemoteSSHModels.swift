import Foundation

/// A saved SSH target used to push agent live configs onto a remote machine.
struct RemoteSSHHost: Identifiable, Equatable, Codable, Sendable {
    var id: String
    var name: String
    /// Hostname or IP (e.g. `dev`, `10.0.0.8`).
    var host: String
    var port: UInt16
    var username: String
    /// Absolute path to a private key; empty → rely on ssh-agent / default keys.
    var identityFile: String
    /// How the *remote* machine reaches this Mac's CPA.
    /// Empty → app fills LAN IPv4 (requires 配置页开启局域网访问).
    var cpaReachableHost: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var lastTestedAt: Date?
    var lastTestOK: Bool?
    var lastTestMessage: String

    static func makeNew(
        name: String = "远程开发机",
        host: String = "",
        username: String = NSUserName(),
        port: UInt16 = 22
    ) -> RemoteSSHHost {
        let now = Date()
        return RemoteSSHHost(
            id: UUID().uuidString,
            name: name,
            host: host,
            port: port,
            username: username,
            identityFile: "",
            cpaReachableHost: "",
            notes: "",
            createdAt: now,
            updatedAt: now,
            lastTestedAt: nil,
            lastTestOK: nil,
            lastTestMessage: ""
        )
    }

    var displayTarget: String {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = self.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if user.isEmpty { return host }
        return "\(user)@\(host)"
    }
}

struct RemoteAgentApplyResult: Equatable, Sendable {
    var agent: AgentKind
    var remotePath: String
    var message: String
    /// A `codex app-server` was already running when we wrote a new model catalog, so it is
    /// still serving the previous profile's `/model` list until it is stopped.
    var codexAppServerHoldsStaleCatalog: Bool = false
}

enum RemoteCPAEndpointBuilder {
    /// Claude: Anthropic base without `/v1`.
    static func claudeBase(host: String, port: UInt16) -> String {
        "http://\(normalizeHost(host)):\(port)"
    }

    /// Codex: OpenAI-compatible `/v1`.
    static func codexBase(host: String, port: UInt16) -> String {
        "http://\(normalizeHost(host)):\(port)/v1"
    }

    private static func normalizeHost(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("[") { return h }
        // IPv6 literal without brackets → leave as-is only if already bracketed by caller.
        return h
    }
}
