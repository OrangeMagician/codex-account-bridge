import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CABDesktop

private func sampleUsage(used: Double = 95, reset: Int64 = Int64(Date().timeIntervalSince1970) + 3600) -> CodexUsageSnapshot {
    CodexUsageSnapshot(planType: "plus", rateLimits: UsageRateLimitSnapshot(limitID: "codex", limitName: nil,
        primary: UsageWindow(usedPercent: used, windowDurationMins: 300, resetsAt: reset), secondary: nil,
        credits: nil, individualLimit: nil, spendControlReached: nil, planType: nil, rateLimitReachedType: nil), rateLimitsByLimitID: nil, resetCredits: nil)
}

private actor LoadCounter {
    var calls = 0, active = 0, peak = 0
    func load() async throws -> UsageReport {
        calls += 1; active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(nanoseconds: 20_000_000)
        return UsageReport(fetchedAt: Date(), accounts: [AccountUsageReport(name: "work", usage: sampleUsage(), error: nil)])
    }
}

@Suite("Maintenance and refresh reliability")
struct ManagementTests {
    @Test func usageRequestsCoalesceAndBoundConcurrency() async throws {
        let repository = UsageRepository(), counter = LoadCounter()
        try await withThrowingTaskGroup(of: UsageReport.self) { group in
            for _ in 0..<12 { group.addTask { try await repository.read(key: .init(target: "local", account: "work"), maximumAge: 30) { try await counter.load() } } }
            for try await _ in group { }
        }
        #expect(await counter.calls == 1)
        try await withThrowingTaskGroup(of: UsageReport.self) { group in
            for index in 0..<10 { group.addTask { try await repository.read(key: .init(target: "remote", account: String(index)), maximumAge: 30) { try await counter.load() } } }
            for try await _ in group { }
        }
        #expect(await counter.peak <= 4)
        _ = try await repository.read(key: .init(target: "local", account: "work"), maximumAge: 0) { try await counter.load() }
        #expect(await counter.calls == 12)
    }

    @Test func unicodeOutputSurvivesSplitUTF8Chunks() {
        let buffer = CommandOutputBuffer(), bytes = Array("你好，Codex 👋".utf8)
        for byte in bytes { _ = buffer.append(Data([byte]), toStandardOutput: true) }
        #expect(buffer.result(exitCode: 0).output == "你好，Codex 👋")
    }

    @Test func failedAccountKeepsItsOwnSuccessfulTimestampAndValues() {
        let date = Date(timeIntervalSince1970: 100)
        let old = AccountUsageReport(name: "work", usage: sampleUsage(), error: nil, fetchedAt: date)
        let failed = AccountUsageReport(name: "work", usage: nil, error: "offline")
        let result = preservingUsage(failed, previous: old, fetchedAt: Date())
        #expect(result.usage == old.usage && result.fetchedAt == date && result.error == "offline")
        #expect(preservingUsage(failed, previous: nil, fetchedAt: Date()).usage == nil)
    }

    @Test func processDrainsLargeOutputAndStopsOnTimeoutOrCancellation() async throws {
        func process(_ script: String) -> Process {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", "-c", script]; return process
        }
        let result = try await CommandExecution(process: process("import sys;sys.stdout.write('x'*200000);sys.stderr.write('y'*200000)")).run(timeout: 10)
        #expect(result.exitCode == 0 && result.output.count == 200000 && result.errorOutput.count == 200000)
        let start = Date()
        await #expect(throws: (any Error).self) {
            try await CommandExecution(process: process("import time;time.sleep(20)")).run(timeout: 0.1)
        }
        #expect(Date().timeIntervalSince(start) < 3)
        let command = CommandExecution(process: process("import time;time.sleep(20)"))
        let task = Task { try await command.run(timeout: 10) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func lowQuotaDeduplicatesCyclesAndDefersDuringQuietHours() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let report = AccountUsageReport(name: "work", usage: sampleUsage(reset: 1_800_007_200), error: nil)
        let source = UsageNotificationSource(key: "local", title: "Mac", reports: [report])
        var settings = LowQuotaSettings()
        #expect(lowQuotaAlerts(sources: [source], settings: settings, sent: [:], now: now).isEmpty)
        settings.enabled = true
        let alerts = lowQuotaAlerts(sources: [source], settings: settings, sent: [:], now: now)
        #expect(alerts.count == 1)
        #expect(lowQuotaAlerts(sources: [source], settings: settings, sent: [alerts[0].key: alerts[0].reset], now: now).isEmpty)
        settings.quietEnabled = true; settings.quietStartHour = 22; settings.quietEndHour = 8
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.startOfDay(for: now)
        #expect(lowQuotaAlerts(sources: [source], settings: settings, sent: [:], now: midnight, calendar: calendar).isEmpty)
        #expect(!settings.isQuiet(at: calendar.date(byAdding: .hour, value: 12, to: midnight)!, calendar: calendar))
        let stale = UsageNotificationSource(key: "local", title: "Mac", reports: [AccountUsageReport(name: "work", usage: report.usage, error: "offline")])
        settings.quietEnabled = false
        #expect(lowQuotaAlerts(sources: [stale], settings: settings, sent: [:], now: now).isEmpty)
    }

