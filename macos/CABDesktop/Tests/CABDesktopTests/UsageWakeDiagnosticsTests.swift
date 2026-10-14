import Foundation
import Testing
@testable import CABDesktop

@MainActor
struct UsageWakeDiagnosticsTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func report(used: Double = 100, reset: Int64? = 1_999_999_999, reached: String? = "rate_limit_reached", weeklyUsed: Double = 10, weeklyReset: Int64 = 2_000_086_400) throws -> AccountUsageReport {
        let window: [String: Any] = ["used_percent": used, "window_duration_mins": 300].merging(reset.map { ["resets_at": $0] } ?? [:]) { _, new in new }
        var limits: [String: Any] = ["primary": window, "secondary": ["used_percent": weeklyUsed, "window_duration_mins": 10080, "resets_at": weeklyReset]]
        if let reached { limits["rate_limit_reached_type"] = reached }
        let data = try JSONSerialization.data(withJSONObject: ["name": "Foxmail", "usage": ["rate_limits": limits]])
        return try JSONDecoder().decode(AccountUsageReport.self, from: data)
    }

    @Test func expiredExhaustedFiveHourWindowWithStaleLimitMarkerMustProbe() throws {
        let expired = try report()
        #expect(usageWakeDecision(report: expired, now: now) == .probe)
        #expect(usageWakeNeedsScheduledProbe(report: expired, now: now))
        let onBoundary = try report(reset: Int64(now.timeIntervalSince1970))
        #expect(usageWakeDecision(report: onBoundary, now: now) == .probe)
    }

    @Test func liveExhaustionUnknownMarkersAndWeeklyLimitsRemainBlocked() throws {
        #expect(usageWakeDecision(report: try report(reset: 2_000_000_001), now: now) == .fiveHourExhausted)
        #expect(usageWakeDecision(report: try report(weeklyUsed: 100), now: now) == .weeklyExhausted)
        #expect(usageWakeDecision(report: try report(reached: "unknown"), now: now) == .limitReached)
        #expect(usageWakeDecision(report: try report(used: 0, reset: nil), now: now) == .limitReached)
        #expect(usageWakeDecision(report: try report(reset: nil), now: now) == .fiveHourExhausted)
    }

    @Test func activeAndUnknownPeriodsHaveDifferentReasons() throws {
        #expect(usageWakeDecision(report: try report(used: 1, reset: 2_000_000_600, reached: nil), now: now) == .fiveHourActive)
        #expect(usageWakeDecision(report: try report(used: 1, reset: nil, reached: nil), now: now) == .unknownWindow)
        #expect(usageWakeDecision(report: nil, now: now) == .queryFailed)
    }

    @Test func journalSurvivesRestartKeepsWindowsAndRemovesSensitiveErrors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("events.jsonl")
        let journal = UsageWakeJournal(url: url, maximumEvents: 2)
        let failed = AccountUsageReport(name: "Foxmail", usage: nil, error: "secret-token")
        for (phase, snapshot) in [("decision", try report()), ("request", try report()), ("failed", failed)] {
            try journal.append(UsageWakeEvent(at: now, target: "local", account: "Foxmail", slot: "2026-10-14-06:00", phase: phase, reason: "queryFailed", before: UsageWakeSnapshot(snapshot), after: nil))
        }
        let text = try String(contentsOf: url)
        #expect(!text.contains("secret-token"))
        #expect(text.contains("300"))
        #expect(text.split(separator: "\n").count == 2)
        let restarted = UsageWakeJournal(url: url, maximumEvents: 2)
        try restarted.append(UsageWakeEvent(target: "local", account: nil, slot: nil, phase: "scheduler", reason: "due", before: nil, after: nil))
        #expect(try String(contentsOf: url).split(separator: "\n").count == 2)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func configuredServersRunRegardlessOfVisiblePageAndDuplicateHostsAreRemoved() {
        let first = RemoteServer(name: "one", host: "oraclearm")
        let endpoints = usageWakeEndpoints(servers: [first, RemoteServer(name: "same", host: "oraclearm"), RemoteServer(name: "two", host: "other"), RemoteServer(name: "empty", host: "")])
        #expect(endpoints.count == 3)
        #expect(endpoints.map(\.host) == ["", "oraclearm", "other"])
        #expect(endpoints[1].key == "remote:\(first.id.uuidString)")
    }

    @Test func successfulRequestWithoutNewCountdownIsNotConfirmed() async throws {
        var reads = 0
        let confirmed = try await verifyUsageWake(requestedAt: now, now: { now }, read: {
            reads += 1
            return try report()
        }, wait: {}, observe: { _ in })
        #expect(!confirmed)
        #expect(reads == 3)
    }

    @Test func delayedOfficialCountdownIsConfirmedAfterReadOnlyPolling() async throws {
        var reads = 0
        var snapshots: [UsageWakeSnapshot] = []
        let confirmed = try await verifyUsageWake(requestedAt: now, now: { now }, read: {
            reads += 1
            return reads == 1 ? try report() : try report(used: 1, reset: 2_000_018_000, reached: nil)
        }, wait: {}, observe: { snapshots.append(UsageWakeSnapshot($0)) })
        #expect(confirmed)
        #expect(reads == 2)
        #expect(snapshots.last?.windows.first?.resetsAt == 2_000_018_000)
    }

    @Test func legacyWakeStateStillDecodes() throws {
        let data = try JSONEncoder().encode(UsageWakeState())
        #expect(try JSONDecoder().decode(UsageWakeState.self, from: data).lastSchedulerTickAt == nil)
    }
}

