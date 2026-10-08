import Foundation

actor CoreInstallService {
    private var cancelRequested = false
    private(set) var task = CoreInstallTask()

    func currentTask() -> CoreInstallTask { task }

    /// Clear progress UI state after success / cancel (keeps actor in sync with AppState).
    func resetTask() {
        task = CoreInstallTask()
        cancelRequested = false
    }

    func cancel() {
        cancelRequested = true
        task.cancellable = false
        task.message = "正在取消…"
    }

    func detectPlatform() -> CorePlatform {
        // Release assets use aarch64 (not arm64) for Apple Silicon.
        #if arch(arm64)
        let arch = "arm64"
        let assetArch = "aarch64"
        #else
        let arch = "amd64"
        let assetArch = "amd64"
        #endif
        return CorePlatform(
            os: "darwin",
            arch: arch,
            assetOS: "darwin",
            assetArch: assetArch,
            archiveKind: "tar.gz"
        )
    }

    /// The default channel contains the tested native-Responses attribution patch.
    /// Explicit numeric versions still install official upstream releases.
    func checkLatest() async throws -> CoreLatest {
        let platform = detectPlatform()
        let url = URL(string: "https://api.github.com/repos/xiangsam/MacCLIProxyAPI/releases?per_page=50")!
        do {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw AppError("无法读取兼容内核发布列表")
            }
            for release in releases {
                guard release["draft"] as? Bool != true, release["prerelease"] as? Bool != true,
                      let tag = release["tag_name"] as? String, tag.hasPrefix("cpa-v"),
                      let assets = release["assets"] as? [[String: Any]] else { continue }
                let version = String(tag.dropFirst(5))
                guard version.hasPrefix("8."), version.contains("-mac.") else { continue }
                let latest = makeLatest(version: version, platform: platform)
                if assets.contains(where: { $0["name"] as? String == latest.assetName }) { return latest }
            }
            throw AppError("尚无已发布的兼容内核")
        } catch {
            // A pinned compatible version is safe when the GitHub API is rate-limited.
            if let pinned = AppPaths.readBundledCoreVersion(), pinned.contains("-mac.") {
                return makeLatest(version: pinned, platform: platform)
            }
            throw error
        }
    }

    func installLatest(progress: @escaping @MainActor (CoreInstallTask) -> Void) async throws -> CoreInstallResult {
        let latest = try await checkLatest()
        return try await install(version: latest.version, downloadURL: latest.downloadURL, assetName: latest.assetName, progress: progress)
    }

    /// Install a specific version (e.g. 7.2.109) without needing the latest check API.
    func installVersion(
        _ version: String,
        progress: @escaping @MainActor (CoreInstallTask) -> Void
    ) async throws -> CoreInstallResult {
        let platform = detectPlatform()
        let ver = AppPaths.normalizeVersion(version)
        guard ver.range(of: #"^\d+\.\d+\.\d+(-mac\.\d+)?$"#, options: .regularExpression) != nil else {
            throw AppError("请输入版本号，例如 8.0.21 或 8.0.21-mac.1")
        }
        let latest = makeLatest(version: ver, platform: platform)
        return try await install(
            version: latest.version,
            downloadURL: latest.downloadURL,
            assetName: latest.assetName,
            progress: progress
        )
    }

    /// Infer version from archive file name when possible.
    func installFromLocalFile(
        _ archivePath: URL,
        progress: @escaping @MainActor (CoreInstallTask) -> Void
    ) async throws -> CoreInstallResult {
        let name = archivePath.lastPathComponent
        try Self.validateArchiveFileName(name)
        let version = versionFromAssetName(name) ?? "local"
        return try await installLocalArchive(
            version: version,
            assetName: name,
            archivePath: archivePath,
            progress: progress
        )
    }

    private func makeLatest(version: String, platform: CorePlatform) -> CoreLatest {
        let ver = AppPaths.normalizeVersion(version)
        let expected = assetName(version: ver, platform: platform)
        return CoreLatest(version: ver, assetName: expected,
            downloadURL: Self.downloadURL(version: ver, assetName: expected))
    }

    static func downloadURL(version: String, assetName: String) -> URL? {
        let patched = version.contains("-mac.")
        let repository = patched ? "xiangsam/MacCLIProxyAPI" : "router-for-me/CLIProxyAPI"
        let tag = patched ? "cpa-v" + version : "v" + version
        return URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(assetName)")
    }

    private func versionFromAssetName(_ name: String) -> String? {
        // CLIProxyAPI_7.2.109_darwin_aarch64.tar.gz
        let base = name
            .replacingOccurrences(of: ".tar.gz", with: "")
            .replacingOccurrences(of: ".zip", with: "")
        let parts = base.split(separator: "_")
        // CLIProxyAPI, version, darwin, arch
        guard parts.count >= 2 else { return nil }
        let version = AppPaths.normalizeVersion(String(parts[1]))
        return version.isEmpty ? nil : version
    }

    private var userAgent: String {
        "MacCLIProxyAPI/0.1 (+https://github.com/router-for-me/CLIProxyAPI)"
    }

    func installLocalArchive(
        version: String,
        assetName: String,
        archivePath: URL,
        progress: @escaping @MainActor (CoreInstallTask) -> Void
    ) async throws -> CoreInstallResult {
        cancelRequested = false
        task = CoreInstallTask(running: true, cancellable: true, phase: "准备安装", message: "使用本地安装包")
        await publish(progress)

        try ensureCoreNotRunning()
        try resetDirectory(AppPaths.stagingDirectory)

        task.phase = "解压"
        task.message = "正在解压 \(assetName)"
        await publish(progress)

        try Self.validateArchiveEntries(archivePath)
        try extractArchive(archivePath, to: AppPaths.stagingDirectory)
        try checkCancelled()

        try Self.validateStagedCore(in: AppPaths.stagingDirectory, expectedArch: detectPlatform().arch)
        let result = try finalizeInstall(version: version, assetName: assetName)
        task.running = false
        task.cancellable = false
        task.phase = "完成"
        task.percent = 100
        task.result = result
        task.message = "安装完成 \(version)"
        await publish(progress)
        return result
    }

    private func install(
        version: String,
        downloadURL: URL?,
        assetName: String,
        progress: @escaping @MainActor (CoreInstallTask) -> Void
    ) async throws -> CoreInstallResult {
        cancelRequested = false
        task = CoreInstallTask(running: true, cancellable: true, phase: "检查版本", message: version)
        await publish(progress)

        try ensureCoreNotRunning()
        try AppPaths.ensureBaseDirectories()
        try resetDirectory(AppPaths.downloadDirectory)
        try resetDirectory(AppPaths.stagingDirectory)

        guard let downloadURL else {
            throw AppError("未找到适用于当前平台的内核资源: \(assetName)")
        }

        let archivePath = AppPaths.downloadDirectory.appendingPathComponent(assetName)
        task.phase = "下载"
        task.message = assetName
        await publish(progress)

        try await download(from: downloadURL, to: archivePath, progress: progress)
        try checkCancelled()

        task.phase = "解压"
        task.message = "正在解压"
        task.percent = nil
        await publish(progress)

        try Self.validateArchiveEntries(archivePath)
        try extractArchive(archivePath, to: AppPaths.stagingDirectory)
        try checkCancelled()

        try Self.validateStagedCore(in: AppPaths.stagingDirectory, expectedArch: detectPlatform().arch)
        let result = try finalizeInstall(version: version, assetName: assetName)
        task.running = false
        task.cancellable = false
        task.phase = "完成"
        task.percent = 100
        task.result = result
        task.message = "安装完成 \(version)"
        await publish(progress)
        return result
    }

    func finalizeInstall(
        version: String, assetName: String,
        staging: URL = AppPaths.stagingDirectory,
        install: URL = AppPaths.installDirectory,
        backup: URL = AppPaths.backupDirectory,
        migrationBackups: URL = AppPaths.baseDirectory.appendingPathComponent("config-backups")
    ) throws -> CoreInstallResult {
        let fm = FileManager.default

        // Preserve existing config.yaml if present.
        let existingConfig = install.appendingPathComponent(AppPaths.coreConfigFile)
        var preservedConfig: Data?
        if fm.fileExists(atPath: existingConfig.path) {
            preservedConfig = try Data(contentsOf: existingConfig)
        }

        guard let stagedBinary = AppPaths.findCoreBinary(in: staging) else {
            throw AppError("安装包中未找到 \(AppPaths.coreBinaryName)")
        }
        var migrationVersion = version
        if version == "local" {
            let example = stagedBinary.deletingLastPathComponent().appendingPathComponent(AppPaths.coreExampleConfigFile)
            if let yaml = try? String(contentsOf: example, encoding: .utf8),
               let root = try? CoreConfigLayout.parse(yaml), CoreConfigLayout.isV8(root) {
                migrationVersion = CoreConfigLayout.usesEarlyV8Paths(root) ? "8.0.0" : "8"
            }
        }
        var authRelativePath: String?
        if let preservedConfig, let yaml = String(data: preservedConfig, encoding: .utf8) {
            let root = try CoreConfigLayout.readLegacy(yaml)
            if let authDir = root["auth-dir"] as? String {
                let resolved = AppPaths.resolveAuthDirectory(authDir: authDir, installDir: install).standardizedFileURL
                let prefix = install.standardizedFileURL.path + "/"
                if resolved.path == install.standardizedFileURL.path {
                    throw AppError("auth-dir 不能指向内核安装目录本身；请先迁移到独立目录")
                }
                var isDirectory: ObjCBool = false
                if resolved.path.hasPrefix(prefix), fm.fileExists(atPath: resolved.path, isDirectory: &isDirectory) {
                    guard isDirectory.boolValue else { throw AppError("auth-dir 必须指向目录") }
                    authRelativePath = String(resolved.path.dropFirst(prefix.count))
                }
            }
        }

        // Validate and migrate before moving either installation. A parse/read failure must
        // never replace a working core or silently discard its credentials.
        let migratedConfig: Data? = try preservedConfig.map { data in
            guard let yaml = String(data: data, encoding: .utf8) else {
                throw AppError("内核配置不是 UTF-8；已保留当前安装")
            }
            return Data(try CoreConfigLayout.migrate(yaml, to: migrationVersion).utf8)
        }

        if fm.fileExists(atPath: backup.path) {
            try fm.removeItem(at: backup)
        }
        let hadExistingInstall = fm.fileExists(atPath: install.path)
        if hadExistingInstall {
            try fm.moveItem(at: install, to: backup)
        }

        do {
            try fm.moveItem(at: staging, to: install)
            // Custom auth directories inside cpa-core must survive replacing that directory.
            // The default ../oauth lives outside it and needs no copy.
            if let authRelativePath {
                let destination = install.appendingPathComponent(authRelativePath)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: backup.appendingPathComponent(authRelativePath), to: destination)
            }

            if let migratedConfig {
                if let preservedConfig, preservedConfig != migratedConfig {
                    try CoreConfigStore.backupBeforeMigration(preservedConfig, directory: migrationBackups)
                }
                let configURL = install.appendingPathComponent(AppPaths.coreConfigFile)
                try migratedConfig.write(to: configURL, options: .atomic)
                try AppPaths.secureSensitiveFile(configURL)
            }

            guard let binary = AppPaths.findCoreBinary(in: install) else {
                throw AppError("安装后的目录中未找到 \(AppPaths.coreBinaryName)")
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            Self.clearQuarantine(binary)

            let meta: [String: Any] = [
                "version": AppPaths.normalizeVersion(version),
                "asset_name": assetName,
                "installed_at_unix": Int(Date().timeIntervalSince1970),
            ]
            let metaData = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            try metaData.write(to: install.appendingPathComponent(AppPaths.coreMetadataFile), options: .atomic)
        } catch {
            try? fm.removeItem(at: install)
            if hadExistingInstall, fm.fileExists(atPath: backup.path) {
                try? fm.moveItem(at: backup, to: install)
            }
            throw error
        }

        return CoreInstallResult(
            version: AppPaths.normalizeVersion(version),
            assetName: assetName,
            installDir: install.path,
            binaryPath: AppPaths.findCoreBinary(in: install)?.path
        )
    }

    /// Gatekeeper refuses to exec a quarantined binary. The offline archive now
    /// rides inside the app bundle, so the flag can reach the core the same way
    /// it reaches other bundled resources.
    private static func clearQuarantine(_ url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = removexattr(path, "com.apple.quarantine", 0)
        }
    }

    static func validateArchiveFileName(_ name: String) throws {
        let lower = name.lowercased()
        guard lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") else {
            throw AppError("内核安装包必须是 .tar.gz 或 .tgz")
        }
    }

    static func validateArchiveEntries(_ archive: URL) throws {
        try validateArchiveFileName(archive.lastPathComponent)
        let output = try runAndCapture(
            executable: "/usr/bin/tar",
            arguments: ["-tzf", archive.path],
            failureMessage: "无法读取内核安装包目录"
        )
        let entries = output.split(whereSeparator: \.isNewline).map(String.init)
        guard !entries.isEmpty else {
            throw AppError("内核安装包为空")
        }
        for entry in entries {
            let path = entry.replacingOccurrences(of: "\\", with: "/")
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            if path.hasPrefix("/") || components.contains("..") {
                throw AppError("内核安装包包含不安全路径：\(entry)")
            }
        }
    }

    static func validateStagedCore(in directory: URL, expectedArch: String) throws {
        guard let binary = AppPaths.findCoreBinary(in: directory) else {
            throw AppError("安装包中未找到 \(AppPaths.coreBinaryName)")
        }
        let description = try runAndCapture(
            executable: "/usr/bin/file",
            arguments: ["-b", binary.path],
            failureMessage: "无法识别内核二进制架构"
        ).lowercased()
        let matches: Bool
        switch expectedArch {
        case "arm64":
            matches = description.contains("arm64")
        case "amd64":
            matches = description.contains("x86_64")
        default:
            matches = false
        }
        guard matches else {
            throw AppError("内核架构不匹配：需要 \(expectedArch)，安装包为 \(description.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private static func runAndCapture(
        executable: String,
        arguments: [String],
        failureMessage: String
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError(detail?.isEmpty == false ? "\(failureMessage)：\(detail!)" : failureMessage)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func ensureCoreNotRunning() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", AppPaths.coreBinaryName]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let text = String(data: data, encoding: .utf8),
           text.split(whereSeparator: \.isNewline).contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        {
            throw AppError("CPA 内核正在运行，请先停止后再安装或更新")
        }
    }

    private func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @MainActor (CoreInstallTask) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError("下载内核失败")
        }
        let total = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var downloaded: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)

        for try await byte in asyncBytes {
            try checkCancelled()
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                downloaded += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                task.downloaded = downloaded
                task.total = total
                if let total, total > 0 {
                    task.percent = Double(downloaded) / Double(total) * 100
                }
                await publish(progress)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            downloaded += Int64(buffer.count)
        }
        task.downloaded = downloaded
        task.total = total
        if let total, total > 0 {
            task.percent = Double(downloaded) / Double(total) * 100
        }
        await publish(progress)
    }

    private func extractArchive(_ archive: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppError("解压内核安装包失败")
        }
    }

    private func resetDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func checkCancelled() throws {
        if cancelRequested {
            task.running = false
            task.message = "已取消"
            throw AppError("安装已取消")
        }
    }

    private func publish(_ progress: @escaping @MainActor (CoreInstallTask) -> Void) async {
        let snapshot = task
        await MainActor.run {
            progress(snapshot)
        }
    }

    private func assetName(version: String, platform: CorePlatform) -> String {
        let ver = AppPaths.normalizeVersion(version)
        return "CLIProxyAPI_\(ver)_\(platform.assetOS)_\(platform.assetArch).\(platform.archiveKind)"
    }
}
