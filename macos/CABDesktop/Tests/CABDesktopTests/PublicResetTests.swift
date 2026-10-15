import Foundation
import AppKit
import SwiftUI
import Testing
@testable import CABDesktop

struct PublicResetTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func record(_ id: String, type: String = "global", kind: String = "reset_completed", date: Date? = nil) -> PublicResetRecord {
        PublicResetRecord(id: id, kind: kind, resetType: type,
                          announcedAt: ISO8601DateFormatter().string(from: date ?? now),
                          effectiveAt: nil, completedAt: nil, confidence: 0.9,
                          scope: .init(plans: ["all"], windows: ["unknown"]),
                          source: .init(url: "https://x.com/thsottiaux/status/123"))
    }

    @Test func baselineAndRestartDeduplicateWhileKeepingBothResetTypes() throws {
        var checkpoint = PublicResetCheckpoint()
        let initial = PublicResetSnapshot(records: [record("old")], generatedAt: now)
        #expect(checkpoint.alerts(in: initial, now: now).isEmpty)
        checkpoint.markSeen(initial.records, now: now)
        let next = PublicResetSnapshot(records: [record("bank", type: "banked"), record("global"), record("old"), record("global")], generatedAt: now)
        #expect(Set(checkpoint.alerts(in: next, now: now).map(\.id)) == ["bank", "global"])
        checkpoint.markSeen(next.records, now: now)
        let restored = try JSONDecoder().decode(PublicResetCheckpoint.self, from: JSONEncoder().encode(checkpoint))
        #expect(restored.alerts(in: next, now: now).isEmpty)
    }

    @Test func scheduledUnknownFutureAndHistoricalRecordsNeverAlert() {
        let checkpoint = PublicResetCheckpoint(initializedAt: now, seenIDs: [])
        let snapshot = PublicResetSnapshot(records: [record("schedule", kind: "reset_scheduled"), record("unknown", type: "unknown"), record("future", date: now.addingTimeInterval(60)), record("history", date: now.addingTimeInterval(-86401)), record("both", type: "global_and_banked")], generatedAt: now)
        #expect(checkpoint.alerts(in: snapshot, now: now).map(\.id) == ["both"])
        #expect(checkpoint.alerts(in: .init(records: [record("fresh")], generatedAt: now.addingTimeInterval(-3601)), now: now).isEmpty)
    }

    @Test func nullableManualRecordAndMillisecondTimestampsDecode() throws {
        let data = Data("""
        {"ok":true,"data":{"items":[{"id":"manual:1","kind":"reset_completed","resetType":"global","announcedAt":null,"effectiveAt":"2026-10-14T00:05:00.123Z","completedAt":null,"confidence":null,"scope":null,"source":{"url":null}}]},"meta":{"generatedAt":"2026-10-14T00:10:00.000Z"}}
        """.utf8)
        let response = HTTPURLResponse(url: PublicResetFeedClient.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let snapshot = try PublicResetFeedClient.decode(data, response: response)
        #expect(snapshot.records.count == 1)
        #expect(snapshot.records.first?.date == publicResetDate("2026-10-14T00:05:00.123Z"))
        #expect(snapshot.records.first?.sourceURL == nil)
    }

    @Test func rateLimitHonorsLongerBodyAndHeader() throws {
        let response = HTTPURLResponse(url: PublicResetFeedClient.endpoint, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "600"])!
        do {
            _ = try PublicResetFeedClient.decode(Data("{\"retryAfter\":1200}".utf8), response: response)
            Issue.record("Expected rate limit")
        } catch PublicResetFeedError.rateLimited(let delay) { #expect(delay == 1200) }
    }

    @Test func rateLimitParsesHTTPDateAndRejectsMalformedSuccess() throws {
        let response = HTTPURLResponse(url: PublicResetFeedClient.endpoint, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "Wed, 14 Oct 2026 00:20:00 GMT"])!
        let requestTime = publicResetDate("2026-10-14T00:00:00Z")!
        do {
            _ = try PublicResetFeedClient.decode(Data("{}".utf8), response: response, now: requestTime)
            Issue.record("Expected rate limit")
        } catch PublicResetFeedError.rateLimited(let delay) { #expect(delay == 1200) }
        let ok = HTTPURLResponse(url: PublicResetFeedClient.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        #expect(throws: (any Error).self) { try PublicResetFeedClient.decode(Data("{\"ok\":false}".utf8), response: ok) }
    }

    @Test func notificationLinksOnlyOpenTrustedSourcesForPublicResetNotifications() {
        #expect(publicResetNotificationURL(identifier: "cab.public-reset.1", value: "https://x.com/thsottiaux/status/1") != nil)
        #expect(publicResetNotificationURL(identifier: "cab.usage-reset.1", value: "https://x.com/") == nil)
        for url in ["https://evil.example/", "https://x.com.evil.example/", "http://x.com/", "file:///tmp/", "https://name:password@x.com/"] {
            #expect(publicResetNotificationURL(identifier: "cab.public-reset.1", value: url) == nil)
        }
    }

    @Test func todayUsesLocalDayRatherThanUTC() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let midnight = publicResetDate("2026-10-13T16:01:00Z")!
        let announcement = record("today", date: publicResetDate("2026-10-13T16:00:00Z")!)
        #expect(publicResetOccurredToday(announcement, now: midnight, calendar: calendar))
    }

    @MainActor @Test func monitorRetriesNotificationFailuresWithoutRepeatingDeliveredEvents() async throws {
        let suite = "cab.public-reset.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "publicResetEnabled.v1")
        var records = [record("baseline")]
        var notifications: [String] = []
        var fail = true
        let monitor = PublicResetMonitor(defaults: defaults, fetch: { .init(records: records, generatedAt: self.now) }, authorize: { true }, notify: { event in
            if event.id == "bank" && fail { throw PublicResetFeedError.http(503) }
            notifications.append(event.id)
        })
        await monitor.check(now: now)
        #expect(notifications.isEmpty)
        records = [record("new"), record("bank", type: "banked")]
        await monitor.check(now: now.addingTimeInterval(300))
        #expect(notifications == ["new"])
        #expect(monitor.error != nil)
        fail = false
        await monitor.check(now: now.addingTimeInterval(600))
        #expect(notifications == ["new", "bank"])
        let restarted = PublicResetMonitor(defaults: defaults, fetch: { .init(records: records, generatedAt: self.now) }, authorize: { true }, notify: { notifications.append($0.id) })
        await restarted.check(now: now.addingTimeInterval(900))
        #expect(notifications == ["new", "bank"])
    }

    @MainActor @Test func staleSnapshotsDoNotEstablishBaselineAndFailuresKeepLastSnapshot() async {
        let suite = "cab.public-reset.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "publicResetEnabled.v1")
        var generated = now.addingTimeInterval(-7200)
        var fail = false
        var notifications: [String] = []
        let monitor = PublicResetMonitor(defaults: defaults, fetch: {
            if fail { throw PublicResetFeedError.http(503) }
            return .init(records: [self.record("existing")], generatedAt: generated)
        }, authorize: { true }, notify: { notifications.append($0.id) })
        await monitor.check(now: now)
        #expect(defaults.data(forKey: "publicResetCheckpoint.v1") == nil)
        #expect(monitor.error != nil)
        generated = now.addingTimeInterval(300)
        await monitor.check(now: now.addingTimeInterval(300))
        #expect(notifications.isEmpty)
        #expect(monitor.error == nil)
        let previous = monitor.snapshot
        fail = true
        await monitor.check(now: now.addingTimeInterval(600))
        #expect(monitor.snapshot == previous)
        #expect(monitor.error != nil)
    }

    @MainActor @Test func disableDuringFetchDiscardsLateResponse() async {
        let suite = "cab.public-reset.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "publicResetEnabled.v1")
        var continuation: CheckedContinuation<PublicResetSnapshot, Never>?
        let monitor = PublicResetMonitor(defaults: defaults, fetch: {
            await withCheckedContinuation { continuation = $0 }
        }, authorize: { true }, notify: { _ in Issue.record("Disabled monitor notified") })
        let request = Task { await monitor.check(now: self.now) }
        while continuation == nil { await Task.yield() }
        monitor.setEnabled(false)
        continuation?.resume(returning: .init(records: [record("late")], generatedAt: now))
        await request.value
        #expect(monitor.snapshot == nil)
        #expect(defaults.data(forKey: "publicResetCheckpoint.v1") == nil)
        #expect(!monitor.enabled)
    }

    @MainActor @Test func renderPublicResetSettings() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CAB_PUBLIC_RESET_RENDER_DIR"] else { return }
        let suite = "cab.public-reset.render." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "publicResetEnabled.v1")
        let date = Date()
        let records = [record("global", date: date), record("bank", type: "banked", date: date)]
        let monitor = PublicResetMonitor(defaults: defaults, fetch: { .init(records: records, generatedAt: date) }, authorize: { true }, notify: { _ in })
        await monitor.check(now: date)
        defer { monitor.setEnabled(false) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for width in [600, 900] {
            for dark in [false, true] {
                let content = GroupBox { PublicResetSettingsView(monitor: monitor).padding(8) } label: { Text("额度与通知") }
                    .padding(24).frame(width: CGFloat(width))
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light).cabPreservingActiveColors()
                _ = NSApplication.shared
                let hosting = NSHostingView(rootView: content)
                let size = hosting.fittingSize
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = hosting
                hosting.frame = NSRect(origin: .zero, size: size)
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("public-reset-\(width)-\(dark).png"))
            }
        }
    }

    @MainActor @Test func livePublicFeedIsCompatible() async throws {
        guard ProcessInfo.processInfo.environment["CAB_PUBLIC_RESET_LIVE_CHECK"] == "1" else { return }
        let snapshot = try await PublicResetFeedClient().fetch()
        #expect(snapshot.records.count <= 10)
        #expect(snapshot.records.allSatisfy { $0.isCompleted })
        #expect(snapshot.generatedAt <= Date().addingTimeInterval(300))
    }

    @MainActor @Test func disabledMonitorDoesNotFetchAndRateLimitBlocksAllEntryPoints() async {
        let suite = "cab.public-reset.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        let disabled = PublicResetMonitor(defaults: defaults, fetch: { calls += 1; throw PublicResetFeedError.http(503) })
        await disabled.check(now: now)
        #expect(calls == 0)
        defaults.set(true, forKey: "publicResetEnabled.v1")
        let enabled = PublicResetMonitor(defaults: defaults, fetch: { calls += 1; throw PublicResetFeedError.rateLimited(1200) })
        await enabled.check(now: now)
        await enabled.check(now: now.addingTimeInterval(1199))
        #expect(calls == 1)
        #expect(enabled.snapshot == nil)
        #expect(enabled.nextCheckAt == now.addingTimeInterval(1200))
        enabled.setEnabled(false)
        await enabled.check(now: now.addingTimeInterval(1500))
        #expect(calls == 1)
    }
}
