import Foundation

struct UsageResetConfirmation: Identifiable, Equatable {
    let accountName: String
    let availableCount: Int64
    let credit: UsageResetCredit?
    let fiveHourRemaining: Double?
    let weeklyRemaining: Double?

    var id: String { "\(accountName):\(credit?.id ?? "generic")" }

    var remainingPeriods: [(title: String, percent: Double)] {
        var periods: [(String, Double)] = []
        if let fiveHourRemaining, fiveHourRemaining > 0 {
            periods.append(("5 小时额度", fiveHourRemaining))
        }
        if let weeklyRemaining, weeklyRemaining > 0 {
            periods.append(("周额度", weeklyRemaining))
        }
        return periods
    }

    var hasRemainingUsage: Bool { !remainingPeriods.isEmpty }
}

func usageResetConfirmation(
    accountName: String,
    usage: CodexUsageSnapshot,
    credit: UsageResetCredit? = nil
) -> UsageResetConfirmation? {
    guard let resetCredits = usage.resetCredits, resetCredits.availableCount > 0 else { return nil }
    let periods = usagePeriodDisplays(for: usage)
    return UsageResetConfirmation(
        accountName: accountName,
        availableCount: resetCredits.availableCount,
        credit: credit,
        fiveHourRemaining: measuredRemainingPercent(periods.fiveHour),
        weeklyRemaining: measuredRemainingPercent(periods.weekly)
    )
}

private func measuredRemainingPercent(_ value: UsagePeriodDisplayValue) -> Double? {
    guard case let .measured(window) = value else { return nil }
    return window.remainingPercent
}

func usageResetCreditTitleLocalizationKey(_ title: String?) -> String {
    let value = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    switch value.lowercased() {
    case "full reset", "full reset (weekly + 5 hr)", "full reset (weekly + 5-hour)":
        return "完全重置（周额度 + 5 小时额度）"
    case "":
        return "完全重置（周额度 + 5 小时额度）"
    default:
        return value
    }
}
