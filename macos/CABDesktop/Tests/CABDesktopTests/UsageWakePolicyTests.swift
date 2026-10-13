import Foundation
import Testing
@testable import CABDesktop

struct UsageWakePolicyTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func report(_ windows: String) throws -> AccountUsageReport {
        try JSONDecoder().decode(AccountUsageReport.self, from: Data("""
        {"name":"test","usage":{"rate_limits":{\(windows)}}}
        """.utf8))
    }

    @Test func weeklyOnlyAccountNeverSendsScheduledOrRecoveryRequest() throws {
        let current = try report("\"primary\":{\"used_percent\":0,\"window_duration_mins\":10080,\"resets_at\":2000000600}")
        let previous = try report("\"primary\":{\"used_percent\":100,\"window_duration_mins\":10080,\"resets_at\":1999999999}")
        #expect(!usageWakeNeedsScheduledProbe(report: current, now: now))
        #expect(!usageWakeNeedsProbeAfterRecovery(previous: previous, current: current, now: now))
    }

    @Test func unusedFiveHourWindowWithoutResetStartsCountdown() throws {
        let current = try report("\"primary\":{\"used_percent\":0,\"window_duration_mins\":300}")
        #expect(usagePeriodState(report: current, period: .fiveHour, now: now) == .notStarted)
        #expect(usageWakeNeedsScheduledProbe(report: current, now: now))
    }

    @Test func weeklyExhaustionBlocksProbeEvenWithUnusedFiveHourWindow() throws {
        let current = try report("\"primary\":{\"used_percent\":0,\"window_duration_mins\":300},\"secondary\":{\"used_percent\":100,\"window_duration_mins\":10080,\"resets_at\":2000000600}")
        #expect(!usageWakeNeedsScheduledProbe(report: current, now: now))
    }

    @Test func missingFiveHourDurationAndEmptyReportsNeverProbe() throws {
        for windows in ["", "\"primary\":{\"used_percent\":0}"] {
            #expect(!usageWakeNeedsScheduledProbe(report: try report(windows), now: now))
        }
    }

    @Test func slightlyLateTickRunsScheduledTaskDuringQuietPeriod() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let time = UsageTimeOfDay(hour: 6, minute: 0)!
        let scheduled = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 6)))
        let settings = UsageWakeSettings(enabled: true, weeklyProbeTimes: [time], quietPeriods: [
            UsageQuietPeriod(start: UsageTimeOfDay(hour: 0, minute: 0)!, end: UsageTimeOfDay(hour: 7, minute: 0)!)
        ])
        #expect(usageWakeTickMode(at: scheduled.addingTimeInterval(90), settings: settings, calendar: calendar) == .scheduled(time))
        #expect(usageWakeTickMode(at: scheduled.addingTimeInterval(300), settings: settings, calendar: calendar) == .paused)
        #expect(usageScheduledProbeSlot(at: scheduled.addingTimeInterval(-1), times: [time], calendar: calendar) == nil)
    }
}
