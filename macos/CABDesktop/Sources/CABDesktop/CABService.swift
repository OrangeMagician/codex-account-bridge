import AppKit
import Foundation

private final class CommandOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var standardText = ""
    private var errorText = ""

    func append(_ data: Data, toStandardOutput: Bool) -> String? {
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return nil }
        lock.lock()
        if toStandardOutput { standardText += chunk } else { errorText += chunk }
        lock.unlock()
        return chunk
    }

    func result(exitCode: Int32) -> CommandResult {
        lock.lock()
        defer { lock.unlock() }
        return CommandResult(output: standardText, errorOutput: errorText, exitCode: exitCode)
    }
}

final class CABService {
    private let fileManager = FileManager.default

    func loadStatus(target: BridgeTarget, remoteHost: String) async throws -> BridgeStatus {
        let result = try await execute(["status", "--json"], target: target, remoteHost: remoteHost)
        guard result.exitCode == 0 else {
            throw BridgeError.commandFailed(preferredMessage(result))
        }
        guard let data = result.output.data(using: .utf8) else {
            throw BridgeError.invalidStatus("cab 返回了无法读取的状态。")
        }
        do {
            return try JSONDecoder().decode(BridgeStatus.self, from: data)
        } catch {
            throw BridgeError.invalidStatus("无法解析 cab 状态：\(error.localizedDescription)")
        }
    }

    func loadUsage(target: BridgeTarget, remoteHost: String) async throws -> UsageReport {
        let result = try await execute(["usage", "--json"], target: target, remoteHost: remoteHost)
        guard result.exitCode == 0 else {
            throw BridgeError.commandFailed(preferredMessage(result))
        }
        guard let data = result.output.data(using: .utf8) else {
            throw BridgeError.invalidUsage("cab 返回了无法读取的额度信息。")
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(UsageReport.self, from: data)
        } catch {
            throw BridgeError.invalidUsage("无法解析 cab 额度信息：\(error.localizedDescription)")
        }
    }

