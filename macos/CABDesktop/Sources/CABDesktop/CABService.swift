import AppKit
import Foundation

final class CommandOutputBuffer: @unchecked Sendable {
    private static let maximumCharactersPerStream = 2_000_000
    private static let truncationMarker = "\n… CAB 已截断过长的命令输出 …\n"
    private let lock = NSLock()
    private var standardText = ""
    private var errorText = ""
    private var standardTruncated = false
    private var errorTruncated = false

    func append(_ data: Data, toStandardOutput: Bool) -> String? {
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return nil }
        lock.lock()
        if toStandardOutput {
            appendLimited(chunk, text: &standardText, truncated: &standardTruncated)
        } else {
            appendLimited(chunk, text: &errorText, truncated: &errorTruncated)
        }
        lock.unlock()
        return chunk
    }

    private func appendLimited(_ chunk: String, text: inout String, truncated: inout Bool) {
        guard !truncated else { return }
        let remaining = Self.maximumCharactersPerStream - text.count
        if chunk.count <= remaining {
            text += chunk
            return
        }
        if remaining > 0 { text += chunk.prefix(remaining) }
        text += Self.truncationMarker
        truncated = true
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

    func loadUsage(
        target: BridgeTarget,
        remoteHost: String,
        accountNames: [String]? = nil
    ) async throws -> UsageReport {
        guard let accountNames else {
            return try await loadUsage(arguments: ["usage", "--json"], target: target, remoteHost: remoteHost)
        }
        var reports: [AccountUsageReport] = []
        var fetchedAt = Date.distantPast
        for accountName in accountNames.sorted() {
            let report = try await loadUsage(
                arguments: ["usage", "--account", accountName, "--json"],
                target: target,
                remoteHost: remoteHost
            )
            reports.append(contentsOf: report.accounts)
            fetchedAt = max(fetchedAt, report.fetchedAt)
        }
        return UsageReport(fetchedAt: fetchedAt, accounts: reports)
    }

    private func loadUsage(
        arguments: [String],
        target: BridgeTarget,
        remoteHost: String
    ) async throws -> UsageReport {
        let result = try await execute(arguments, target: target, remoteHost: remoteHost)
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

    func loadAgentBindings(remoteHost: String) async throws -> AgentBindingReport {
        let result = try await execute(["agent", "list", "--json"], target: .remote, remoteHost: remoteHost)
        guard result.exitCode == 0 else { throw BridgeError.commandFailed(preferredMessage(result)) }
        guard let data = result.output.data(using: .utf8) else {
            throw BridgeError.commandFailed("cab 返回了无法读取的智能体绑定信息。")
        }
        do {
            return try JSONDecoder().decode(AgentBindingReport.self, from: data)
        } catch {
            throw BridgeError.commandFailed("无法解析智能体绑定信息：\(error.localizedDescription)")
        }
    }

    func loadCodexProcesses(target: BridgeTarget, remoteHost: String) async throws -> CodexProcessReport {
        let result = try await execute(["processes", "list", "--json"], target: target, remoteHost: remoteHost)
        guard result.exitCode == 0 else { throw BridgeError.commandFailed(preferredMessage(result)) }
        guard let data = result.output.data(using: .utf8) else { throw BridgeError.commandFailed("cab 返回了无法读取的 Codex 进程信息。") }
        do { return try JSONDecoder().decode(CodexProcessReport.self, from: data) }
        catch { throw BridgeError.commandFailed("无法解析 Codex 进程信息：\(error.localizedDescription)") }
    }

    func loadRemoteSwitchCodexProcesses(remoteHost: String) async throws -> [CodexProcessStatus] {
        let bindings = try await loadAgentBindings(remoteHost: remoteHost)
        let activeServices = bindings.agents.filter(\.active).map(\.service)
        let invalidService = activeServices.first {
            $0.range(of: #"^[A-Za-z0-9_.@-]+\.service$"#, options: .regularExpression) == nil
        }
        guard invalidService == nil else {
            throw BridgeError.commandFailed("远程智能体返回了无效的 systemd 服务名，已取消切换以避免误关进程。")
        }

        let agentMainPIDs: Set<Int>
        if activeServices.isEmpty {
            agentMainPIDs = []
        } else {
            let result = try await executeRemoteProgram(
                "/usr/bin/systemctl",
                arguments: ["--user", "show"] + activeServices + ["--property=Names", "--property=MainPID"],
                remoteHost: remoteHost
            )
            guard result.exitCode == 0 else { throw BridgeError.commandFailed(preferredMessage(result)) }
            let mainPIDs = systemdMainPIDsByService(from: result.output)
            guard activeServices.allSatisfy({ (mainPIDs[$0] ?? 0) > 0 }) else {
                throw BridgeError.commandFailed("无法确认全部远程智能体的进程归属，已取消切换以避免误关智能体。")
            }
            agentMainPIDs = Set(activeServices.compactMap { mainPIDs[$0] })
        }

        let report = try await loadCodexProcesses(target: .remote, remoteHost: remoteHost)
        return remoteUserCodexProcesses(report.processes, excludingParentPIDs: agentMainPIDs)
    }

    func stopCodexProcesses(_ pids: [Int], target: BridgeTarget, remoteHost: String) async throws {
        guard !pids.isEmpty else { return }
        let result = try await execute(["processes", "stop", "--pids", pids.map(String.init).joined(separator: ","), "--confirm-stop-codex"], target: target, remoteHost: remoteHost)
        guard result.exitCode == 0 else { throw BridgeError.commandFailed(preferredMessage(result)) }
    }

    func loadLegacySessions(remoteHost: String) async throws -> LegacySessionReport {
        let result = try await execute(["sessions", "legacy-status", "--json"], target: .remote, remoteHost: remoteHost)
        guard result.exitCode == 0, let data = result.output.data(using: .utf8) else { throw BridgeError.commandFailed(preferredMessage(result)) }
        do { return try JSONDecoder().decode(LegacySessionReport.self, from: data) }
        catch { throw BridgeError.commandFailed("无法解析旧会话信息：\(error.localizedDescription)") }
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
            process.environment = localCABEnvironment(
                baseEnvironment: ProcessInfo.processInfo.environment,
                homeDirectory: fileManager.homeDirectoryForCurrentUser,
                executableCheck: fileManager.isExecutableFile(atPath:)
            )
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

    private func executeRemoteProgram(_ executable: String, arguments: [String], remoteHost: String) async throws -> CommandResult {
        let host = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw BridgeError.commandFailed("请先填写 SSH 主机。") }
        return try await runLocalProcess(
            "/usr/bin/ssh",
            arguments: ["--", host, executable] + arguments
        )
    }

    func launchCodexInTerminal(target: BridgeTarget, remoteHost: String) throws {
        let command: String
        if target == .local {
            guard let executable = cabExecutable() else { throw BridgeError.executableMissing }
            let environment = localCABEnvironment(
                baseEnvironment: ProcessInfo.processInfo.environment,
                homeDirectory: fileManager.homeDirectoryForCurrentUser,
                executableCheck: fileManager.isExecutableFile(atPath:)
            )
            let codexPrefix = environment["CAB_REAL_CODEX"].map { "CAB_REAL_CODEX=\(shellQuote($0)) " } ?? ""
            command = "\(codexPrefix)\(shellQuote(executable.path)) run"
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

    /// Merges only the official desktop app's workspace catalog into the target
    /// CODEX_HOME. Authentication, config, plugins, prompts, and unrelated UI
    /// state remain account-local.
    func synchronizeCodexWorkspaceState(
        sourceHome: String,
        targetHome: String,
        knownHomes: [String]
    ) throws -> CodexWorkspaceSyncResult {
        try CodexWorkspaceState.synchronize(
            sourceHome: sourceHome,
            targetHome: targetHome,
            knownHomes: knownHomes
        )
    }

    func restoreCodexWorkspaceState(_ result: CodexWorkspaceSyncResult) throws {
        try CodexWorkspaceState.restore(result)
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
            do {
                try restoreCodexThreadIndex(backupURL: backupURL, codexHome: codexHome)
            } catch let restoreError {
                throw BridgeError.commandFailed("无法准备 Codex 对话索引重建，且自动恢复失败。备份保存在 \(backupURL.path)。\n\(error.localizedDescription)\n恢复错误：\(restoreError.localizedDescription)")
            }
            throw BridgeError.commandFailed("无法准备 Codex 对话索引重建；已自动恢复原索引。\n\(error.localizedDescription)")
        }
        return backupURL
    }

    func restoreCodexThreadIndex(backupURL: URL, codexHome: String) throws {
        let homeURL = URL(fileURLWithPath: codexHome, isDirectory: true).standardizedFileURL
        let databaseURL = homeURL.appendingPathComponent("state_5.sqlite")
        let safeBackup = backupURL.standardizedFileURL
        guard safeBackup.deletingLastPathComponent() == homeURL,
              safeBackup.lastPathComponent.hasPrefix("state_5.sqlite.cab-backup-") else {
            throw BridgeError.commandFailed("拒绝从账号目录外的文件恢复 Codex 线程索引。")
        }
        let values = try safeBackup.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw BridgeError.commandFailed("Codex 线程索引备份不是安全的普通文件。")
        }
        let staged = homeURL.appendingPathComponent(".state_5.sqlite.restore-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staged) }
        try fileManager.copyItem(at: safeBackup, to: staged)
        _ = try fileManager.replaceItemAt(databaseURL, withItemAt: staged)
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

    func runningNonDesktopCodexProcesses(knownHomes: [String]) async throws -> [CodexProcessConflict] {
        let pgrep = try await runLocalProcess("/usr/bin/pgrep", arguments: ["-x", "codex"])
        if pgrep.exitCode == 1 { return [] }
        guard pgrep.exitCode == 0 else {
            throw BridgeError.commandFailed(pgrep.errorOutput.nonEmpty ?? "无法枚举正在运行的 Codex 进程。")
        }
        let desktopPath = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")?.standardizedFileURL.path
        var result: [CodexProcessConflict] = []
        for line in pgrep.output.split(whereSeparator: \.isNewline) {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            let ps = try await runLocalProcess("/bin/ps", arguments: ["-ww", "-p", String(pid), "-o", "comm="])
            guard ps.exitCode == 0 else { continue }
            let executablePath = ps.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !isCodexDesktopProcess(executablePath: executablePath, desktopApplicationPath: desktopPath) else { continue }
            let title = try await codexThreadTitle(pid: pid, knownHomes: knownHomes)
            result.append(CodexProcessConflict(pid: pid, label: codexProcessLabel(executablePath: executablePath), title: title))
        }
        return result
    }

    func stopLocalCodexProcesses(_ pids: [Int32]) async throws {
        guard !pids.isEmpty else { return }
        let result = try await execute(
            ["processes", "stop", "--pids", pids.map(String.init).joined(separator: ","), "--confirm-stop-codex"],
            target: .local,
            remoteHost: ""
        )
        guard result.exitCode == 0 else { throw BridgeError.commandFailed(preferredMessage(result)) }
    }

    private func codexThreadTitle(pid: Int32, knownHomes: [String]) async throws -> String? {
        let ps = try await runLocalProcess("/bin/ps", arguments: ["-ww", "-p", String(pid), "-o", "args="])
        guard ps.exitCode == 0 else { return nil }
        let range = NSRange(ps.output.startIndex..., in: ps.output)
        let expression = try NSRegularExpression(pattern: #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#)
        let threadIDs = expression.matches(in: ps.output, range: range).compactMap { match -> String? in
            guard let valueRange = Range(match.range, in: ps.output) else { return nil }
            return String(ps.output[valueRange]).lowercased()
        }
        guard !threadIDs.isEmpty, FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { return nil }
        for home in knownHomes {
            let database = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("state_5.sqlite")
            guard FileManager.default.fileExists(atPath: database.path) else { continue }
            for threadID in threadIDs {
                let sql = "SELECT COALESCE(NULLIF(name,''), NULLIF(title,'')) FROM threads WHERE id='\(threadID)' LIMIT 1;"
                let query = try await runLocalProcess("/usr/bin/sqlite3", arguments: ["-readonly", database.path, sql])
                if query.exitCode == 0, let title = query.output.nonEmpty {
                    return title
                }
            }
        }
        return nil
    }

    private func runLocalProcess(_ executable: String, arguments: [String]) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { finished in
                continuation.resume(returning: CommandResult(
                    output: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                    errorOutput: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                    exitCode: finished.terminationStatus
                ))
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
                  let port = redirect.port,
                  port == 1455 || port == 1457 else { continue }
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

func localCABEnvironment(
    baseEnvironment: [String: String],
    homeDirectory: URL,
    executableCheck: (String) -> Bool
) -> [String: String] {
    var environment = baseEnvironment
    let searchDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        homeDirectory.appendingPathComponent(".local/bin").path,
    ]
    let existingDirectories = (baseEnvironment["PATH"] ?? "")
        .split(separator: ":")
        .map(String.init)
    var seen = Set<String>()
    environment["PATH"] = (searchDirectories + existingDirectories)
        .filter { !$0.isEmpty && seen.insert($0).inserted }
        .joined(separator: ":")

    if baseEnvironment["CAB_REAL_CODEX"]?.isEmpty != false {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ] + searchDirectories.map { URL(fileURLWithPath: $0).appendingPathComponent("codex").path }
        if let executable = candidates.first(where: executableCheck) {
            environment["CAB_REAL_CODEX"] = executable
        }
    }
    return environment
}

func isCodexDesktopProcess(executablePath: String, desktopApplicationPath: String?) -> Bool {
    if let desktopApplicationPath, executablePath.contains(desktopApplicationPath + "/Contents/") {
        return true
    }
    return executablePath.contains("/Codex.app/Contents/") || executablePath.contains("/ChatGPT.app/Contents/")
}

func codexProcessLabel(executablePath: String) -> String {
    let value = executablePath.lowercased()
    if value.contains("/.vscode/extensions/") || value.contains("/visual studio code.app/") {
        return "VS Code 的 Codex 扩展"
    }
    if value.contains("/cursor.app/") || value.contains("/.cursor/extensions/") {
        return "Cursor 的 Codex 扩展"
    }
    if value.contains("jetbrains") {
        return "JetBrains 的 Codex 插件"
    }
    return "Codex CLI 或 app-server"
}

func systemdMainPIDsByService(from output: String) -> [String: Int] {
    var result: [String: Int] = [:]
    for block in output.components(separatedBy: "\n\n") {
        var names: [String] = []
        var mainPID: Int?
        for line in block.split(separator: "\n") {
            if line.hasPrefix("Names=") {
                names = line.dropFirst("Names=".count).split(separator: " ").map(String.init)
            } else if line.hasPrefix("MainPID=") {
                mainPID = Int(line.dropFirst("MainPID=".count))
            }
        }
        guard let mainPID else { continue }
        for name in names { result[name] = mainPID }
    }
    return result
}

func remoteUserCodexProcesses(_ processes: [CodexProcessStatus], excludingParentPIDs agentMainPIDs: Set<Int>) -> [CodexProcessStatus] {
    processes.filter { !agentMainPIDs.contains($0.parentPID) }
}

func codexProcesses(_ current: [CodexProcessStatus], matchingPIDsFrom snapshot: [CodexProcessStatus]) -> [CodexProcessStatus] {
    let targetPIDs = Set(snapshot.map(\.pid))
    return current.filter { targetPIDs.contains($0.pid) }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
