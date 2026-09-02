import Foundation

enum UsageAutomaticRefreshDecision: Equatable {
    case useCache
    case refresh
}

func usageAutomaticRefreshDecision(
    report _: AccountUsageReport?,
    cacheCheckedAt: Date?,
    interval: UsageRefreshInterval,
    now: Date = Date()
) -> UsageAutomaticRefreshDecision {
    guard let cacheCheckedAt else { return .refresh }
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