    @MainActor @Test func launchProfilesAndSwitchRecordsPersistWithoutRawOutput() throws {
        let suite = "CAB.Management.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ManagementToolsStore(defaults: defaults)
        let profile = ProjectLaunchProfile(name: "App", directory: "/tmp/a project's $(name)", account: "work", remoteHost: "server")
        try model.saveProfile(profile)
        let id = model.beginRecord(host: "server", source: "one", destination: "work")
        model.record(id, stage: "预检通过", backups: ["/backup"])
        let restored = ManagementToolsStore(defaults: defaults)
        #expect(restored.profiles == [profile])
        #expect(restored.records[0].outcome == "结果待确认")
        let command = try codexRunTerminalCommand(target: .remote, remoteHost: "server", cabExecutablePath: nil, realCodexPath: nil, accountName: profile.account, directory: profile.directory)
        #expect(command.contains("--directory") && command.contains("--account"))
        #expect(throws: (any Error).self) { try ProjectLaunchProfile(name: "bad", directory: "relative", account: "", remoteHost: "").validate() }
    }

    @MainActor @Test func exportManagementViews() throws {
        guard let path = ProcessInfo.processInfo.environment["CAB_MANAGEMENT_RENDER_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let suite = "CAB.Render.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ManagementToolsStore(defaults: defaults)
        let account = AccountStatus(name: "Work", home: "/accounts/work", login: "present", default: true, remote: false)
        let store = CABStore()
        store.status.accounts = [account]
        model.diagnostics = DiagnosticReport(cabVersion: "0.7.0", codexPath: "/Applications/Codex.app/Contents/Resources/codex", codexVersion: "Codex CLI", entryPoint: "/Users/example/.local/bin/codex", defaultAccount: "Work", remoteAccount: "Work", capabilities: [], checks: [DiagnosticCheck(id: "runtime", ok: true, detail: "Official Codex executable is reachable"), DiagnosticCheck(id: "ssh", ok: false, detail: "Server CAB update required")], processes: [])
        model.backups = [ManagedBackup(id: "sample", account: "Work", path: "/accounts/work/state_5.sqlite.cab-backup-20260922", target: "/accounts/work/state_5.sqlite", bytes: 5242880, createdAt: Date(), kind: "database", safe: true, problem: nil)]
        try model.saveProfile(ProjectLaunchProfile(name: "CodexAccountBridge", directory: "/Users/example/Workspace/My/codex-account-bridge", account: "Work", remoteHost: ""))
        let id = model.beginRecord(host: "", source: "Personal", destination: "Work")
        model.record(id, stage: "预检通过", outcome: "部分完成", backups: ["/accounts/work/state_5.sqlite.cab-backup-20260922"])
        func render<V: View>(_ content: V, name: String, dark: Bool) throws {
            let view = content.padding(24).frame(width: 620).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light).cabPreservingActiveColors()
            _ = NSApplication.shared
            let hosting = NSHostingView(rootView: view)
            let size = hosting.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = hosting
            hosting.frame = NSRect(origin: .zero, size: size); hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path).appendingPathComponent("\(name)-\(dark).png"))
        }
        let lowQuota = LowQuotaMonitor(defaults: defaults)
        lowQuota.update { $0.enabled = true; $0.quietEnabled = true }
        for dark in [false, true] {
            try render(LowQuotaSettingsView(monitor: lowQuota), name: "low-quota", dark: dark)
            try render(ProjectProfileEditor(profile: model.profiles[0], accounts: [account], save: { _ in }), name: "project-editor", dark: dark)
        }
        for section in ["cab.tools", "cab.projects", "cab.history"] {
            for width in [620, 900] {
                for dark in [false, true] {
                    let view = ManagementToolsView(model: model, section: section, performsLiveChecks: false).environmentObject(store)
                        .padding(24).frame(width: CGFloat(width)).background(Color(nsColor: .windowBackgroundColor)).cabPreservingActiveColors()
                        .environment(\.colorScheme, dark ? .dark : .light)
                    _ = NSApplication.shared
                    let hosting = NSHostingView(rootView: view)
                    let size = hosting.fittingSize
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = hosting
                    hosting.frame = NSRect(origin: .zero, size: size); hosting.layoutSubtreeIfNeeded()
                    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path).appendingPathComponent("\(section)-\(width)-\(dark).png"))
                }
            }
        }
    }
}
