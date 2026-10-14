import Foundation

enum UsageWakeDecision: String, Codable {
    case probe, fiveHourActive, noFiveHourLimit, unknownWindow, queryFailed
    case fiveHourExhausted, weeklyExhausted, otherWindowExhausted, limitReached, spendingBlocked

    var message: String {
        switch self {
        case .probe: return "五小时周期尚未开始，准备请求"
        case .fiveHourActive: return "五小时周期仍在计时，已跳过"
        case .noFiveHourLimit: return "账号没有五小时额度限制，已跳过"
        case .unknownWindow: return "额度窗口信息不完整，已跳过"
        case .queryFailed: return "额度查询失败，未使用旧数据发送请求"
        case .fiveHourExhausted: return "五小时额度耗尽且尚未恢复，已跳过"
        case .weeklyExhausted: return "周额度耗尽且尚未恢复，已跳过"
        case .otherWindowExhausted: return "其他额度窗口耗尽，已跳过"
        case .limitReached: return "官方仍返回限额标记且无法确认已恢复，已跳过"
        case .spendingBlocked: return "账号消费上限已触发，已跳过"
        }
    }
}

func usageWakeDecision(report: AccountUsageReport?, now: Date = Date()) -> UsageWakeDecision {
    guard let report, report.error == nil, let usage = report.usage else { return .queryFailed }
    let limits = usageCodexRateLimits(for: usage)
    let windows = [limits.primary, limits.secondary].compactMap { $0 }
    guard windows.contains(where: { $0.windowDurationMins == usageFiveHourWindowMinutes }) else {
        return windows.isEmpty || windows.contains(where: { $0.windowDurationMins == nil }) ? .unknownWindow : .noFiveHourLimit
    }
    guard windows.allSatisfy({ $0.windowDurationMins != nil }) else { return .unknownWindow }
    if limits.spendControlReached == true { return .spendingBlocked }
    if let individual = limits.individualLimit, individual.remainingPercent <= 0,
       Date(timeIntervalSince1970: TimeInterval(individual.resetsAt)) > now { return .spendingBlocked }
    for window in windows where window.remainingPercent <= 0 {
        if let reset = window.resetDate, reset <= now { continue }
        switch window.windowDurationMins {
        case usageFiveHourWindowMinutes: return .fiveHourExhausted
        case usageWeeklyWindowMinutes: return .weeklyExhausted
        default: return .otherWindowExhausted
        }
    }
    if let reached = limits.rateLimitReachedType, !reached.isEmpty {
        // A stale marker can accompany a 100%-used window whose reset has
        // passed. Only this explicit evidence permits a single verified probe.
        let expiredExhaustion = windows.contains { $0.remainingPercent <= 0 && ($0.resetDate.map { $0 <= now } ?? false) }
        if reached != "rate_limit_reached" || !expiredExhaustion { return .limitReached }
    }
    switch usagePeriodState(report: report, period: .fiveHour, now: now) {
    case .active: return .fiveHourActive
    case .notStarted: return .probe
    case .unknown: return .unknownWindow
    }
}

// Explicit whitelist: no credentials, request contents, session data, or raw
// subprocess/error output is written to the diagnostic journal.
struct UsageWakeSnapshot: Codable, Equatable {
    let fetchedAt: Date?
    let queryFailed: Bool
    let windows: [UsageWindow]
    let limitReached: String?
    let spendingBlocked: Bool?

    init(_ report: AccountUsageReport?) {
        fetchedAt = report?.fetchedAt
        queryFailed = report == nil || report?.error != nil || report?.usage == nil
        if let usage = report?.usage {
            let limits = usageCodexRateLimits(for: usage)
            windows = [limits.primary, limits.secondary].compactMap { $0 }
            limitReached = limits.rateLimitReachedType.map { $0 == "rate_limit_reached" ? $0 : "other_limit_marker" }
            spendingBlocked = limits.spendControlReached
        } else { windows = []; limitReached = nil; spendingBlocked = nil }
    }
}

struct UsageWakeEvent: Codable, Equatable {
    var at: Date = Date()
    let target: String
    let account: String?
    let slot: String?
    let phase: String
    let reason: String
    let before: UsageWakeSnapshot?
    let after: UsageWakeSnapshot?
}

@MainActor
final class UsageWakeJournal {
    static let shared = UsageWakeJournal()
    let url: URL
    private let maximumEvents: Int

    init(url: URL? = nil, maximumEvents: Int = 2000) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/codex-account-bridge/usage-wake-events.jsonl")
        self.maximumEvents = max(1, maximumEvents)
    }

    func append(_ event: UsageWakeEvent) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let old: Data
        if manager.fileExists(atPath: url.path) {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadUnknown) }
            old = try Data(contentsOf: url)
        } else { old = Data() }
        var lines = old.split(separator: 10).suffix(maximumEvents - 1).map { Data($0) }
        lines.append(try encoder.encode(event))
        var output = Data()
        for line in lines { output.append(line); output.append(10) }
        try output.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct UsageWakeEndpoint: Equatable {
    let key: String
    let target: BridgeTarget
    let host: String
}

func usageWakeEndpoints(servers: [RemoteServer]) -> [UsageWakeEndpoint] {
    var endpoints = [UsageWakeEndpoint(key: "local", target: .local, host: "")]
    var hosts = Set<String>()
    for server in servers where !server.host.isEmpty && hosts.insert(server.host).inserted {
        endpoints.append(UsageWakeEndpoint(key: "remote:\(server.id.uuidString)", target: .remote, host: server.host))
    }
    return endpoints
}

// Query retries are read-only. Never resend a model request after success,
// failure, or a delayed/missing quota update.
@MainActor
func verifyUsageWake(
    requestedAt: Date,
    now: () -> Date = Date.init,
    read: () async throws -> AccountUsageReport?,
    wait: () async throws -> Void,
    observe: (AccountUsageReport?) throws -> Void
) async throws -> Bool {
    for attempt in 0..<3 {
        if attempt > 0 { try await wait() }
        let report = try await read()
        try observe(report)
        if case let .active(reset) = usagePeriodState(report: report, period: .fiveHour, now: now()),
           reset > requestedAt, reset <= now().addingTimeInterval(5 * 3600 + 120) {
            return true
        }
    }
    return false
}

func usageWakeProbeFailureReason(_ error: Error) -> String {
    let message = error.localizedDescription
    for category in ["authentication_required", "model_unavailable", "rate_limited", "network_failed", "timed out"] {
        if message.contains(category) { return category == "timed out" ? "probe_timeout" : category }
    }
    return "official_command_failed"
}

struct UsageWakePendingSchedule: Codable, Equatable {
    let slot: UsageTimeOfDay
    let scheduledAt: Date
    let resetAt: Date
    var latestScheduledAt: Date? = nil
    var latestSlot: UsageTimeOfDay? = nil

    var completionSlotID: String {
        usageScheduledProbeSlotIdentifier(at: latestScheduledAt ?? scheduledAt, time: latestSlot ?? slot)
    }
}

func usageWakeResetAfterCurrentWindow(report: AccountUsageReport?, now: Date) -> Date? {
    guard let report, report.error == nil,
          let reset = usageWindows(for: report).first(where: { $0.windowDurationMins == usageFiveHourWindowMinutes })?.resetDate,
          reset > now else { return nil }
    return reset
}
