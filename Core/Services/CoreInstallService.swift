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

    /// Resolve latest release with multiple sources (GitHub API is often rate-limited).
    func checkLatest() async throws -> CoreLatest {
        let platform = detectPlatform()
        var errors: [String] = []

        // 1) Atom feed (no API quota)
        do {
            let version = try await fetchVersionFromAtom()
            return makeLatest(version: version, platform: platform)
        } catch {
            errors.append("Atom: \(error.localizedDescription)")
        }

        // 2) Release page redirect (no API quota)
        do {
            let version = try await fetchVersionFromReleasePage()
            return makeLatest(version: version, platform: platform)
        } catch {
            errors.append("Release 页: \(error.localizedDescription)")
        }

        // 3) GitHub REST API (may hit rate limit)
        do {
            return try await fetchLatestFromAPI(platform: platform)
        } catch {
            errors.append("API: \(error.localizedDescription)")
        }

        // 4) Fall back to bundled version pin if available
        if let pinned = AppPaths.readBundledCoreVersion(), !pinned.isEmpty {
            return makeLatest(version: pinned, platform: platform)
        }

        throw AppError(
            "检查最新内核版本失败（\(errors.joined(separator: "；"))）。可尝试：指定版本安装，或选择本地 .tar.gz 安装包。"
        )
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
        guard !ver.isEmpty else { throw AppError("版本号不能为空") }
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
        let version = versionFromAssetName(name) ?? AppPaths.readBundledCoreVersion() ?? "local"
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
        let url = URL(
            string: "https://github.com/router-for-me/CLIProxyAPI/releases/download/v\(ver)/\(expected)"
        )
        return CoreLatest(version: ver, assetName: expected, downloadURL: url)
    }

    private func fetchVersionFromAtom() async throws -> String {
        let url = URL(string: "https://github.com/router-for-me/CLIProxyAPI/releases.atom")!
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/atom+xml,application/xml,text/xml,*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError("Atom 无响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppError("HTTP \(http.statusCode)")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        if let version = parseVersionFromAtom(text) {
            return version
        }
        throw AppError("Atom 未解析到版本")
    }

    private func fetchVersionFromReleasePage() async throws -> String {
        // Don't follow redirects automatically so we can read Location; use a
        // session that does follow and then parse final URL.
        let url = URL(string: "https://github.com/router-for-me/CLIProxyAPI/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,*/*", forHTTPHeaderField: "Accept")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError("Release 页无响应")
        }
        // Final URL after redirects, e.g. .../releases/tag/v7.2.109
        let finalURL = http.url?.absoluteString ?? ""
        if let range = finalURL.range(of: "/releases/tag/") {
            let tag = String(finalURL[range.upperBound...])
                .split(separator: "/")
                .first
                .map(String.init) ?? ""
            let version = AppPaths.normalizeVersion(tag)
            if !version.isEmpty { return version }
        }
        if !(200..<400).contains(http.statusCode) {
            throw AppError("HTTP \(http.statusCode)")
        }
        throw AppError("Release 页未返回版本标签")
    }

    private func fetchLatestFromAPI(platform: CorePlatform) async throws -> CoreLatest {
        let url = URL(string: "https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest")!
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError("API 无响应")
        }
        if http.statusCode == 403 || http.statusCode == 429 {
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.localizedCaseInsensitiveContains("rate limit") {
                throw AppError("GitHub API 限流")
            }
            throw AppError("HTTP \(http.statusCode)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppError("HTTP \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError("解析 JSON 失败")
        }
        let tag = (json["tag_name"] as? String) ?? ""
        let version = AppPaths.normalizeVersion(tag)
        guard !version.isEmpty else { throw AppError("无 tag_name") }

        let expected = assetName(version: version, platform: platform)
        var downloadURL: URL?
        if let assets = json["assets"] as? [[String: Any]] {
            for asset in assets {
                if let name = asset["name"] as? String, name == expected {
                    if let browser = asset["browser_download_url"] as? String {
                        downloadURL = URL(string: browser)
                    }
                    break
                }
            }
        }
        if downloadURL == nil {
            downloadURL = URL(
                string: "https://github.com/router-for-me/CLIProxyAPI/releases/download/v\(version)/\(expected)"
            )
        }
        return CoreLatest(version: version, assetName: expected, downloadURL: downloadURL)
    }

    private func parseVersionFromAtom(_ xml: String) -> String? {
        // Prefer first <entry> link or title.
        guard let entryRange = xml.range(of: "<entry>") else { return nil }
        let entry = String(xml[entryRange.lowerBound...])
        if let tagRange = entry.range(of: "/releases/tag/") {
            let rest = entry[tagRange.upperBound...]
            let tag = rest.split(whereSeparator: { "\"'<>?# \n\r\t".contains($0) }).first.map(String.init) ?? ""
            let version = AppPaths.normalizeVersion(tag.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            if !version.isEmpty { return version }
        }
        if let titleStart = entry.range(of: "<title>"),
           let titleEnd = entry.range(of: "</title>", range: titleStart.upperBound..<entry.endIndex)
        {
            let title = String(entry[titleStart.upperBound..<titleEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let version = AppPaths.normalizeVersion(title)
            if !version.isEmpty { return version }
        }
        return nil
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

    private func finalizeInstall(version: String, assetName: String) throws -> CoreInstallResult {
        let staging = AppPaths.stagingDirectory
        let install = AppPaths.installDirectory
        let backup = AppPaths.backupDirectory
        let fm = FileManager.default

        // Preserve existing config.yaml if present.
        let existingConfig = install.appendingPathComponent(AppPaths.coreConfigFile)
        var preservedConfig: Data?
        if fm.fileExists(atPath: existingConfig.path) {
            preservedConfig = try? Data(contentsOf: existingConfig)
        }

        // Locate binary in staging (may be nested).
        guard AppPaths.findCoreBinary(in: staging) != nil else {
            throw AppError("安装包中未找到 \(AppPaths.coreBinaryName)")
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

            if let preservedConfig {
                let configURL = install.appendingPathComponent(AppPaths.coreConfigFile)
                try preservedConfig.write(to: configURL, options: .atomic)
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
            try metaData.write(to: AppPaths.coreMetadataURL, options: .atomic)
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
