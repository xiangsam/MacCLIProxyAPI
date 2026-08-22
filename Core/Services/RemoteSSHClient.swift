import Foundation

/// Thin wrapper around `/usr/bin/ssh` + `/usr/bin/scp` (OpenSSH).
enum RemoteSSHClient {
    struct CommandResult: Sendable {
        var exitCode: Int32
        var stdout: String
        var stderr: String

        var succeeded: Bool { exitCode == 0 }
        var combinedOutput: String {
            let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if out.isEmpty { return err }
            if err.isEmpty { return out }
            return out + "\n" + err
        }
    }

    static func testConnection(_ host: RemoteSSHHost) throws -> CommandResult {
        try runRemote(host, command: "echo maccliproxy-ssh-ok && hostname && whoami && pwd")
    }

    static func runRemote(_ host: RemoteSSHHost, command: String) throws -> CommandResult {
        try runSSH(host, remoteCommand: command, allocateTTY: false)
    }

    /// Read a remote UTF-8 text file. Missing file → nil (exit 42).
    static func readRemoteFile(_ host: RemoteSSHHost, path: String) throws -> String? {
        let quoted = shellQuote(path)
        let script = "if [ -f \(quoted) ]; then cat \(quoted); else exit 42; fi"
        let result = try runRemote(host, command: script)
        if result.exitCode == 42 { return nil }
        guard result.succeeded else {
            throw AppError(sshFailure("读取远程文件失败", result))
        }
        return result.stdout
    }

    /// Atomically write UTF-8 content to a remote path (mkdir -p parent, temp + mv).
    static func writeRemoteFile(_ host: RemoteSSHHost, path: String, contents: String, mode: String = "600") throws {
        let localTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("maccliproxy-remote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: localTemp) }
        try contents.write(to: localTemp, atomically: true, encoding: .utf8)

        let remoteTemp = "/tmp/maccliproxy-\(UUID().uuidString)"
        let scp = try runSCP(host, localPath: localTemp.path, remotePath: remoteTemp)
        guard scp.succeeded else {
            throw AppError(sshFailure("上传临时文件失败", scp))
        }

        let quotedPath = shellQuote(path)
        let quotedTemp = shellQuote(remoteTemp)
        let parentPath: String
        if path.hasPrefix("$HOME/") {
            let rest = String(path.dropFirst("$HOME/".count))
            let parentRest = (rest as NSString).deletingLastPathComponent
            parentPath = parentRest.isEmpty ? "$HOME" : "$HOME/\(parentRest)"
        } else {
            parentPath = (path as NSString).deletingLastPathComponent
        }
        let parent = shellQuote(parentPath)
        let script = """
        mkdir -p \(parent) && \
        mv \(quotedTemp) \(quotedPath) && \
        chmod \(mode) \(quotedPath)
        """
        let move = try runRemote(host, command: script)
        guard move.succeeded else {
            _ = try? runRemote(host, command: "rm -f \(quotedTemp)")
            throw AppError(sshFailure("写入远程文件失败", move))
        }
    }

    /// Download a remote file to a local path (`scp remote → local`).
    static func downloadRemoteFile(_ host: RemoteSSHHost, remotePath: String, localPath: String) throws {
        var args = baseSSHArgs(host, forSCP: true)
        args.append("\(host.displayTarget):\(remotePath)")
        args.append(localPath)
        let result = try run("/usr/bin/scp", arguments: args)
        guard result.succeeded else {
            throw AppError(sshFailure("下载远程文件失败", result))
        }
    }

    /// Upload a local file to an absolute remote path (`scp local → remote`).
    static func uploadLocalFile(_ host: RemoteSSHHost, localPath: String, remotePath: String) throws {
        let result = try runSCP(host, localPath: localPath, remotePath: remotePath)
        guard result.succeeded else {
            throw AppError(sshFailure("上传文件失败", result))
        }
    }

    // MARK: - Process helpers

    private static func runSSH(
        _ host: RemoteSSHHost,
        remoteCommand: String,
        allocateTTY: Bool
    ) throws -> CommandResult {
        var args = baseSSHArgs(host)
        if !allocateTTY {
            args.append("-T")
        }
        args.append(host.displayTarget)
        args.append(remoteCommand)
        return try run("/usr/bin/ssh", arguments: args)
    }

    private static func runSCP(
        _ host: RemoteSSHHost,
        localPath: String,
        remotePath: String
    ) throws -> CommandResult {
        var args = baseSSHArgs(host, forSCP: true)
        args.append(localPath)
        args.append("\(host.displayTarget):\(remotePath)")
        return try run("/usr/bin/scp", arguments: args)
    }

    private static func baseSSHArgs(_ host: RemoteSSHHost, forSCP: Bool = false) -> [String] {
        // Reuse one TCP session across read/scp/mv round-trips in a single enable.
        let control = controlPath(for: host)
        var args: [String] = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=15",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(control)",
            "-o", "ControlPersist=60",
            forSCP ? "-P" : "-p", "\(host.port)",
        ]
        let identity = host.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !identity.isEmpty {
            args.append(contentsOf: ["-i", identity])
        }
        return args
    }

    /// Stable OpenSSH ControlPath per host (no spaces / specials).
    private static func controlPath(for host: RemoteSSHHost) -> String {
        let raw = "\(host.username)@\(host.host)-\(host.port)"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "/tmp/maccliproxy-ssh-\(raw)"
    }

    private static func run(_ launchPath: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AppError("无法启动 \(launchPath): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private static func shellQuote(_ value: String) -> String {
        if value.hasPrefix("$HOME/") || value == "$HOME" {
            let rest = value == "$HOME" ? "" : String(value.dropFirst("$HOME/".count))
            if rest.isEmpty { return "\"$HOME\"" }
            return "\"$HOME/\(rest.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func sshFailure(_ prefix: String, _ result: CommandResult) -> String {
        let detail = result.combinedOutput
        if detail.isEmpty {
            return "\(prefix)（exit \(result.exitCode)）"
        }
        return "\(prefix): \(detail)"
    }
}
