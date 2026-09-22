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

struct UsageReserveDisplay: Equatable, Identifiable {
    let id: String
    let name: String
    let window: UsageWindow

    var remainingPercent: Double { window.remainingPercent }
    var resetDate: Date? { window.resetDate }
}

/// Returns the optional reserve/fallback model bucket reported by app-server.
/// The normal Codex bucket is deliberately excluded; reserve buckets are
/// identified from the server-provided id/name so new labels remain visible.
func usageReserveDisplays(for snapshot: CodexUsageSnapshot) -> [UsageReserveDisplay] {
    guard let buckets = snapshot.rateLimitsByLimitID, !buckets.isEmpty else { return [] }
    let primary = usageCodexRateLimits(for: snapshot)
    let primaryID = primary.limitID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    return buckets.compactMap { key, bucket in
        let bucketID = (bucket.limitID ?? key).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedID = bucketID.lowercased()
        guard normalizedID != "codex", normalizedID != primaryID else { return nil }
        let descriptor = "\(normalizedID) \((bucket.limitName ?? "").lowercased())"
        let isOtherBucket = normalizedID == "other" || normalizedID.hasSuffix("_other")
        let reserveMarker = isOtherBucket || ["reserve", "fallback", "backup", "备用", "后备"]
            .contains { descriptor.contains($0) }
        guard reserveMarker, let window = bucket.primary ?? bucket.secondary else { return nil }

        let suppliedName = bucket.limitName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name: String
        if !suppliedName.isEmpty, suppliedName.lowercased() != normalizedID {
            name = suppliedName
        } else if normalizedID == "codex_other" {
            // The official app-server uses codex_other for the Luna Reserve bucket.
            name = "Luna Reserve"
        } else if normalizedID == "fallback" {
            name = cabLocalized("备用模型")
        } else {
            name = bucketID
        }
        return UsageReserveDisplay(id: bucketID, name: name, window: window)
    }
    .sorted { lhs, rhs in
        if lhs.name.caseInsensitiveCompare(rhs.name) == .orderedSame { return lhs.id < rhs.id }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
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
