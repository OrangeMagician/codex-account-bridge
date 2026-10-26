import AppKit
import Darwin

// NSRunningApplication's time-varying properties are cached until the main run
// loop advances. Confirm the PID with the kernel before treating an old app
// object as evidence that the desktop is still running.
func desktopProcessIsRunning(_ pid: pid_t) -> Bool {
    guard pid > 0 else { return false }
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size {
        return info.pbi_status != SZOMB
    }
    // A permission or inspection error is not proof of exit. Signal 0 only
    // checks existence; it never asks a process to stop.
    return kill(pid, 0) == 0 || errno != ESRCH
}

@MainActor
func waitForDesktopProcessesToExit(
    pollLimit: Int = 300,
    runningProcessIDs: () -> [pid_t],
    pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 100_000_000) }
) async throws {
    for attempt in 0...pollLimit {
        try Task.checkCancellation()
        if runningProcessIDs().isEmpty { return }
        if attempt < pollLimit { try await pause() }
    }
    throw BridgeError.commandFailed("Codex 桌面客户端仍在运行，请先保存任务并手动退出后重试。")
}

@MainActor
struct CodexDesktopLifecycle {
    var bundleIdentifier = "com.openai.codex"
    var applicationURLOverride: URL?

    private func applicationURL() throws -> URL {
        guard let url = applicationURLOverride ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
              Bundle(url: url)?.executableURL != nil else {
            throw BridgeError.commandFailed("未找到已安装的 Codex 桌面客户端。")
        }
        return url
    }

    private var runningApplications: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { desktopProcessIsRunning($0.processIdentifier) }
    }

    var isRunning: Bool { !runningApplications.isEmpty }

    func stop() async throws {
        _ = try applicationURL()
        let applications = runningApplications
        let originalPIDs = applications.map(\.processIdentifier)
        for application in applications { _ = application.terminate() }
        try await waitForDesktopProcessesToExit {
            // Retain the original PIDs even if Launch Services drops them early,
            // and include any newly opened instance before permitting migration.
            let pids = Set(originalPIDs + runningApplications.map(\.processIdentifier))
            return pids.filter(desktopProcessIsRunning)
        }
    }

    func start(codexHome: String) async throws {
        let url = try applicationURL()
        guard !isRunning else {
            throw BridgeError.commandFailed("Codex 桌面客户端仍在运行，请先保存任务并手动退出后重试。")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome
        environment.removeValue(forKey: "CODEX_THREAD_ID")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = environment
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
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
}