    func execute(
        _ arguments: [String],
        target: BridgeTarget,
        remoteHost: String,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandResult {
        let process = Process()
        if target == .local {
            guard let executable = cabExecutable() else { throw BridgeError.executableMissing }
            process.executableURL = executable
            process.arguments = arguments
        } else {
            let host = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { throw BridgeError.commandFailed("请先填写 SSH 主机。") }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            var sshArguments: [String] = []
            if arguments.contains("--browser-auth") {
                sshArguments += [
                    "-o", "ExitOnForwardFailure=yes",
                    "-L", "127.0.0.1:1455:127.0.0.1:1455",
                    "-L", "127.0.0.1:1457:127.0.0.1:1457",
                ]
            }
            process.arguments = sshArguments + ["--", host, "cab"] + arguments
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withCheckedThrowingContinuation { continuation in
            let buffer = CommandOutputBuffer()

            stdout.fileHandleForReading.readabilityHandler = { handle in
                if let chunk = buffer.append(handle.availableData, toStandardOutput: true) { onOutput?(chunk) }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                if let chunk = buffer.append(handle.availableData, toStandardOutput: false) { onOutput?(chunk) }
            }
            process.terminationHandler = { finished in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                if let chunk = buffer.append(stdout.fileHandleForReading.readDataToEndOfFile(), toStandardOutput: true) { onOutput?(chunk) }
                if let chunk = buffer.append(stderr.fileHandleForReading.readDataToEndOfFile(), toStandardOutput: false) { onOutput?(chunk) }
                continuation.resume(returning: buffer.result(exitCode: finished.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    func launchCodexInTerminal(target: BridgeTarget, remoteHost: String) throws {
        let command: String
        if target == .local {
            guard let executable = cabExecutable() else { throw BridgeError.executableMissing }
            command = "\(shellQuote(executable.path)) run"
        } else {
            let host = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { throw BridgeError.commandFailed("请先填写 SSH 主机。") }
            command = "ssh -- \(shellQuote(host)) cab run"
        }
        let script = "tell application \"Terminal\" to do script \(appleScriptQuote(command))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try process.run()
    }

    func stopCodexDesktop() async throws {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
              Bundle(url: applicationURL)?.executableURL != nil else {
            throw BridgeError.commandFailed("未找到已安装的 Codex 桌面客户端。")
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        for application in running where !application.isTerminated {
            _ = application.terminate()
        }
        for _ in 0..<50 {
            if running.allSatisfy(\.isTerminated) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard running.allSatisfy(\.isTerminated) else {
            throw BridgeError.commandFailed("Codex 桌面客户端仍在运行，请先保存任务并手动退出后重试。")
        }
    }

    func startCodexDesktop(codexHome: String) async throws {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
              Bundle(url: applicationURL)?.executableURL != nil else {
            throw BridgeError.commandFailed("未找到已安装的 Codex 桌面客户端。")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome
        environment.removeValue(forKey: "CODEX_THREAD_ID")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = environment
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let application {
                    application.activate(options: [.activateIgnoringOtherApps])
                    continuation.resume()
                } else {
                    continuation.resume(throwing: BridgeError.commandFailed("Codex 桌面客户端未能重新启动。"))
                }
            }
        }
    }

    func restartCodexDesktop(codexHome: String) async throws {
        try await stopCodexDesktop()
        try await startCodexDesktop(codexHome: codexHome)
    }

    /// Marks the official Codex thread catalog for a full rebuild from the
    /// selected CODEX_HOME's active and archived session directories. CAB never
    /// reads thread rows or rollout contents; it checkpoints, verifies, backs up,
    /// and resets only the official backfill watermark while Codex is stopped.
    func prepareCodexThreadIndexRebuild(codexHome: String) async throws -> URL? {
        let homeURL = URL(fileURLWithPath: codexHome, isDirectory: true).standardizedFileURL
        let databaseURL = homeURL.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: databaseURL.path) else { return nil }
        let values = try databaseURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw BridgeError.commandFailed("拒绝修改非普通文件或符号链接形式的 Codex 线程索引。")
        }
        guard fileManager.isExecutableFile(atPath: "/usr/bin/sqlite3") else {
            throw BridgeError.commandFailed("系统缺少 /usr/bin/sqlite3，无法安全重建 Codex 对话索引。")
        }

        let checked = try await runSQLite(
            databaseURL,
            sql: "PRAGMA busy_timeout=5000; PRAGMA wal_checkpoint(TRUNCATE); PRAGMA integrity_check;"
        )
        guard checked.split(whereSeparator: \.isNewline).contains("ok") else {
            throw BridgeError.commandFailed("Codex 线程索引完整性检查失败，已停止切换。")
        }

        let backupURL = homeURL.appendingPathComponent("state_5.sqlite.cab-backup-\(Int(Date().timeIntervalSince1970 * 1_000))")
        try fileManager.copyItem(at: databaseURL, to: backupURL)
        do {
            let reset = try await runSQLite(
                databaseURL,
                sql: "PRAGMA busy_timeout=5000; BEGIN IMMEDIATE; DELETE FROM backfill_state; COMMIT; PRAGMA integrity_check;"
            )
            guard reset.split(whereSeparator: \.isNewline).contains("ok") else {
                throw BridgeError.commandFailed("重置 Codex 对话索引水位后完整性检查失败；备份保存在 \(backupURL.path)。")
            }
        } catch {
            throw BridgeError.commandFailed("无法准备 Codex 对话索引重建；原索引备份保存在 \(backupURL.path)。\n\(error.localizedDescription)")
        }
        return backupURL
    }

    private func runSQLite(_ databaseURL: URL, sql: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [databaseURL.path, sql]
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { finished in
                let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: BridgeError.commandFailed(errorOutput.isEmpty ? "sqlite3 执行失败。" : errorOutput))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func hasRunningCodexProcesses(target: BridgeTarget, remoteHost: String) async throws -> Bool {
        let process = Process()
        if target == .local {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-x", "codex"]
        } else {
            let host = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { throw BridgeError.commandFailed("请先填写 SSH 主机。") }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["--", host, "pgrep", "-x", "codex"]
        }
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                switch finished.terminationStatus {
                case 0:
                    continuation.resume(returning: true)
                case 1:
                    continuation.resume(returning: false)
                default:
                    let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let message = detail.flatMap { $0.isEmpty ? nil : $0 } ?? "无法确认 Codex 是否已经退出。"
                    continuation.resume(throwing: BridgeError.commandFailed(message))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func discoverSSHHosts() throws -> [String] {
        try SSHConfigDiscovery().discover()
    }

    func installedBrowsers() -> [BrowserChoice] {
        BrowserChoice.allCases.filter { browserApplicationURL($0) != nil }
    }

    func installedPrivateBrowsers() -> [BrowserChoice] {
        installedBrowsers().filter { $0.privateArgument != nil }
    }

    func officialLoginURL(in text: String) -> URL? {
        let sanitized = text.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(sanitized.startIndex..., in: sanitized)
        for match in detector.matches(in: sanitized, options: [], range: range) {
            guard let url = match.url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { continue }
            guard host == "openai.com" || host.hasSuffix(".openai.com") || host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") else { continue }
            if host == "auth.openai.com", url.path == "/codex/device" { return url }
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let redirectValue = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
                  let redirect = URL(string: redirectValue),
                  redirect.scheme?.lowercased() == "http",
                  redirect.host?.lowercased() == "localhost",
                  redirect.path == "/auth/callback",
                  redirect.port != nil else { continue }
            return url
        }
        return nil
    }

    func openDefaultBrowser(url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw BridgeError.commandFailed("无法打开系统默认浏览器。")
        }
    }

    func openBrowser(_ browser: BrowserChoice, url: URL, privateWindow: Bool) throws {
        guard let application = browserApplicationURL(browser) else {
            throw BridgeError.commandFailed("未找到 \(browser.title)。")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if privateWindow {
            guard let privateArgument = browser.privateArgument else {
                throw BridgeError.commandFailed("\(browser.title) 不支持由 CAB 自动打开私人窗口。")
            }
            process.arguments = ["-na", application.path, "--args", privateArgument, url.absoluteString]
        } else {
            process.arguments = ["-a", application.path, url.absoluteString]
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BridgeError.commandFailed("无法在 \(browser.title) 打开登录页面。")
        }
    }

    private func cabExecutable() -> URL? {
        var candidates: [String] = []
        if let configured = ProcessInfo.processInfo.environment["CAB_EXECUTABLE"], !configured.isEmpty {
            candidates.append(configured)
        }
        candidates += [
            "/opt/homebrew/bin/cab",
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/cab").path,
            "/usr/local/bin/cab",
        ]
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    private func browserApplicationURL(_ browser: BrowserChoice) -> URL? {
        let roots = [URL(fileURLWithPath: "/Applications"), fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for root in roots {
            for name in browser.applicationNames {
                let candidate = root.appendingPathComponent(name)
                if fileManager.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    private func preferredMessage(_ result: CommandResult) -> String {
        let error = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return error.isEmpty ? (output.isEmpty ? "cab 命令执行失败（\(result.exitCode)）。" : output) : error
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
