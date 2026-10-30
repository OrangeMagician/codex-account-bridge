import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CABDesktop

@MainActor
struct AppSettingsNavigationTests {
    private let now = publicResetDate("2026-10-30T03:00:00Z")!

    private func record(type: String = "global", date: Date? = nil, kind: String = "reset_completed") -> PublicResetRecord {
        PublicResetRecord(id: "fixture", kind: kind, resetType: type,
                          announcedAt: ISO8601DateFormatter().string(from: date ?? now), effectiveAt: nil,
                          completedAt: nil, confidence: nil, scope: nil, source: .init(url: nil))
    }

    @Test func settingsIsNotAnAccountAndSurvivesLocationChanges() {
        let store = CABStore(service: CABService(executable: URL(fileURLWithPath: "/usr/bin/false")), desktopHome: { .notRunning })
        store.remoteServers = []
        store.sidebarSelection = CABStore.appSettingsSelection
        #expect(store.showingAppSettings && !store.showingTools && !store.showingGlobalSettings)
        #expect(store.selectedAccount == nil)
        store.changeTarget(.remote)
        #expect(store.showingAppSettings && store.selectedAccount == nil)
        store.sidebarSelection = CABStore.globalSettingsSelection
        #expect(!store.showingAppSettings && store.showingGlobalSettings)
        store.sidebarSelection = "work"
        #expect(store.selectedAccount == "work")
    }

    @Test func todaySummaryDistinguishesPublicResetsFromCardGrantsAndUnknownData() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func status(_ records: [PublicResetRecord], generated: Date? = nil, error: String? = nil) -> PublicResetTodayStatus {
            publicResetTodayStatus(snapshot: .init(records: records, generatedAt: generated ?? now), checking: false,
                                   error: error, now: now, calendar: calendar)
        }
        #expect(status([record()]) == .occurred)
        #expect(status([record(type: "global_and_banked")]) == .occurred)
        #expect(status([record(type: "banked")]) == .none)
        #expect(status([record(kind: "reset_scheduled")]) == .none)
        #expect(status([record(date: now.addingTimeInterval(60))]) == .none)
        #expect(status([record(date: now.addingTimeInterval(-86400))]) == .none)
        #expect(status([], generated: now.addingTimeInterval(-7200)) == .unknown)
        #expect(status([], error: "offline") == .unknown)
        #expect(publicResetTodayStatus(snapshot: nil, checking: true, error: nil) == .checking)
        let midnight = publicResetDate("2026-10-30T16:01:00Z")!
        #expect(publicResetTodayStatus(snapshot: .init(records: [], generatedAt: midnight.addingTimeInterval(-120)),
                                       checking: false, error: nil, now: midnight, calendar: calendar) == .unknown)
    }

    @Test func overviewCanReadWithAlertsOffWithoutAuthorizationOrNotifications() async {
        let suite = "CABOverviewTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var reads = 0
        let monitor = PublicResetMonitor(defaults: defaults, fetch: {
            reads += 1
            return .init(records: [record()], generatedAt: now)
        }, authorize: { Issue.record("Overview requested notification permission"); return false },
           notify: { _ in Issue.record("Overview sent a notification with alerts off") })
        await monitor.check(now: now)
        #expect(reads == 0)
        await monitor.checkForDisplay(now: now)
        #expect(reads == 1 && monitor.snapshot?.records.count == 1 && !monitor.enabled)
        #expect(defaults.data(forKey: "publicResetCheckpoint.v1") == nil)
        await monitor.checkForDisplay(now: now.addingTimeInterval(60))
        #expect(reads == 1) // Reopening the page shares the rate-limit deadline.
        await monitor.checkForDisplay(now: now.addingTimeInterval(300))
        #expect(reads == 2)
    }

    @Test func cancelledOverviewReadDiscardsLateResult() async {
        let suite = "CABOverviewCancelTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var continuation: CheckedContinuation<PublicResetSnapshot, Never>?
        let monitor = PublicResetMonitor(defaults: defaults, fetch: {
            await withCheckedContinuation { continuation = $0 }
        }, authorize: { false }, notify: { _ in Issue.record("Unexpected notification") })
        let task = Task { await monitor.checkForDisplay(now: now) }
        while continuation == nil { await Task.yield() }
        task.cancel()
        continuation?.resume(returning: .init(records: [record()], generatedAt: now))
        await task.value
        #expect(monitor.snapshot == nil && !monitor.checking)
    }

    @Test func renderMainWindowOverviewAndSettingsWithoutLiveOperations() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CAB_APP_SETTINGS_RENDER_DIR"] else { return }
        let suite = "CABSettingsRender.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let date = Date()
        let monitor = PublicResetMonitor(defaults: defaults, fetch: {
            .init(records: [record(date: date)], generatedAt: date)
        }, authorize: { false }, notify: { _ in Issue.record("Render sent a notification") })
        await monitor.checkForDisplay(now: date)
        let automation = UsageResetAutomation(defaults: defaults)
        automation.setEnabled(false)
        let store = CABStore(desktopHome: { .notRunning }, usageResetAutomation: automation)
        store.remoteServers = []
        store.status = BridgeStatus(sharedSessions: false, rotation: RotationStatus(enabled: false), accounts: [
            AccountStatus(name: "Work", home: "/fixture/work", login: "present", default: true, remote: false)
        ])
        store.usageByAccount = ["Work": try JSONDecoder().decode(AccountUsageReport.self, from: Data("""
        {"name":"Work","usage":{"rate_limits":{"primary":{"used_percent":25,"window_duration_mins":300},"secondary":{"used_percent":40,"window_duration_mins":10080}}}}
        """.utf8))]
        store.interfaceLanguage = .simplifiedChinese
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for selection in [CABStore.globalSettingsSelection, CABStore.appSettingsSelection] {
            store.sidebarSelection = selection
            for width in [900, 1200] {
                for dark in [false, true] {
                    let content = ContentView(performsLiveChecks: false, publicResetMonitor: monitor)
                        .environmentObject(store).environmentObject(MenuBarUsageStore())
                        .frame(width: CGFloat(width), height: 900)
                        .environment(\.colorScheme, dark ? .dark : .light).cabPreservingActiveColors()
                    let hosting = NSHostingView(rootView: content)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = hosting
                    hosting.frame = window.contentLayoutRect
                    hosting.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    let page = selection == CABStore.appSettingsSelection ? "settings" : "overview"
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("\(page)-\(width)-dark-\(dark).png"))
                }
            }
        }
    }
}
