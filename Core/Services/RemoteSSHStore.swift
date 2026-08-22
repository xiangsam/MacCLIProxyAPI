import Foundation

enum RemoteSSHStore {
    static func loadHosts() -> [RemoteSSHHost] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: AppPaths.remoteSSHHostsURL),
              let decoded = try? decoder.decode([RemoteSSHHost].self, from: data)
        else { return [] }
        return decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func saveHosts(_ hosts: [RemoteSSHHost]) throws {
        try AppPaths.ensureBaseDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(hosts)
        try data.write(to: AppPaths.remoteSSHHostsURL, options: .atomic)
        try AppPaths.secureSensitiveFile(AppPaths.remoteSSHHostsURL)
    }

    static func upsert(_ host: RemoteSSHHost) throws -> [RemoteSSHHost] {
        var hosts = loadHosts()
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.insert(host, at: 0)
        }
        try saveHosts(hosts)
        return hosts
    }

    /// Import SSH config entries; skip aliases that already exist (same name+host+user).
    @discardableResult
    static func importEntries(_ entries: [SSHConfigHostEntry]) throws -> (hosts: [RemoteSSHHost], imported: Int, skipped: Int) {
        var hosts = loadHosts()
        var imported = 0
        var skipped = 0
        for entry in entries {
            let candidate = entry.toRemoteSSHHost()
            let exists = hosts.contains {
                $0.name == candidate.name
                    && $0.host == candidate.host
                    && $0.username == candidate.username
                    && $0.port == candidate.port
            }
            if exists {
                skipped += 1
                continue
            }
            hosts.insert(candidate, at: 0)
            imported += 1
        }
        if imported > 0 {
            try saveHosts(hosts)
        }
        return (hosts.sorted { $0.updatedAt > $1.updatedAt }, imported, skipped)
    }

    static func delete(id: String) throws -> [RemoteSSHHost] {
        var hosts = loadHosts().filter { $0.id != id }
        try saveHosts(hosts)
        return hosts
    }
}
