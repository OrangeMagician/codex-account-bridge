import AppKit
import Darwin
import Testing
@testable import CABDesktop

@Suite("Desktop shutdown and relaunch")
@MainActor
struct DesktopLifecycleTests {
    @Test func alreadyExitedDoesNotWait() async throws {
        try await waitForDesktopProcessesToExit(runningProcessIDs: { [] }, pause: {
            Issue.record("An already stopped desktop must proceed immediately")
        })
    }

    @Test func allowsShutdownToTakeLongerThanFiveSeconds() async throws {
        var polls = 0
        try await waitForDesktopProcessesToExit(runningProcessIDs: {
            polls < 60 ? [123] : []
        }, pause: { polls += 1 })
        #expect(polls == 60)
    }

    @Test func checksAgainAtTheTimeoutBoundary() async throws {
        var polls = 0
        try await waitForDesktopProcessesToExit(pollLimit: 3, runningProcessIDs: {
            polls < 3 ? [123] : []
        }, pause: { polls += 1 })
        #expect(polls == 3)
    }

    @Test func refusesToProceedWhileAnyInstanceRemains() async {
        var polls = 0
        do {
            try await waitForDesktopProcessesToExit(pollLimit: 3, runningProcessIDs: {
                polls == 0 ? [123, 456] : [456]
            }, pause: { polls += 1 })
            Issue.record("A live desktop must block account migration and relaunch")
        } catch {
            #expect(error is BridgeError)
            #expect(polls == 3)
        }
    }

