import AppKit
import CABContinuity
import Foundation

final class CommandOutputBuffer: @unchecked Sendable {
    private static let maximumCharactersPerStream = 2_000_000
    private static let truncationMarker = "\n… CAB 已截断过长的命令输出 …\n"
    private let lock = NSLock()
    private var standardPending = Data()
    private var errorPending = Data()
    private var standardText = ""
    private var errorText = ""
    private var standardTruncated = false
    private var errorTruncated = false

    func append(_ data: Data, toStandardOutput: Bool) -> String? {
        guard !data.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let chunk: String
        if toStandardOutput {
            standardPending.append(data)
            chunk = decodeCompleteUTF8(&standardPending)
            appendLimited(chunk, text: &standardText, truncated: &standardTruncated)
        } else {
            errorPending.append(data)
            chunk = decodeCompleteUTF8(&errorPending)
            appendLimited(chunk, text: &errorText, truncated: &errorTruncated)
        }
        return chunk.isEmpty ? nil : chunk
    }

    private func decodeCompleteUTF8(_ pending: inout Data) -> String {
        for trailing in 0...min(3, pending.count) {
            if let text = String(data: pending.dropLast(trailing), encoding: .utf8) {
                pending = Data(pending.suffix(trailing))
                return text
            }
        }
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        return text
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
        appendLimited(String(decoding: standardPending, as: UTF8.self), text: &standardText, truncated: &standardTruncated)
        appendLimited(String(decoding: errorPending, as: UTF8.self), text: &errorText, truncated: &errorTruncated)
        standardPending.removeAll(); errorPending.removeAll()
        return CommandResult(output: standardText, errorOutput: errorText, exitCode: exitCode)
    }
}

