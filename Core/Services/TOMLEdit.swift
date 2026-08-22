import Foundation

/// Minimal line-based TOML editing: set/remove keys inside a table without rewriting the file.
/// Preserves unrelated content, comments and ordering (cc-switch style merge, not append-block).
enum TOMLEdit {
    /// Set `key = value` inside `table` (nil/"" = root table). Creates the table when missing.
    static func setString(_ text: String, table: String?, key: String, value: String) -> String {
        setRaw(text, table: table, key: key, literal: "\"\(escape(value))\"")
    }

    static func setRaw(_ text: String, table: String?, key: String, literal: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let target = normalizeTableName(table)
        let line = "\(key) = \(literal)"

        if let range = tableRange(lines, name: target) {
            if let idx = keyIndex(lines, in: range, key: key) {
                lines[idx] = line
            } else {
                lines.insert(line, at: insertionIndex(lines, in: range))
            }
            return lines.joined(separator: "\n")
        }

        var result = text
        while result.hasSuffix("\n") { result.removeLast() }
        if target.isEmpty {
            return result.isEmpty ? line + "\n" : line + "\n" + result + "\n"
        }
        let prefix = result.isEmpty ? "" : result + "\n\n"
        return prefix + "[\(target)]\n" + line + "\n"
    }

    static func removeKey(_ text: String, table: String?, key: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let range = tableRange(lines, name: normalizeTableName(table)),
              let idx = keyIndex(lines, in: range, key: key)
        else { return text }
        lines.remove(at: idx)
        return lines.joined(separator: "\n")
    }

    /// Remove a whole `[table]` section including its header.
    static func removeTable(_ text: String, name: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let range = tableRange(lines, name: normalizeTableName(name)), let header = range.headerIndex else {
            return text
        }
        lines.removeSubrange(header...range.endIndex)
        return lines.joined(separator: "\n")
    }

    /// Remove every `[[name]]` array-of-tables section (header + body until next table).
    static func removeArrayOfTables(_ text: String, name: String) -> String {
        let target = canonical(normalizeTableName(name))
        var lines = text.components(separatedBy: "\n")
        var idx = 0
        while idx < lines.count {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[["), trimmed.hasSuffix("]]") else {
                idx += 1
                continue
            }
            let header = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            guard canonical(header) == target else {
                idx += 1
                continue
            }
            var end = idx
            var j = idx + 1
            while j < lines.count {
                let t = lines[j].trimmingCharacters(in: .whitespaces)
                if tableHeader(lines[j]) != nil || t.hasPrefix("[[") { break }
                end = j
                j += 1
            }
            lines.removeSubrange(idx...end)
        }
        return lines.joined(separator: "\n")
    }

    /// All `[model.xxx]`-style sub-table names directly under `parent`.
    static func subTableNames(_ text: String, parent: String) -> [String] {
        let parentPath = pathComponents(normalizeTableName(parent))
        var names: [String] = []
        for line in text.components(separatedBy: "\n") {
            guard let header = tableHeader(line) else { continue }
            let path = pathComponents(header)
            guard path.count == parentPath.count + 1, Array(path.prefix(parentPath.count)) == parentPath else {
                continue
            }
            names.append(path[parentPath.count])
        }
        return names
    }

    static func value(_ text: String, table: String?, key: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let range = tableRange(lines, name: normalizeTableName(table)),
              let idx = keyIndex(lines, in: range, key: key)
        else { return nil }
        let parts = lines[idx].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return unquote(parts[1].trimmingCharacters(in: .whitespaces))
    }

    static func quoteTableComponent(_ name: String) -> String {
        let bare = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if !name.isEmpty, name.unicodeScalars.allSatisfy({ bare.contains($0) }) {
            return name
        }
        return "\"\(escape(name))\""
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Internals

    private struct TableRange {
        /// nil for the implicit root table.
        var headerIndex: Int?
        /// First line belonging to the table body.
        var startIndex: Int
        /// Last line belonging to the table body (may be < startIndex when empty).
        var endIndex: Int
    }

    private static func normalizeTableName(_ table: String?) -> String {
        (table ?? "").trimmingCharacters(in: .whitespaces)
    }

    private static func tableHeader(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), !trimmed.hasPrefix("[[") else { return nil }
        return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    private static func tableRange(_ lines: [String], name: String) -> TableRange? {
        if name.isEmpty {
            var end = lines.count - 1
            for (idx, line) in lines.enumerated() where tableHeader(line) != nil || line.trimmingCharacters(in: .whitespaces).hasPrefix("[[") {
                end = idx - 1
                break
            }
            return TableRange(headerIndex: nil, startIndex: 0, endIndex: end)
        }
        guard let header = lines.firstIndex(where: { tableHeader($0).map(canonical) == canonical(name) }) else {
            return nil
        }
        var end = lines.count - 1
        var idx = header + 1
        while idx < lines.count {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            if tableHeader(lines[idx]) != nil || trimmed.hasPrefix("[[") {
                end = idx - 1
                break
            }
            idx += 1
        }
        return TableRange(headerIndex: header, startIndex: header + 1, endIndex: end)
    }

    /// Compare table paths ignoring quoting differences (`model."a-b"` == `model.a-b`).
    private static func canonical(_ name: String) -> String {
        pathComponents(name).joined(separator: "\u{0}")
    }

    /// Split a dotted table path, treating quoted segments as atomic (`model."grok-4.5"`).
    private static func pathComponents(_ name: String) -> [String] {
        var components: [String] = []
        var current = ""
        var quote: Character?
        for char in name {
            if let q = quote {
                if char == q {
                    quote = nil
                } else {
                    current.append(char)
                }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == "." {
                components.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        components.append(current.trimmingCharacters(in: .whitespaces))
        return components.filter { !$0.isEmpty }
    }

    private static func keyIndex(_ lines: [String], in range: TableRange, key: String) -> Int? {
        guard range.startIndex <= range.endIndex else { return nil }
        for idx in range.startIndex...range.endIndex where idx < lines.count {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "="), !trimmed.hasPrefix("#") else { continue }
            let name = unquote(String(trimmed[trimmed.startIndex..<eq]).trimmingCharacters(in: .whitespaces))
            if name == key { return idx }
        }
        return nil
    }

    /// Insert after the last non-empty body line so trailing blank lines stay at the bottom.
    private static func insertionIndex(_ lines: [String], in range: TableRange) -> Int {
        var idx = min(range.endIndex, lines.count - 1)
        while idx >= range.startIndex, idx >= 0, lines[idx].trimmingCharacters(in: .whitespaces).isEmpty {
            idx -= 1
        }
        return max(idx + 1, range.startIndex)
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return value
    }
}
