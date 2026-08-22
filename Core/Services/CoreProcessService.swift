import Foundation

/// Process control lives off the main actor so start/stop waits never freeze the UI.
final class CoreProcessService: @unchecked Sendable {
    private struct ProcessRecord: Codable {
        var pid: Int32
        var binaryPath: String
        var configPath: String
        var port: UInt16
        var startedAt: TimeInterval
    }

    private let lock = NSLock()
    private var managedProcess: Process?
    private var managedPID: Int32?

    func currentStatus(port: UInt16) -> CoreStatus {
        let installDir = AppPaths.installDirectory
        let binary = AppPaths.findCoreBinary(in: installDir)
        let installed = binary != nil
        let version = readInstalledVersion()
        let managedAlive = isManagedProcessAlive()
        let recorded = binary.flatMap { validatedProcessRecord(expectedBinary: $0) }
        let orphanPIDs = findInstalledCorePIDs()
        let portOpen = isPortOpen(port: port)
        let pid = managedAlive
            ? lockedPID()
            : (recorded?.pid ?? orphanPIDs.first)
        let running = managedAlive
            || recorded != nil
            || !orphanPIDs.isEmpty
            || (portOpen && pid != nil)

        var message = "已停止"
        if !installed {
            message = "未安装"
        } else if running {
            if managedAlive {
                message = "运行中（本应用托管）"
            } else if recorded == nil, !orphanPIDs.isEmpty {
                message = "运行中（残留进程）"
            } else {
                message = "运行中"
            }
        }

        return CoreStatus(
            installed: installed,
            running: running,
            managed: managedAlive,
            processId: running ? pid : nil,
            currentVersion: version,
            installDir: installDir.path,
            binaryPath: binary?.path,
            message: message
        )
    }

    func start(gui: GuiConfigFile) throws -> CoreStatus {
        try AppPaths.ensureBaseDirectories()
        let installDir = AppPaths.installDirectory
        let authDir = AppPaths.resolveAuthDirectory(authDir: gui.authDir, installDir: installDir)
        try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)

        guard let binary = AppPaths.findCoreBinary(in: installDir) else {
            throw AppError("未安装 CPA 内核，请先安装最新版")
        }

        if isManagedProcessAlive() || validatedProcessRecord(expectedBinary: binary) != nil {
            throw AppError("CPA 内核已经在运行")
        }
        // Unclean previous quit often leaves an orphan listening on the port.
        if isPortOpen(port: gui.port) {
            _ = try reclaimOrphanOnPortIfOurs(port: gui.port)
            if isPortOpen(port: gui.port) {
                throw AppError("端口 \(gui.port) 已被其他程序占用，请更换端口后重试")
            }
        }

        let configPath = try CoreConfigStore.mergeForStart(gui: gui)

