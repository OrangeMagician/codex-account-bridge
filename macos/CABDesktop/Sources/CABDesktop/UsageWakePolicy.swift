import Foundation

let usageFiveHourWindowMinutes: Int64 = 300
let usageWeeklyWindowMinutes: Int64 = 10_080
let usageWakeMaximumEntries = 3
let usageWakeProbeCooldown: TimeInterval = 30 * 60

enum UsagePeriodKind: String, Codable, CaseIterable {
    case fiveHour
    case weekly

    var durationMinutes: Int64 {
        switch self {
        case .fiveHour: return usageFiveHourWindowMinutes
        case .weekly: return usageWeeklyWindowMinutes
        }
    }

    var title: String {
        switch self {
        case .fiveHour: return "五小时"
        case .weekly: return "周"
        }
    }
}

enum UsagePeriodState: Equatable {
    case active(resetDate: Date)
    case notStarted
    case unknown
}

struct UsageTimeOfDay: Codable, Equatable, Identifiable, Hashable {
    let hour: Int
    let minute: Int

    var id: String { String(format: "%02d:%02d", hour, minute) }

    init?(hour: Int, minute: Int) {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    init(date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        self.hour = components.hour ?? 0
        self.minute = components.minute ?? 0
    }

    func date(on day: Date, calendar: Calendar = .current) -> Date? {
        var components = calendar.dateComponents([.calendar, .year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)
    }
}

struct UsageQuietPeriod: Codable, Equatable, Identifiable {
    var start: UsageTimeOfDay
    var end: UsageTimeOfDay

    var id: String { "\(start.id)-\(end.id)" }
}

struct UsageWakeSettings: Codable, Equatable {
    var enabled = false
    var wakeOnRecovery = true
    var weeklyProbeTimes: [UsageTimeOfDay] = []
    var quietPeriods: [UsageQuietPeriod] = []

    mutating func normalize() {
        weeklyProbeTimes = Array(Set(weeklyProbeTimes)).sorted { $0.id < $1.id }.prefix(usageWakeMaximumEntries).map { $0 }
        var seen = Set<String>()
        quietPeriods = quietPeriods.filter { seen.insert($0.id).inserted }
        quietPeriods = Array(quietPeriods.prefix(usageWakeMaximumEntries))
    }
}

struct UsageWakeState: Codable, Equatable {
    var lastProbeAtByAccount: [String: Date] = [:]
    var lastScheduledSlotByAccount: [String: String] = [:]
    var lastRecoveryFingerprintByAccount: [String: String] = [:]
    var pendingRecoveryFingerprintByAccount: [String: String] = [:]
    var lastResultByAccount: [String: String] = [:]
    var lastResultAtByAccount: [String: Date] = [:]

    mutating func prune(knownKeys: Set<String>) {
        lastProbeAtByAccount = lastProbeAtByAccount.filter { knownKeys.contains($0.key) }
        lastScheduledSlotByAccount = lastScheduledSlotByAccount.filter { knownKeys.contains($0.key) }
        lastRecoveryFingerprintByAccount = lastRecoveryFingerprintByAccount.filter { knownKeys.contains($0.key) }
        pendingRecoveryFingerprintByAccount = pendingRecoveryFingerprintByAccount.filter { knownKeys.contains($0.key) }
        lastResultByAccount = lastResultByAccount.filter { knownKeys.contains($0.key) }
        lastResultAtByAccount = lastResultAtByAccount.filter { knownKeys.contains($0.key) }
    }
}

func usageCodexRateLimits(for snapshot: CodexUsageSnapshot) -> UsageRateLimitSnapshot {
    snapshot.rateLimitsByLimitID?["codex"] ?? snapshot.rateLimits
}

func usageWindows(for report: AccountUsageReport) -> [UsageWindow] {
    guard report.error == nil, let usage = report.usage else { return [] }
    let limits = usageCodexRateLimits(for: usage)
    return [limits.primary, limits.secondary].compactMap { $0 }
}

func usagePeriodState(
    report: AccountUsageReport?,
    period: UsagePeriodKind,
    now: Date = Date()
) -> UsagePeriodState {
    guard let report, report.error == nil, let usage = report.usage else { return .unknown }
    let limits = usageCodexRateLimits(for: usage)
    let windows = [limits.primary, limits.secondary].compactMap { $0 }
    let matching = windows.filter {
        $0.windowDurationMins == period.durationMinutes
    }
    guard !matching.isEmpty else {
        return windows.contains(where: { $0.windowDurationMins == nil }) ? .unknown : .notStarted
    }
    guard let resetDate = matching.compactMap(\.resetDate).max() else { return .unknown }
    return resetDate > now ? .active(resetDate: resetDate) : .notStarted
}

func usageReportHasAvailableCapacity(_ report: AccountUsageReport?, now: Date = Date()) -> Bool {
    guard let report, report.error == nil, let usage = report.usage else { return false }
    let limits = usageCodexRateLimits(for: usage)
    if let reached = limits.rateLimitReachedType, !reached.isEmpty { return false }
    let windows = [limits.primary, limits.secondary].compactMap { $0 }
    if windows.isEmpty { return false }
    return windows.contains { window in
        if let resetDate = window.resetDate, resetDate <= now { return true }
        return window.remainingPercent > 0
    }
}

func usageWakeNeedsProbe(
    report: AccountUsageReport?,
    period: UsagePeriodKind,
    now: Date = Date()
) -> Bool {
    guard usageReportHasAvailableCapacity(report, now: now) else { return false }
    if case .notStarted = usagePeriodState(report: report, period: period, now: now) {
        return true
    }
    return false
}

func usageWakeNeedsProbeAfterRecovery(
    previous: AccountUsageReport?,
    current: AccountUsageReport?,
    now: Date = Date()
) -> Bool {
    guard let previous, previous.error == nil, let previousUsage = previous.usage else { return false }
    let previousLimits = usageCodexRateLimits(for: previousUsage)
    let previousWindows = [previousLimits.primary, previousLimits.secondary].compactMap { $0 }
    let previouslyExhausted = !previousWindows.isEmpty && previousWindows.allSatisfy { $0.remainingPercent <= 0 }
        || (previousLimits.rateLimitReachedType?.isEmpty == false)
    guard previouslyExhausted, usageReportHasAvailableCapacity(current, now: now) else { return false }
    return UsagePeriodKind.allCases.contains { usageWakeNeedsProbe(report: current, period: $0, now: now) }
}

func usageIsWithinQuietPeriod(
    _ date: Date,
    periods: [UsageQuietPeriod],
    calendar: Calendar = .current
) -> Bool {
    let current = UsageTimeOfDay(date: date, calendar: calendar)
    for period in periods {
        if period.start == period.end { return true }
        if period.start.id < period.end.id {
            if current.id >= period.start.id && current.id < period.end.id { return true }
        } else if current.id >= period.start.id || current.id < period.end.id {
            return true
        }
    }
    return false
}

func usageScheduledProbeSlot(
    at date: Date,
    times: [UsageTimeOfDay],
    calendar: Calendar = .current
) -> UsageTimeOfDay? {
    let current = UsageTimeOfDay(date: date, calendar: calendar)
    return times.first { $0 == current }
}

func usageScheduledProbeSlotIdentifier(
    at date: Date,
    time: UsageTimeOfDay,
    calendar: Calendar = .current
) -> String {
    let day = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d-%@", day.year ?? 0, day.month ?? 0, day.day ?? 0, time.id)
}

func usageNextScheduledProbeDate(
    after date: Date,
    times: [UsageTimeOfDay],
    calendar: Calendar = .current
) -> Date? {
    guard !times.isEmpty else { return nil }
    let sorted = times.sorted { $0.id < $1.id }
    for dayOffset in 0...1 {
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: date) else { continue }
        for time in sorted {
            guard let candidate = time.date(on: day, calendar: calendar) else { continue }
            if candidate > date { return candidate }
        }
    }
    return nil
}