final class CABService {
    private let fileManager = FileManager.default
    private let executionLock = NSLock()
    private var readExecutions: [UUID: CommandExecution] = [:]

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
        try await loadUsage(target: target, remoteHost: remoteHost, accountNames: accountNames, force: false)
    }

    func loadUsage(target: BridgeTarget, remoteHost: String, accountNames: [String]?, force: Bool) async throws -> UsageReport {
        let names: [String]
        if let accountNames { names = accountNames }
        else { names = try await loadStatus(target: target, remoteHost: remoteHost).accounts.filter(\.isLoggedIn).map(\.name) }
        return await withTaskGroup(of: UsageReport.self) { group in
            for name in Set(names) {
                group.addTask {
                    do {
                        return try await UsageRepository.shared.read(
                            key: .init(target: target == .local ? "local" : "ssh:" + remoteHost, account: name),
                            maximumAge: force ? 0 : 30
                        ) {
                            try Task.checkCancellation()
                            return try await self.loadUsage(arguments: ["usage", "--account", name, "--json"], target: target, remoteHost: remoteHost)
                        }
                    } catch {
                        return UsageReport(fetchedAt: Date(), accounts: [AccountUsageReport(name: name, usage: nil, error: error.localizedDescription)])
                    }
                }
            }
            var reports: [AccountUsageReport] = []
            var fetchedAt = Date.distantPast
            for await result in group {
                fetchedAt = max(fetchedAt, result.fetchedAt)
                reports += result.accounts.map { preservingUsage($0, previous: nil, fetchedAt: result.fetchedAt) }
            }
            return UsageReport(fetchedAt: fetchedAt, accounts: reports.sorted { $0.name < $1.name })
        }
    }

    func loadTokenUsage(target: BridgeTarget, remoteHost: String) async throws -> TokenUsageReport {
        let result = try await execute(["tokens", "--json"], target: target, remoteHost: remoteHost)
        guard result.exitCode == 0 else {
            throw BridgeError.commandFailed(preferredMessage(result))
        }
        guard let data = result.output.data(using: .utf8) else {
            throw BridgeError.invalidTokens("cab 返回了无法读取的 Token 统计。")
        }
        do {
            return try cabDateDecoder().decode(TokenUsageReport.self, from: data)
        } catch {
            throw BridgeError.invalidTokens("无法解析 Token 统计：\(error.localizedDescription)")
        }
    }

    func updateCodex(
        target: BridgeTarget,
        remoteHost: String,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandResult {
        let result = try await execute(["update"], target: target, remoteHost: remoteHost, onOutput: onOutput)
        guard result.exitCode == 0 else {
            throw BridgeError.commandFailed(preferredMessage(result))
        }
        return result
    }

    func loadCodexUpdateStatus(target: BridgeTarget, remoteHost: String) async throws -> CodexUpdateStatus {
        let result = try await execute(["update", "--check", "--json"], target: target, remoteHost: remoteHost)
        guard result.exitCode == 0 else {
            throw BridgeError.commandFailed(preferredMessage(result))
        }
        guard let data = result.output.data(using: .utf8) else {
            throw BridgeError.invalidUpdate("cab 返回了无法读取的 Codex 版本信息。")
        }
        do {
            return try JSONDecoder().decode(CodexUpdateStatus.self, from: data)
        } catch {
            throw BridgeError.invalidUpdate("无法解析 Codex 版本信息：\(error.localizedDescription)")
        }
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
            return try cabDateDecoder().decode(UsageReport.self, from: data)
        } catch {
            throw BridgeError.invalidUsage("无法解析 cab 额度信息：\(error.localizedDescription)")
        }
    }

    func cabDateDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无法解析 ISO 8601 时间：\(value)"
            )
        }
        return decoder
    }

    func probeUsage(target: BridgeTarget, remoteHost: String, accountName: String) async throws {
        let result = try await execute(
            ["usage", "probe", "--account", accountName, "--model", "gpt-5.6-luna", "--json"],
            target: target,
            remoteHost: remoteHost
        )
        guard result.exitCode == 0 else {
            throw BridgeError.commandFailed("官方 Codex 最低消耗请求未完成；本次不会自动重试。")
        }
    }

    func resetUsage(
        target: BridgeTarget,
        remoteHost: String,
        accountName: String,
        creditID: String?,
        idempotencyKey: UUID
    ) async throws -> UsageResetResult {
        var arguments = [
            "usage", "reset",
            "--account", accountName,
            "--idempotency-key", idempotencyKey.uuidString.lowercased(),
            "--confirm-reset-usage",
            "--json",
        ]
        if let creditID, !creditID.isEmpty {
            arguments.append(contentsOf: ["--credit-id", creditID])
        }
        let result = try await execute(
            arguments,
            target: target,
            remoteHost: remoteHost
        )
        guard result.exitCode == 0 else {
            throw BridgeError.commandFailed(preferredMessage(result))
        }
        guard let data = result.output.data(using: .utf8) else {
            throw BridgeError.invalidUsage("cab 返回了无法读取的额度重置结果。")
        }
        do {
            return try JSONDecoder().decode(UsageResetResult.self, from: data)
        } catch {
            throw BridgeError.invalidUsage("无法解析额度重置结果：\(error.localizedDescription)")
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

    func stopCodexProcesses(_ pids: [Int], target: BridgeTarget, remoteHost: String, forceAfterTimeout: Bool = false) async throws {
        guard !pids.isEmpty else { return }
        var arguments = ["processes", "stop", "--pids", pids.map(String.init).joined(separator: ","), "--confirm-stop-codex"]
        if forceAfterTimeout { arguments.append("--force-after-timeout") }
        let result = try await execute(arguments, target: target, remoteHost: remoteHost)
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
            var sshArguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=12", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2"]
            if arguments.contains("--browser-auth") {
                sshArguments += [
                    "-o", "ExitOnForwardFailure=yes",
                    "-L", "127.0.0.1:1455:127.0.0.1:1455",
                    "-L", "127.0.0.1:1457:127.0.0.1:1457",
                ]
            }
            process.arguments = sshArguments + ["--", host, (["cab"] + arguments).map(cabShellQuote).joined(separator: " ")]
        }

        let execution = CommandExecution(process: process)
        let id = UUID()
        let readOnly = isReadOnlyCommand(arguments)
        if readOnly { register(execution, id: id) }
        defer { unregister(id) }
        let result = try await execution.run(timeout: commandTimeout(arguments), onOutput: onOutput)
        if target == .remote, result.exitCode != 0 {
            return CommandResult(output: result.output, errorOutput: remoteCommandFailure(result), exitCode: result.exitCode)
        }
        return result
    }

    private func register(_ execution: CommandExecution, id: UUID) {
        executionLock.lock(); defer { executionLock.unlock() }
        readExecutions[id] = execution
    }
    private func unregister(_ id: UUID) {
        executionLock.lock(); defer { executionLock.unlock() }
        readExecutions[id] = nil
    }
    func cancelReadOperations() {
        executionLock.lock()
        let operations = Array(readExecutions.values)
        executionLock.unlock()
        operations.forEach { $0.cancel() }
    }

    private func executeRemoteProgram(_ executable: String, arguments: [String], remoteHost: String) async throws -> CommandResult {
        let host = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw BridgeError.commandFailed("请先填写 SSH 主机。") }
        return try await runLocalProcess(
            "/usr/bin/ssh",
            arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=12", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "--", host, ([executable] + arguments).map(cabShellQuote).joined(separator: " ")]
        )
    }

    func launchCodexInTerminal(target: BridgeTarget, remoteHost: String, accountName: String? = nil, directory: String? = nil) throws {
        let environment = localCABEnvironment(
            baseEnvironment: ProcessInfo.processInfo.environment,
            homeDirectory: fileManager.homeDirectoryForCurrentUser,
            executableCheck: fileManager.isExecutableFile(atPath:)
        )
        let command = try codexRunTerminalCommand(
            target: target,
            remoteHost: remoteHost,
            cabExecutablePath: cabExecutable()?.path,
            realCodexPath: environment["CAB_REAL_CODEX"],
            accountName: accountName,
            directory: directory
        )
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

    /// Merges the official desktop app's portable workspace state into the target
    /// CODEX_HOME. Authentication, config, plugin authorization, device identity,
    /// and security preferences remain account-local.
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

    func synchronizeCodexContinuityState(
        sourceHome: String,
        targetHome: String,
        knownHomes: [String]
    ) throws -> CodexContinuitySyncResult {
        try CodexContinuityState.synchronize(
            sourceHome: sourceHome,
            targetHome: targetHome,
            knownHomes: knownHomes
        )
    }

    func restoreCodexContinuityState(_ result: CodexContinuitySyncResult) throws {
        try CodexContinuityState.restore(result)
    }

    func synchronizeCodexThreadCatalogState(
        sourceHome: String,
        targetHome: String,
        knownHomes: [String]
    ) throws -> CodexThreadCatalogSyncResult? {
        try CodexThreadCatalogState.synchronize(
            sourceHome: sourceHome,
            targetHome: targetHome,
            knownHomes: knownHomes
        )
    }

    func restoreCodexThreadCatalogState(_ result: CodexThreadCatalogSyncResult) throws {
        try CodexThreadCatalogState.restore(result)
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
        let arguments = [
            "processes", "stop",
            "--pids", pids.map(String.init).joined(separator: ","),
            "--confirm-stop-codex",
            "--force-after-timeout",
        ]
        let result = try await execute(
            arguments,
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        return try await CommandExecution(process: process).run(timeout: 60)
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
        let candidates = cabExecutableCandidates(
            configured: ProcessInfo.processInfo.environment["CAB_EXECUTABLE"],
            bundleResourceURL: Bundle.main.resourceURL,
            homeDirectory: fileManager.homeDirectoryForCurrentUser
        )
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

    private func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

func cabExecutableCandidates(
    configured: String?,
    bundleResourceURL: URL?,
    homeDirectory: URL
) -> [String] {
    var candidates: [String] = []
    if let configured, !configured.isEmpty { candidates.append(configured) }
    if let bundleResourceURL { candidates.append(bundleResourceURL.appendingPathComponent("cab").path) }
    candidates += [
        "/opt/homebrew/bin/cab",
        homeDirectory.appendingPathComponent(".local/bin/cab").path,
        "/usr/local/bin/cab",
    ]
    return candidates
}

func codexRunTerminalCommand(
    target: BridgeTarget,
    remoteHost: String,
    cabExecutablePath: String?,
    realCodexPath: String?,
    accountName: String?,
    directory: String? = nil
) throws -> String {
    let directoryArgument = directory.map { " --directory \(cabShellQuote($0))" } ?? ""
    let accountArgument = accountName.map { " --account \(cabShellQuote($0))" } ?? ""
    if target == .local {
        guard let cabExecutablePath else { throw BridgeError.executableMissing }
        let codexPrefix = realCodexPath.map { "CAB_REAL_CODEX=\(cabShellQuote($0)) " } ?? ""
        return "\(codexPrefix)\(cabShellQuote(cabExecutablePath)) run\(accountArgument)\(directoryArgument)"
    }

    let host = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !host.isEmpty else { throw BridgeError.commandFailed("请先填写 SSH 主机。") }
    if let directory {
        guard let accountName else { throw BridgeError.invalidAccountName }
        let remote = ["cab", "run", "--account", accountName, "--directory", directory].map(cabShellQuote).joined(separator: " ")
        return "ssh -tt -- \(cabShellQuote(host)) \(cabShellQuote(remote))"
    }
    return "ssh -tt -- \(cabShellQuote(host)) cab run\(accountArgument)"
}

private func cabShellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
    var agentProcessPIDs = agentMainPIDs
    var discoveredDescendant = true
    while discoveredDescendant {
        discoveredDescendant = false
        for process in processes where agentProcessPIDs.contains(process.parentPID) {
            if agentProcessPIDs.insert(process.pid).inserted {
                discoveredDescendant = true
            }
        }
    }
    return processes.filter { !agentProcessPIDs.contains($0.pid) }
}

// Account selection only affects future connections. This operation deliberately
// has no process-stop capability; active tasks retain their existing account.
func switchRemoteAccountSafely(
    _ name: String,
    execute: ([String]) async throws -> CommandResult
) async throws -> CommandResult {
    let result = try await execute(["remote", "use", name])
    guard result.exitCode == 0 else {
        throw BridgeError.commandFailed(result.errorOutput.isEmpty ? result.output : result.errorOutput)
    }
    return result
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
