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

// A delivered event can be ignored during shutdown. Only a visible window
// confirms success. Returning false asks the caller to resolve the PID again.
@MainActor
func revealDesktopWindow(
    isRunning: () -> Bool,
    isVisible: () -> Bool,
    activate: () -> Void,
    reopen: () throws -> Void,
    openLaunchURL: () throws -> Void,
    pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 100_000_000) }
) async throws -> Bool {
    func waitForWindow(polls: Int) async throws -> Bool {
        for _ in 0..<polls {
            if !isRunning() { return false }
            if isVisible() { return true }
            try await pause()
        }
        return isRunning() && isVisible()
    }

    guard isRunning() else { return false }
    activate()
    if try await waitForWindow(polls: 2) { return true }
    guard isRunning() else { return false }
    // The Dock reopen event is best-effort. The Codex launch link also
    // handles an instance with no primary window or a minimized window.
    try? reopen()
    if try await waitForWindow(polls: 12) { return true }
    guard isRunning() else { return false }
    do { try openLaunchURL() } catch {
        if !isRunning() { return false }
        throw error
    }
    if try await waitForWindow(polls: 60) { return true }
    guard isRunning() else { return false }
    throw BridgeError.commandFailed(cabLocalized("未检测到所选账号的窗口，请重试。"))
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

    var runningApplications: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { desktopProcessIsRunning($0.processIdentifier) }
    }

    var isRunning: Bool { !runningApplications.isEmpty }

    func stop() async throws {
        _ = try applicationURL()
        let applications = runningApplications
        guard applications.count <= 1 else {
            throw BridgeError.commandFailed(cabLocalized("请先退出其他账号窗口，再重启切换。"))
        }
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
        guard !isRunning else {
            throw BridgeError.commandFailed("Codex 桌面客户端仍在运行，请先保存任务并手动退出后重试。")
        }
        _ = try await launch(codexHome: codexHome)
    }

    func stopAccount(codexHome: String) async throws {
        _ = try applicationURL()
        let home = canonicalDesktopHome(codexHome)
        let applications = runningApplications.filter { desktopProcessHome($0.processIdentifier) == home }
        let originalPIDs = applications.map(\.processIdentifier)
        for app in applications {
            guard app.terminate() else {
                throw BridgeError.commandFailed(cabLocalized("账号窗口未能退出，请保存任务后重试。"))
            }
        }
        try await waitForDesktopProcessesToExit {
            let selectedPIDs = runningApplications.filter {
                desktopProcessHome($0.processIdentifier) == home
            }.map(\.processIdentifier)
            return Set(originalPIDs + selectedPIDs).filter(desktopProcessIsRunning)
        }
    }

    @discardableResult
    func openAccountWindow(codexHome: String) async throws -> NSRunningApplication {
        let home = canonicalDesktopHome(codexHome)
        // Closing the last window can leave an app in Launch Services while it
        // exits. Resolve the account again if that PID disappears mid-request.
        for _ in 0..<2 {
            let apps = runningApplications
            if let app = apps.first(where: { desktopProcessHome($0.processIdentifier) == home }) {
                let pid = app.processIdentifier
                let revealed = try await revealDesktopWindow(
                    isRunning: { desktopProcessIsRunning(pid) },
                    isVisible: { frontDesktopWindowPID(in: [pid]) != nil },
                    activate: {
                        _ = app.unhide()
                        _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                    },
                    reopen: { try sendWindowEvent(to: pid, openLaunchURL: false) },
                    openLaunchURL: { try sendWindowEvent(to: pid, openLaunchURL: true) }
                )
                if revealed { return app }
                continue
            }
            guard !apps.contains(where: { desktopProcessIsRunning($0.processIdentifier) && desktopProcessHome($0.processIdentifier) == nil }) else {
                throw BridgeError.commandFailed(cabLocalized("暂时无法识别已运行窗口的账号，请重试。"))
            }
            let app = try await launch(codexHome: home)
            let pid = app.processIdentifier
            for _ in 0..<150 {
                if frontDesktopWindowPID(in: [pid]) != nil { return app }
                if !desktopProcessIsRunning(pid) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw BridgeError.commandFailed(cabLocalized("未检测到所选账号的窗口，请重试。"))
        }
        throw BridgeError.commandFailed(cabLocalized("未检测到所选账号的窗口，请重试。"))
    }

    private func sendWindowEvent(to pid: pid_t, openLaunchURL: Bool) throws {
        let event = NSAppleEventDescriptor(
            eventClass: openLaunchURL ? AEEventClass(kInternetEventClass) : AEEventClass(kCoreEventClass),
            eventID: openLaunchURL ? AEEventID(kAEGetURL) : AEEventID(kAEReopenApplication),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if openLaunchURL {
            event.setParam(NSAppleEventDescriptor(string: "codex://launch"), forKeyword: AEKeyword(keyDirectObject))
        }
        _ = try event.sendEvent(options: [.noReply, .neverInteract], timeout: 2)
    }

    private func launch(codexHome: String) async throws -> NSRunningApplication {
        let url = try applicationURL()
        let home = canonicalDesktopHome(codexHome)
        let profile = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".cab-desktop-profile", isDirectory: true)
        let manager = FileManager.default
        if !manager.fileExists(atPath: profile.path) {
            try manager.createDirectory(at: profile, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        guard try manager.attributesOfItem(atPath: profile.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw BridgeError.commandFailed(cabLocalized("账号窗口配置路径必须是独立目录。"))
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home
        environment["CODEX_ELECTRON_USER_DATA_PATH"] = profile.path
        environment["CODEX_APP_SERVER_FORCE_CLI"] = "1"
        environment.removeValue(forKey: "CODEX_THREAD_ID")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = environment
        configuration.arguments = ["--user-data-dir=" + profile.path]
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        guard app.bundleIdentifier == bundleIdentifier, desktopProcessHome(app.processIdentifier) == home else {
            throw BridgeError.commandFailed(cabLocalized("无法确认新窗口使用了所选账号。"))
        }
        return app
    }
}