@MainActor
struct UsageWakeDeferredResetTests {
    @Test func actualOvernightSnapshotExplainsSixAMAndSchedulesResetRecheck() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let sixAM = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 6)))
        let data = Data(#"{"name":"Foxmail","usage":{"rate_limits":{"primary":{"used_percent":6,"window_duration_mins":300,"resets_at":1791929089},"secondary":{"used_percent":11,"window_duration_mins":10080,"resets_at":1792479674}}}}"#.utf8)
        let report = try JSONDecoder().decode(AccountUsageReport.self, from: data)
        #expect(usageWakeDecision(report: report, now: sixAM) == .fiveHourActive)
        let reset = try #require(usageWakeResetAfterCurrentWindow(report: report, now: sixAM))
        #expect(reset.timeIntervalSince(sixAM) == 289)
        let pending = UsageWakePendingSchedule(slot: UsageTimeOfDay(hour: 6, minute: 0)!, scheduledAt: sixAM, resetAt: reset)
        #expect(usageWakeDecision(report: report, now: reset.addingTimeInterval(1)) == .probe)
        let state = UsageWakeState(scheduledWaitsByAccount: ["local|Foxmail": pending])
        let restored = try JSONDecoder().decode(UsageWakeState.self, from: JSONEncoder().encode(state))
        #expect(restored.scheduledWaitsByAccount?["local|Foxmail"] == pending)
    }
}

@MainActor
struct UsageWakeLongCountdownTests {
    @Test func fiveHourCountdownCanBeDeferredForHoursAndSurvivesRestart() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let data = Data(#"{"name":"Foxmail","usage":{"rate_limits":{"primary":{"used_percent":40,"window_duration_mins":300,"resets_at":2000014400}}}}"#.utf8)
        let report = try JSONDecoder().decode(AccountUsageReport.self, from: data)
        let reset = try #require(usageWakeResetAfterCurrentWindow(report: report, now: now))
        #expect(reset.timeIntervalSince(now) == 4 * 3600)
        let pending = UsageWakePendingSchedule(slot: UsageTimeOfDay(hour: 6, minute: 0)!, scheduledAt: now, resetAt: reset)
        let restored = try JSONDecoder().decode(UsageWakeState.self, from: JSONEncoder().encode(UsageWakeState(scheduledWaitsByAccount: ["local|Foxmail": pending])))
        #expect(restored.scheduledWaitsByAccount?["local|Foxmail"]?.resetAt == reset)
        #expect(usageWakeResetAfterCurrentWindow(report: report, now: reset) == nil)
        #expect(usageWakeDecision(report: report, now: reset) == .probe)
    }
}
