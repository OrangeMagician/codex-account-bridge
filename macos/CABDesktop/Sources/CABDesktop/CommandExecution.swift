import Foundation

/// Owns only the subprocess launched for this request. Cancelling a query never
/// signals an existing Codex task or a different user's SSH connection.
final class CommandExecution: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let output = CommandOutputBuffer()
    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var completed = false
    private var cancelled = false
    private var timer: DispatchWorkItem?

    init(process: Process) { self.process = process }

    func run(timeout: TimeInterval, onOutput: (@Sendable (String) -> Void)? = nil) async throws -> CommandResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let stdout = Pipe(), stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                let readers = DispatchGroup()
                for (pipe, isOutput) in [(stdout, true), (stderr, false)] {
                    readers.enter()
                    DispatchQueue.global(qos: .utility).async { [output] in
                        defer { readers.leave() }
                        while let data = try? pipe.fileHandleForReading.read(upToCount: 8192), !data.isEmpty {
                            if let chunk = output.append(data, toStandardOutput: isOutput) { onOutput?(chunk) }
                        }
                    }
                }
                process.terminationHandler = { [weak self] finished in
                    readers.notify(queue: .global(qos: .utility)) {
                        guard let self else { return }
                        self.finish(.success(self.output.result(exitCode: finished.terminationStatus)))
                    }
                }
                do {
                    try process.run()
                    // Only the child should keep the write ends open.
                    try? stdout.fileHandleForWriting.close()
                    try? stderr.fileHandleForWriting.close()
                    let work = DispatchWorkItem { [weak self] in
                        self?.stop(error: BridgeError.commandFailed(cabLocalized("操作超时。请检查连接后重试；远程操作的结果请刷新确认。")))
                    }
                    timer = work
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: work)
                    lock.unlock()
                } catch {
                    try? stdout.fileHandleForWriting.close()
                    try? stderr.fileHandleForWriting.close()
                    lock.unlock()
                    finish(.failure(error))
                }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() { stop(error: CancellationError()) }

    private func stop(error: Error) {
        lock.lock()
        cancelled = true
        if process.isRunning { process.terminate() }
        lock.unlock()
        finish(.failure(error))
    }

    private func finish(_ result: Result<CommandResult, Error>) {
        lock.lock()
        guard !completed, let continuation else { lock.unlock(); return }
        completed = true
        self.continuation = nil
        timer?.cancel()
        timer = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

func commandTimeout(_ arguments: [String]) -> TimeInterval {
    switch arguments.first {
    case "login": return 600
    case "update": return arguments.contains("--check") ? 60 : 600
    case "tokens": return 110
    case "doctor", "backups", "sessions": return 180
    case "usage": return arguments.dropFirst().first == "reset" ? 180 : 120
    default: return 60
    }
}

func remoteCommandFailure(_ result: CommandResult) -> String {
    let detail = result.errorOutput.isEmpty ? result.output : result.errorOutput
    let value = detail.lowercased()
    if value.contains("usage reset result is unconfirmed") { return detail }
    if value.contains("permission denied") { return cabLocalized("SSH 认证失败。请在终端确认此主机的 SSH 登录配置。") }
    if value.contains("host key verification failed") { return cabLocalized("SSH 主机身份尚未确认或已改变。请在终端核对主机密钥。") }
    if value.contains("timed out") || value.contains("no route to host") || value.contains("could not resolve hostname") || value.contains("connection refused") {
        return cabLocalized("无法连接服务器。请检查主机地址、网络与 SSH 服务。")
    }
    if value.contains("unknown command") { return cabLocalized("服务器 CAB 不支持此功能，请先更新服务器 CAB。") }
    if value.contains("cab: command not found") || value.contains("cab: not found") { return cabLocalized("服务器找不到 CAB。请安装到 SSH 登录 PATH 后重试。") }
    return detail
}

func isReadOnlyCommand(_ arguments: [String]) -> Bool {
    switch arguments.first {
    case "status", "tokens", "capabilities": return true
    case "doctor": return !arguments.contains("--repair")
    case "usage": return !arguments.contains("reset") && !arguments.contains("probe")
    case "update": return arguments.contains("--check")
    case "processes", "agent", "backups": return arguments.dropFirst().first == "list" || arguments.dropFirst().first == "preview"
    case "sessions": return arguments.dropFirst().first == "legacy-status"
    default: return false
    }
}
