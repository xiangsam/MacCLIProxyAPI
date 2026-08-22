import Foundation

/// One concrete `Host` alias parsed from OpenSSH config (wildcards excluded).
struct SSHConfigHostEntry: Identifiable, Equatable, Sendable {
    /// Alias from the `Host` line (e.g. `dev`).
    var alias: String
    /// `HostName` if set, otherwise the alias.
    var hostName: String
    var user: String
    var port: UInt16
    var identityFile: String
    /// Relative source hint for UI (`~/.ssh/config`).
    var source: String

    var id: String { "\(source)#\(alias)" }

    var displayTarget: String {
        let user = self.user.trimmingCharacters(in: .whitespacesAndNewlines)
        if user.isEmpty { return hostName }
        return "\(user)@\(hostName)"
    }

    func toRemoteSSHHost(defaultUsername: String = NSUserName()) -> RemoteSSHHost {
        var host = RemoteSSHHost.makeNew(
            name: alias,
            host: hostName,
            username: user.isEmpty ? defaultUsername : user,
            port: port == 0 ? 22 : port
        )
        host.identityFile = identityFile
        host.notes = "从 \(source) 导入"
        return host
    }
}

/// Minimal OpenSSH config reader: `Host` / keyword lines + recursive `Include`.
enum SSHConfigReader {
    static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
    }

    static func loadImportableHosts(
        configURL: URL = defaultConfigURL,
        defaultUsername: String = NSUserName()
    ) -> [SSHConfigHostEntry] {
        var visited = Set<String>()
        let blocks = parseFile(configURL, visited: &visited)
        return materialize(blocks: blocks, defaultUsername: defaultUsername)
            .sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
    }

    // MARK: - Parse

    private struct HostBlock {
        var patterns: [String]
        var hostName: String?
        var user: String?
        var port: UInt16?
        var identityFile: String?
        var source: String
    }

    private static func parseFile(_ url: URL, visited: inout Set<String>) -> [HostBlock] {
        let path = url.standardizedFileURL.path
        guard !visited.contains(path) else { return [] }
        visited.insert(path)

        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let source = displaySource(url)
        var blocks: [HostBlock] = []
        var current: HostBlock?
        var skippingMatch = false

        func flush() {
            if let current { blocks.append(current) }
            current = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine))
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let parts = splitTokens(trimmed)
            guard let key = parts.first?.lowercased() else { continue }
            let values = Array(parts.dropFirst())

            switch key {
            case "include":
                flush()
                skippingMatch = false
                for pattern in values {
                    for included in expandInclude(pattern, relativeTo: url.deletingLastPathComponent()) {
                        blocks.append(contentsOf: parseFile(included, visited: &visited))
                    }
                }
            case "match":
                flush()
                skippingMatch = true
            case "host":
                flush()
                skippingMatch = false
                current = HostBlock(patterns: values, source: source)
            default:
                guard !skippingMatch, var block = current else { continue }
                applyKeyword(key, values: values, to: &block)
                current = block
            }
        }
        flush()
        return blocks
    }

    private static func applyKeyword(_ key: String, values: [String], to block: inout HostBlock) {
        guard let first = values.first else { return }
        switch key {
        case "hostname":
            block.hostName = first
        case "user":
            block.user = first
        case "port":
            if let port = UInt16(first) { block.port = port }
        case "identityfile":
            // First IdentityFile wins for our import model.
            if block.identityFile == nil {
                block.identityFile = expandHome(first)
            }
        default:
            break
        }
    }

    // MARK: - Materialize concrete aliases

    private static func materialize(blocks: [HostBlock], defaultUsername: String) -> [SSHConfigHostEntry] {
        var aliases: [String] = []
        var seen = Set<String>()
        for block in blocks {
            for pattern in block.patterns where isConcreteHostPattern(pattern) {
                if seen.insert(pattern).inserted {
                    aliases.append(pattern)
                }
            }
        }

        return aliases.map { alias in
            var entry = SSHConfigHostEntry(
                alias: alias,
                hostName: alias,
                user: "",
                port: 22,
                identityFile: "",
                source: "~/.ssh/config"
            )
            for block in blocks where block.patterns.contains(where: { $0 == "*" || $0 == alias }) {
                if let hostName = block.hostName { entry.hostName = hostName }
                if let user = block.user { entry.user = user }
                if let port = block.port { entry.port = port }
                if let identity = block.identityFile, !identity.isEmpty {
                    entry.identityFile = identity
                }
                // Prefer the most specific non-* block's source label.
                if block.patterns.contains(alias) {
                    entry.source = block.source
                }
            }
            if entry.user.isEmpty {
                entry.user = defaultUsername
            }
            return entry
        }
    }

    private static func isConcreteHostPattern(_ pattern: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty || p == "*" { return false }
        if p.contains("*") || p.contains("?") || p.contains("!") { return false }
        return true
    }

    // MARK: - Include / path helpers

    private static func expandInclude(_ pattern: String, relativeTo directory: URL) -> [URL] {
        let expanded = expandHome(pattern)
        let base: URL
        if expanded.hasPrefix("/") {
            base = URL(fileURLWithPath: expanded)
        } else {
            base = directory.appendingPathComponent(expanded)
        }
        let path = base.path
        if path.contains("*") || path.contains("?") {
            let parent = (path as NSString).deletingLastPathComponent
            let namePattern = (path as NSString).lastPathComponent
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return [] }
            return items.compactMap { name -> URL? in
                guard matchesGlob(name, pattern: namePattern) else { return nil }
                return URL(fileURLWithPath: parent).appendingPathComponent(name)
            }.sorted { $0.path < $1.path }
        }
        return [base]
    }

    private static func matchesGlob(_ name: String, pattern: String) -> Bool {
        let pred = NSPredicate(format: "self LIKE %@", pattern)
        return pred.evaluate(with: name)
    }

    private static func expandHome(_ value: String) -> String {
        var s = stripQuotes(value)
        if s.hasPrefix("~/") {
            s = FileManager.default.homeDirectoryForCurrentUser.path + String(s.dropFirst())
        } else if s == "~" {
            s = FileManager.default.homeDirectoryForCurrentUser.path
        }
        return s
    }

    private static func stripQuotes(_ value: String) -> String {
        var s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2 {
            if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
                s.removeFirst()
                s.removeLast()
            }
        }
        return s
    }

    private static func stripComment(_ line: String) -> String {
        var inQuote: Character?
        for (index, ch) in line.enumerated() {
            if let q = inQuote {
                if ch == q { inQuote = nil }
                continue
            }
            if ch == "\"" || ch == "'" {
                inQuote = ch
                continue
            }
            if ch == "#" {
                return String(line.prefix(index))
            }
        }
        return line
    }

    private static func splitTokens(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for ch in line {
            if let q = quote {
                if ch == q {
                    quote = nil
                } else {
                    current.append(ch)
                }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                continue
            }
            if ch == " " || ch == "\t" || ch == "=" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func displaySource(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}
