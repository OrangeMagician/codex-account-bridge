import Foundation

enum UsageAutomaticRefreshDecision: Equatable {
    case useCache
    case refresh
    case pause(until: Date)
}

func exhaustedUsageResumeDate(report: AccountUsageReport) -> Date? {
    guard report.error == nil, let limits = report.usage?.rateLimits else { return nil }
    let windows = [limits.primary, limits.secondary].compactMap { $0 }
    let exhaustedWindows = windows.filter { $0.remainingPercent <= 0 }
    guard !exhaustedWindows.isEmpty else { return nil }
    let resetDates = exhaustedWindows.compactMap(\.resetDate)
    guard resetDates.count == exhaustedWindows.count else { return nil }
    return resetDates.max()
}

func usageAutomaticRefreshDecision(
    report: AccountUsageReport?,
    cacheCheckedAt: Date?,
    interval: UsageRefreshInterval,
    now: Date = Date()
) -> UsageAutomaticRefreshDecision {
    guard let report, let cacheCheckedAt else { return .refresh }
    if let resumeDate = exhaustedUsageResumeDate(report: report) {
        if resumeDate > now {
            return .pause(until: resumeDate)
        }
        if cacheCheckedAt < resumeDate {
            return .refresh
        }
    }

    guard let duration = interval.duration else { return .useCache }
    return now.timeIntervalSince(cacheCheckedAt) < duration ? .useCache : .refresh
}

func usageAccountNamesToRefresh(
    accountNames: [String],
    reports: [String: AccountUsageReport],
    checkedAtByAccount: [String: Date],
    interval: UsageRefreshInterval,
    now: Date = Date()
) -> [String] {
    accountNames.sorted().filter { accountName in
        usageAutomaticRefreshDecision(
            report: reports[accountName],
            cacheCheckedAt: checkedAtByAccount[accountName],
            interval: interval,
            now: now
        ) == .refresh
    }
}
