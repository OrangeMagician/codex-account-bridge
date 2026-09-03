import Foundation

enum UsagePeriodDisplayValue: Equatable {
    case measured(UsageWindow)
    case unlimited
    case unavailable

    var remainingPercent: Double? {
        switch self {
        case let .measured(window): return window.remainingPercent
        case .unlimited: return 100
        case .unavailable: return nil
        }
    }
}

struct UsagePeriodDisplays: Equatable {
    let fiveHour: UsagePeriodDisplayValue
    let weekly: UsagePeriodDisplayValue
}

func usagePeriodDisplays(for snapshot: CodexUsageSnapshot) -> UsagePeriodDisplays {
    let limits = usageCodexRateLimits(for: snapshot)
    let windows = [limits.primary, limits.secondary].compactMap { $0 }

    let fiveHour = windows.first { $0.windowDurationMins == usageFiveHourWindowMinutes }
        ?? limits.primary.flatMap { $0.windowDurationMins == nil ? $0 : nil }
    let weekly = windows.first { $0.windowDurationMins == usageWeeklyWindowMinutes }
        ?? limits.secondary.flatMap { $0.windowDurationMins == nil ? $0 : nil }

    let missingFiveHour: UsagePeriodDisplayValue = windows.isEmpty ? .unavailable : .unlimited

    return UsagePeriodDisplays(
        fiveHour: fiveHour.map(UsagePeriodDisplayValue.measured) ?? missingFiveHour,
        weekly: weekly.map(UsagePeriodDisplayValue.measured) ?? .unavailable
    )
}