    @Test func cancellationIsNotReportedAsAQuitFailure() async {
        do {
            try await waitForDesktopProcessesToExit(runningProcessIDs: { [123] }, pause: {
                throw CancellationError()
            })
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func kernelDetectsExitDespiteAnUnchangedPIDSnapshot() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.2"]
        try process.run()
        let stalePIDs = [process.processIdentifier]
        #expect(desktopProcessIsRunning(process.processIdentifier))
        try await waitForDesktopProcessesToExit(runningProcessIDs: {
            stalePIDs.filter(desktopProcessIsRunning)
        })
        #expect(!desktopProcessIsRunning(process.processIdentifier))
        #expect(!desktopProcessIsRunning(0))
        #expect(!desktopProcessIsRunning(-1))
        #expect(desktopProcessIsRunning(getpid()))
    }

    @Test func refusesSharedProfileDirectorySymlink() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("account")
        let other = root.appendingPathComponent("other")
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: other, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: home.appendingPathComponent(".cab-desktop-profile"), withDestinationURL: other)
        let lifecycle = CodexDesktopLifecycle(bundleIdentifier: "test.cab.no-launch", applicationURLOverride: Bundle.main.bundleURL)
        do {
            _ = try await lifecycle.openAccountWindow(codexHome: home.path)
            Issue.record("A symlink must not be used as the account's Electron profile")
        } catch {
            #expect(error.localizedDescription == cabLocalized("账号窗口配置路径必须是独立目录。"))
        }
    }

    @Test func opensAndReusesTwoOfficialAccountWindowsWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CAB_VERIFY_ACCOUNT_WINDOWS"] == "1" else { return }
        let lifecycle = CodexDesktopLifecycle()
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("cab-window-test-" + UUID().uuidString)
        let first = root.appendingPathComponent("A"), second = root.appendingPathComponent("B")
        let testHomes = Set([first, second].map { canonicalDesktopHome($0.path) })
        let originals = Set(lifecycle.runningApplications.map(\.processIdentifier))
        for home in [first, second] { try manager.createDirectory(at: home, withIntermediateDirectories: true) }
        func testApps() -> [NSRunningApplication] {
            lifecycle.runningApplications.filter { app in
                !originals.contains(app.processIdentifier) && desktopProcessHome(app.processIdentifier).map(testHomes.contains) == true
            }
        }
        func verify() async throws {
            let a = try await lifecycle.openAccountWindow(codexHome: first.path)
            let b = try await lifecycle.openAccountWindow(codexHome: second.path)
            #expect(a.processIdentifier != b.processIdentifier)
            for app in [a, b] {
                for _ in 0..<200 {
                    if frontDesktopWindowPID(in: [app.processIdentifier]) != nil { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                #expect(frontDesktopWindowPID(in: [app.processIdentifier]) != nil)
            }
            for (home, app) in [(first, a), (second, b)] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                process.arguments = ["-P", String(app.processIdentifier), "-x", "codex"]
                let children = try await CommandExecution(process: process).run(timeout: 5)
                let pids = children.output.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
                #expect(!pids.isEmpty)
                #expect(pids.allSatisfy { desktopProcessHome($0) == canonicalDesktopHome(home.path) })
            }
            _ = a.hide()
            for (home, expected) in [(first, a), (second, b), (first, a)] {
                let reopened = try await CodexDesktopLifecycle().openAccountWindow(codexHome: home.path)
                #expect(reopened.processIdentifier == expected.processIdentifier)
                for _ in 0..<50 {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == expected.processIdentifier { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == expected.processIdentifier)
                #expect(currentLocalDesktopHome().frontHome == canonicalDesktopHome(home.path))
            }
            #expect(testApps().count == 2)
            #expect(originals.isSubset(of: Set(lifecycle.runningApplications.map(\.processIdentifier))))
        }
        let outcome: Result<Void, Error>
        do { try await verify(); outcome = .success(()) } catch { outcome = .failure(error) }
        let apps = testApps()
        for app in apps { _ = app.terminate() }
        do {
            try await waitForDesktopProcessesToExit { testApps().map(\.processIdentifier) }
        } catch {
            for app in testApps() { _ = app.forceTerminate() }
            try await waitForDesktopProcessesToExit { testApps().map(\.processIdentifier) }
        }
        try manager.removeItem(at: root)
        try outcome.get()
    }

    @Test func verifiesNativeDelayedQuitAndRelaunchWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CAB_VERIFY_DESKTOP_LIFECYCLE"] == "1" else { return }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("cab-lifecycle-\(UUID().uuidString)")
        let app = root.appendingPathComponent("CABLifecycleFixture.app")
        let contents = app.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/Fixture")
        let bundleID = "test.cab.lifecycle.\(UUID().uuidString.lowercased())"
        try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer {
            // Only this disposable test app can be force-stopped by the test.
            for application in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                _ = application.forceTerminate()
            }
            try? manager.removeItem(at: root)
        }
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "Fixture",
                                    "CFBundlePackageType": "APPL", "LSUIElement": true]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let source = root.appendingPathComponent("Fixture.swift")
        try """
        import AppKit
        final class Delegate: NSObject, NSApplicationDelegate {
            func applicationDidFinishLaunching(_ notification: Notification) {
                let environment = ProcessInfo.processInfo.environment
                let home = URL(fileURLWithPath: environment["CODEX_HOME"]!)
                let result = environment["CODEX_HOME"]!
                try! result.write(to: home.appendingPathComponent("launched"), atomically: true, encoding: .utf8)
            }
            func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
                let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"]!)
                try! "reopened".write(to: home.appendingPathComponent("reopened"), atomically: true, encoding: .utf8)
                return true
            }
            func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    sender.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            }
        }
        let app = NSApplication.shared
        let delegate = Delegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        """.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        compiler.arguments = [source.path, "-o", executable.path]
        try compiler.run()
        compiler.waitUntilExit()
        #expect(compiler.terminationStatus == 0)

        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        for home in [first, second] { try manager.createDirectory(at: home, withIntermediateDirectories: true) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = ["CODEX_HOME": first.path]
        configuration.activates = false
        let initial = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        let lifecycle = CodexDesktopLifecycle(bundleIdentifier: bundleID, applicationURLOverride: app)
        for _ in 0..<100 {
            if manager.fileExists(atPath: first.appendingPathComponent("launched").path) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(manager.fileExists(atPath: first.appendingPathComponent("launched").path))
        #expect(lifecycle.isRunning)
        let reused = try await lifecycle.openAccountWindow(codexHome: first.path)
        #expect(reused.processIdentifier == initial.processIdentifier)
        for _ in 0..<50 {
            if manager.fileExists(atPath: first.appendingPathComponent("reopened").path) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(manager.fileExists(atPath: first.appendingPathComponent("reopened").path))
        do {
            try await lifecycle.start(codexHome: second.path)
            Issue.record("Must not reuse a running app with the previous account environment")
        } catch { #expect(error is BridgeError) }

        let clock = ContinuousClock()
        let start = clock.now
        try await lifecycle.stop()
        #expect(start.duration(to: clock.now) >= .seconds(5))
        #expect(!desktopProcessIsRunning(initial.processIdentifier))
        #expect(!lifecycle.isRunning)
        try await lifecycle.start(codexHome: second.path)
        let marker = second.appendingPathComponent("launched")
        for _ in 0..<100 {
            if manager.fileExists(atPath: marker.path) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == canonicalDesktopHome(second.path))
        #expect(lifecycle.isRunning)
        print("Verified native desktop quit after >5 seconds and relaunch with the requested CODEX_HOME")
    }
}
