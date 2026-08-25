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
            process.arguments = ["--", host, "cab"] + arguments
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
