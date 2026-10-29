import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CABDesktop

@MainActor
struct UsageResetAutomationTests {
    private func report(used: Double = 0, seconds: [Int?] = [600], ids: [String?]? = nil,
                        status: String = "available", count: Int = 2, error: String? = nil) throws -> AccountUsageReport {
        let cards: [[String: Any]] = seconds.enumerated().map { index, seconds in
            var card: [String: Any] = ["granted_at": 1, "status": status]
            if let seconds { card["expires_at"] = 2_000_000_000 + seconds }
            if let id = ids?[index] ?? (ids == nil ? "card\(index)" : nil) { card["id"] = id }
            return card
        }
        let usage: [String: Any] = ["rate_limits": ["primary": ["used_percent": used, "window_duration_mins": 300],
                                                         "secondary": ["used_percent": used, "window_duration_mins": 10080]],
                                    "reset_credits": ["available_count": count, "credits": cards]]
        var json: [String: Any] = ["name": "work", "usage": usage]
        if let error { json["error"] = error }
        return try JSONDecoder().decode(AccountUsageReport.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let suite = "UsageResetAutomationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(Fixture(defaults: defaults, report: report()))
    }

    @Test(arguments: [0.0, 45.0, 100.0])
    func ignoresRemainingQuotaAndIncludesExactTenMinuteBoundary(used: Double) throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let value = try report(used: used, seconds: [601, 600, 1, 0, -1, nil])
        #expect(expiringUsageResetCredits(report: value, now: now).map(\.creditID) == ["card2", "card1"])
    }