        // Ensure executable bit.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binary.path
        )

        let process = Process()
        process.executableURL = binary
        process.arguments = ["-config", configPath.path]
        process.currentDirectoryURL = installDir
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw AppError("启动 CPA 内核失败: \(error.localizedDescription)")
        }

        lock.lock()
        managedProcess = process
        managedPID = process.processIdentifier
        lock.unlock()

        do {
            try writeProcessRecord(
                ProcessRecord(
                    pid: process.processIdentifier,
                    binaryPath: binary.standardizedFileURL.path,
                    configPath: configPath.standardizedFileURL.path,
                    port: gui.port,
                    startedAt: Date().timeIntervalSince1970
                )
            )
            try waitForManagementPort(process: process, port: gui.port, timeout: 10)
        } catch {
            terminateProcess(process)
            removeProcessRecord()
            lock.lock()
            managedProcess = nil
            managedPID = nil
            lock.unlock()
            throw error
        }

        return currentStatus(port: gui.port)
    }

    func stop(port: UInt16) throws -> CoreStatus {
        lock.lock()
        let process = managedProcess
        lock.unlock()
        let binary = AppPaths.findCoreBinary(in: AppPaths.installDirectory)
        let recorded = binary.flatMap { validatedProcessRecord(expectedBinary: $0) }

        if let process, process.isRunning {
            terminateProcess(process)
        }

        // Prefer recorded PID, then any still-alive process that matches our install paths.
        var pids = Set<Int32>()
        if let recorded {
            pids.insert(recorded.pid)
        }
        for pid in findInstalledCorePIDs() {
            pids.insert(pid)
        }
        // Port may still be held by our binary even if the process record was lost.
        if let portPID = pidListening(on: port),
           let binary,
           processCommand(for: portPID)?.contains(binary.standardizedFileURL.path) == true
        {
            pids.insert(portPID)
        }

        for pid in pids {
            killPID(pid, signal: SIGTERM)
        }
        usleep(400_000)
        for pid in pids where isPIDAlive(pid) {
            killPID(pid, signal: SIGKILL)
        }

        removeProcessRecord()

        lock.lock()
        managedProcess = nil
        managedPID = nil
        lock.unlock()

        // Brief wait for port release.
        let deadline = Date().addingTimeInterval(3)
        let releasedPort = recorded?.port ?? port
        while Date() < deadline, isPortOpen(port: releasedPort) {
            usleep(100_000)
        }

        return currentStatus(port: port)
    }

    /// Best-effort stop used on app quit (never throws).
    func stopOnAppExit(port: UInt16) {
        _ = try? stop(port: port)
    }

    /// If the listen port is held by *our* installed binary (orphaned after unclean exit), stop it.
    /// Returns true when an orphan was cleaned.
    @discardableResult
    func reclaimOrphanOnPortIfOurs(port: UInt16) throws -> Bool {
        guard isPortOpen(port: port) else { return false }
        guard let binary = AppPaths.findCoreBinary(in: AppPaths.installDirectory) else {
            throw AppError("端口 \(port) 已被占用，且本机未安装可识别的内核")
        }
        let ours = findInstalledCorePIDs()
        if let portPID = pidListening(on: port) {
            let cmd = processCommand(for: portPID) ?? ""
            if cmd.contains(binary.standardizedFileURL.path) || ours.contains(portPID) {
                _ = try stop(port: port)
                return true
            }
            throw AppError(
                "端口 \(port) 已被其他进程占用（PID \(portPID)）。请结束后再启动，或在配置中更换端口。"
            )
        }
        // Port open but couldn't resolve PID — still try stopping known our processes.
        if !ours.isEmpty {
            _ = try stop(port: port)
            return true
        }
        throw AppError("端口 \(port) 已被占用，请更换端口或手动结束占用进程")
    }

    func restart(gui: GuiConfigFile) throws -> CoreStatus {
        _ = try? stop(port: gui.port)
        return try start(gui: gui)
    }

    // MARK: - Helpers

    private func lockedPID() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return managedPID
    }

    private func isManagedProcessAlive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let process = managedProcess else { return false }
        if process.isRunning { return true }
        managedProcess = nil
        managedPID = nil
        return false
    }

    private func waitForManagementPort(process: Process, port: UInt16, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning {
                throw AppError("CPA 内核启动后立即退出")
            }
            if isPortOpen(port: port) {
                return
            }
            usleep(100_000)
        }
        throw AppError("CPA 内核启动超时：\(Int(timeout)) 秒内未监听管理端口 \(port)")
    }

    private func terminateProcess(_ process: Process) {
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            killPID(process.processIdentifier, signal: SIGKILL)
        }
    }

    private func killPID(_ pid: Int32, signal: Int32) {
        _ = kill(pid, signal)
    }

    /// Run an external tool and capture stdout.
    /// Must drain the pipe *before* `waitUntilExit` — otherwise large output (e.g. `ps -ax`)
    /// fills the ~64KB pipe buffer and deadlocks forever (app stuck bouncing in Dock).
    private func runCapturingStdout(
        executable: String,
        arguments: [String]
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain first so the child can exit when output exceeds the pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// PIDs whose command line is our installed `cli-proxy-api` + this app's config.yaml.
    private func findInstalledCorePIDs() -> [Int32] {
        guard let binary = AppPaths.findCoreBinary(in: AppPaths.installDirectory) else { return [] }
        let binaryPath = binary.standardizedFileURL.path
        let configPath = AppPaths.coreConfigURL.standardizedFileURL.path
        guard let text = runCapturingStdout(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,command="]
        ) else { return [] }
        var result: [Int32] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // "  422 /path/cli-proxy-api -config /path/config.yaml"
            guard let space = trimmed.firstIndex(where: { $0.isWhitespace }) else { continue }
            let pidStr = String(trimmed[..<space])
            guard let pid = Int32(pidStr) else { continue }
            let command = String(trimmed[space...]).trimmingCharacters(in: .whitespaces)
            if Self.commandLineBelongsToApp(command, binaryPath: binaryPath, configPath: configPath) {
                result.append(pid)
            }
        }
        return result
    }

    private func pidListening(on port: UInt16) -> Int32? {
        guard let text = runCapturingStdout(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        ) else { return nil }
        let first = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let first, let pid = Int32(first) else { return nil }
        return pid
    }

    private func processCommand(for pid: Int32) -> String? {
        runCapturingStdout(
            executable: "/bin/ps",
            arguments: ["-p", String(pid), "-o", "command="]
        )?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isPortOpen(port: UInt16) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private func validatedProcessRecord(expectedBinary: URL) -> ProcessRecord? {
        guard let data = try? Data(contentsOf: AppPaths.coreProcessURL),
              let record = try? JSONDecoder().decode(ProcessRecord.self, from: data),
              record.pid > 0,
              URL(fileURLWithPath: record.binaryPath).standardizedFileURL.path
                == expectedBinary.standardizedFileURL.path,
              URL(fileURLWithPath: record.configPath).standardizedFileURL.path
                == AppPaths.coreConfigURL.standardizedFileURL.path,
              isPIDAlive(record.pid),
              processMatchesRecord(record)
        else {
            removeProcessRecord()
            return nil
        }
        return record
    }

    private func writeProcessRecord(_ record: ProcessRecord) throws {
        let data = try JSONEncoder().encode(record)
        try data.write(to: AppPaths.coreProcessURL, options: .atomic)
        try AppPaths.secureSensitiveFile(AppPaths.coreProcessURL)
    }

    private func removeProcessRecord() {
        try? FileManager.default.removeItem(at: AppPaths.coreProcessURL)
    }

    private func isPIDAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func processMatchesRecord(_ record: ProcessRecord) -> Bool {
        guard let command = processCommand(for: record.pid), !command.isEmpty else {
            return false
        }
        return Self.commandLineBelongsToApp(
            command,
            binaryPath: record.binaryPath,
            configPath: record.configPath
        )
    }

    static func commandLineBelongsToApp(
        _ command: String,
        binaryPath: String,
        configPath: String
    ) -> Bool {
        command.contains(binaryPath)
            && command.contains("-config")
            && command.contains(configPath)
    }

    private func readInstalledVersion() -> String? {
        AppPaths.readInstalledCoreVersion()
    }
}