    @Test func skipsMissingIDsUnavailableCardsAndFailedSnapshots() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for value in [try report(ids: [nil]), try report(ids: [""]), try report(status: "used"),
                      try report(count: 0), try report(error: "offline")] {
            #expect(expiringUsageResetCredits(report: value, now: now).isEmpty)
        }
    }

    @Test func defaultsOnAndPersistsDisabledWithoutAnyRequests() async throws {
        try await withFixture { fixture in
            #expect(fixture.automation.enabled)
            fixture.automation.setEnabled(false)
            fixture.automation = UsageResetAutomation(defaults: fixture.defaults)
            #expect(!fixture.automation.enabled)
            await fixture.tick()
            #expect(fixture.reads == 0 && fixture.calls.isEmpty)
            fixture.automation.setEnabled(true)
            await fixture.tick()
            #expect(fixture.calls.count == 1)
        }
    }

    @Test func usesEarliestSpecificCardThenReadsAgainAndNeverReplaysAfterRestart() async throws {
        try await withFixture { fixture in
            fixture.report = try report(seconds: [590, 60])
            await fixture.tick()
            #expect(fixture.calls.map(\.credit) == ["card1"])
            #expect(fixture.reads == 2) // discovery and post-response read
            #expect(fixture.cached == 2)
            #expect(fixture.automation.lastResult != nil && fixture.automation.error == nil)
            fixture.automation = UsageResetAutomation(defaults: fixture.defaults)
            await fixture.tick() // even a stale official snapshot cannot replay card1
            #expect(fixture.calls.map(\.credit) == ["card1", "card0"])
            fixture.date.addTimeInterval(30)
            await fixture.tick()
            #expect(fixture.calls.count == 2)
        }
    }

    @Test func schedulesAtExpiryMinusTenMinutesWithoutWaitingForOrdinaryRefresh() async throws {
        try await withFixture { fixture in
            fixture.report = try report(seconds: [720])
            await fixture.tick()
            #expect(fixture.calls.isEmpty)
            fixture.date.addTimeInterval(119)
            await fixture.tick()
            #expect(fixture.reads == 1)
            fixture.date.addTimeInterval(1)
            await fixture.tick()
            #expect(fixture.calls.count == 1)
        }
    }

    @Test func failedResponseRetainsOriginalRequestAndBlocksOtherCardsAcrossRestart() async throws {
        try await withFixture { fixture in
            fixture.report = try report(seconds: [100, 500])
            fixture.failReset = true
            await fixture.tick()
            #expect(fixture.calls.count == 1 && fixture.automation.error != nil)
            let attempts = UsageResetAttempts(defaults: fixture.defaults)
            let pending = try attempts.begin(scope: "local", account: "work", creditID: "card0")
            #expect(pending.id == fixture.calls.first?.id)
            fixture.failReset = false
            fixture.automation = UsageResetAutomation(defaults: fixture.defaults)
            fixture.date.addTimeInterval(30)
            await fixture.tick()
            #expect(fixture.calls.count == 1)
            #expect(attempts.hasPending(scope: "local", account: "work"))
        }
    }

    @Test func nothingToResetIsTruthfulAndRetriesWithANewKeyAfterOneMinute() async throws {
        try await withFixture { fixture in
            fixture.outcome = .nothingToReset
            await fixture.tick()
            #expect(fixture.automation.lastResult?.contains("未消耗") == true)
            fixture.date.addTimeInterval(30)
            await fixture.tick()
            #expect(fixture.calls.count == 1)
            fixture.date.addTimeInterval(30)
            await fixture.tick()
            #expect(fixture.calls.count == 2 && fixture.calls[0].id != fixture.calls[1].id)
        }
    }

    @Test func checksLocalAndRemoteWithSeparateRequestScopes() async throws {
        try await withFixture { fixture in
            fixture.endpoints.append(UsageWakeEndpoint(key: "remote:test", target: .remote, host: "fixture-host"))
            await fixture.tick()
            #expect(fixture.calls.map(\.scope) == ["local", "remote:test"])
            #expect(fixture.calls[0].id != fixture.calls[1].id)
        }
    }

    @Test func disablingDuringReadCancelsRedemptionAndBusyDefersAllWork() async throws {
        try await withFixture { fixture in
            fixture.allowed = false
            await fixture.tick()
            #expect(fixture.reads == 0)
            fixture.allowed = true
            fixture.disableDuringRead = true
            await fixture.tick()
            #expect(fixture.reads == 1 && fixture.calls.isEmpty)
        }
    }

    @Test func readFailureNeverUsesOldCardsAndRetriesReadOnly() async throws {
        try await withFixture { fixture in
            fixture.failRead = true
            await fixture.tick()
            #expect(fixture.calls.isEmpty && fixture.automation.error != nil)
            fixture.failRead = false
            fixture.date.addTimeInterval(30)
            await fixture.tick()
            #expect(fixture.calls.isEmpty)
            fixture.date.addTimeInterval(30)
            await fixture.tick()
            #expect(fixture.calls.count == 1)
        }
    }

    @Test func schedulerRedeemsThroughFixtureCLIWhileRefreshIsManualAndPaused() async throws {
        try await withFixture { fixture in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent("cab-fixture")
            let script = """
            #!/usr/bin/python3
            import sys,json,time,pathlib,datetime
            root=pathlib.Path(__file__).parent
            args=sys.argv[1:]
            if args[0]=='status':
                print(json.dumps({'shared_sessions':False,'rotation':{'enabled':False},'accounts':[{'name':'work','home':str(root),'login':'present','default':False,'remote':False}]}))
            elif args[:2]==['usage','reset']:
                (root/'reset-args.json').write_text(json.dumps(args))
                print(json.dumps({'account':'work','outcome':'reset'}))
            elif args[0]=='usage':
                card={'id':'fixture-expiring-card','granted_at':1,'expires_at':int(time.time())+300,'status':'available'}
                print(json.dumps({'fetched_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'accounts':[{'name':'work','usage':{'rate_limits':{'primary':{'used_percent':0,'window_duration_mins':300}},'reset_credits':{'available_count':1,'credits':[card]}}}]}))
            else:sys.exit(2)
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let store = CABStore(service: CABService(executable: executable), desktopHome: { .notRunning }, usageResetAutomation: fixture.automation)
            store.remoteServers = []
            store.usageRefreshInterval = .manual
            store.usageWakeSettings.enabled = true
            store.usageWakeSettings.wakeOnRecovery = false
            store.usageWakeSettings.weeklyProbeTimes = []
            store.usageWakeSettings.quietPeriods = [UsageQuietPeriod(start: UsageTimeOfDay(hour: 0, minute: 0)!, end: UsageTimeOfDay(hour: 23, minute: 59)!)]
            await store.runUsageRefreshSchedulerTick()
            let data = try Data(contentsOf: root.appendingPathComponent("reset-args.json"))
            let args = try JSONDecoder().decode([String].self, from: data)
            #expect(args.contains("--confirm-reset-usage"))
            #expect(args[try #require(args.firstIndex(of: "--account")) + 1] == "work")
            #expect(args[try #require(args.firstIndex(of: "--credit-id")) + 1] == "fixture-expiring-card")
            #expect(UUID(uuidString: args[try #require(args.firstIndex(of: "--idempotency-key")) + 1]) != nil)
            #expect(store.usageResetResult == nil) // automation never opens a result dialog
            #expect(store.usageResettingAccount == nil && !store.isBusy)
            #expect(store.usageByAccount["work"]?.usage != nil)
        }
    }

    @Test func rendersSettingsUsingOnlyFixtureState() throws {
        guard let directory = ProcessInfo.processInfo.environment["CAB_RESET_AUTOMATION_RENDER_DIR"] else { return }
        let suite = "UsageResetAutomationRender.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let automation = UsageResetAutomation(defaults: defaults)
        let store = CABStore(desktopHome: { .notRunning }, usageResetAutomation: automation)
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for width in [600, 900] {
            for dark in [false, true] {
                for enabled in [false, true] {
                    automation.setEnabled(enabled)
                    let content = SystemSettingsView().environmentObject(store).environmentObject(MenuBarUsageStore())
                        .frame(width: CGFloat(width), height: 1000)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, dark ? .dark : .light).cabPreservingActiveColors()
                    let hosting = NSHostingView(rootView: content)
                    let size = NSSize(width: width, height: 1000)
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = hosting
                    hosting.frame = NSRect(origin: .zero, size: size)
                    hosting.layoutSubtreeIfNeeded()
                    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("settings-\(width)-dark-\(dark)-enabled-\(enabled).png"))
                }
            }
        }
    }
}

/// All I/O is in memory. No official CLI, SSH connection or real card is used.
@MainActor
private final class Fixture {
    let defaults: UserDefaults
    var automation: UsageResetAutomation
    var report: AccountUsageReport
    var date = Date(timeIntervalSince1970: 2_000_000_000)
    var endpoints = [UsageWakeEndpoint(key: "local", target: .local, host: "")]
    var allowed = true
    var failReset = false
    var failRead = false
    var disableDuringRead = false
    var outcome: UsageResetOutcome = .reset
    var reads = 0
    var cached = 0
    var calls: [(scope: String, credit: String, id: UUID)] = []

    init(defaults: UserDefaults, report: AccountUsageReport) {
        self.defaults = defaults
        self.report = report
        automation = UsageResetAutomation(defaults: defaults)
    }

    func tick() async {
        await automation.tick(endpoints: endpoints, now: { self.date }, allowed: { self.allowed },
            loadAccounts: { _ in ["work"] },
            loadUsage: { _, _ in
                self.reads += 1
                if self.failRead { throw BridgeError.commandFailed("fixture read failed") }
                if self.disableDuringRead { self.automation.setEnabled(false) }
                return [self.report]
            }, reset: { endpoint, account, credit, id in
                self.calls.append((endpoint.key, credit, id))
                if self.failReset { throw BridgeError.commandFailed("fixture response lost") }
                return UsageResetResult(account: account, outcome: self.outcome)
            }, cache: { _, _ in self.cached += 1 })
    }
}
