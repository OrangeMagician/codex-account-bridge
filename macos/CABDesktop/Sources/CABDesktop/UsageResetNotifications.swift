import Foundation
import UserNotifications

let usageResetNotificationIdentifierPrefix = "cab.usage-reset."

struct UsageNotificationSource: Equatable {
    let key: String
    let title: String
    let reports: [AccountUsageReport]
}

struct UsageResetNotificationPlan: Equatable {
    let identifier: String
    let title: String
    let body: String
    let date: Date
}

func usageResetNotificationPlans(
    sources: [UsageNotificationSource],
    now: Date = Date(),
    maximumCount: Int = 60
) -> [UsageResetNotificationPlan] {
    guard maximumCount > 0 else { return [] }
    var plans: [UsageResetNotificationPlan] = []
    for source in sources {
        for report in source.reports where report.error == nil {
            guard let limits = report.usage?.rateLimits else { continue }
            let windows: [(String, String, UsageWindow?)] = [
                ("primary", "主要周期", limits.primary),
                ("secondary", "次要周期", limits.secondary),
            ]
            for (key, title, window) in windows {
                guard let resetDate = window?.resetDate, resetDate > now else { continue }
                let identifier = "cab.usage-reset.\(source.key).\(report.name).\(key).\(window?.resetsAt ?? 0)"
                plans.append(UsageResetNotificationPlan(
                    identifier: identifier,
                    title: "Codex 额度已到重置时间",
                    body: "\(source.title) · \(report.name) 的\(title)预计已重置。打开 CAB 刷新后可查看最新额度。",
                    date: resetDate
                ))
            }
        }
    }
    return Array(plans.sorted { left, right in
        if left.date != right.date { return left.date < right.date }
        return left.identifier < right.identifier
    }.prefix(maximumCount))
}

func usageResetNotificationIdentifiersToReplace(
    _ identifiers: [String],
    sourceKeys: Set<String>?
) -> [String] {
    identifiers.filter { identifier in
        guard identifier.hasPrefix(usageResetNotificationIdentifierPrefix) else { return false }
        guard let sourceKeys else { return true }
        return sourceKeys.contains { sourceKey in
            identifier.hasPrefix("\(usageResetNotificationIdentifierPrefix)\(sourceKey).")
        }
    }
}

enum UsageResetNotificationError: LocalizedError {
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "macOS 通知权限未开启。请在“系统设置 > 通知 > CodexAccountBridge”中允许通知后重试。"
        }
    }
}

final class UsageResetNotificationService: NSObject, UNUserNotificationCenterDelegate {
    private static let maximumPendingNotificationCount = 60
    private let center: UNUserNotificationCenter

    override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func replaceScheduledNotifications(
        with plans: [UsageResetNotificationPlan],
        replacingSourceKeys sourceKeys: Set<String>? = nil
    ) async throws -> Int {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw UsageResetNotificationError.permissionDenied
        }
        let existing = await center.pendingNotificationRequests()
        let existingCABIDs = existing.map(\.identifier).filter {
            $0.hasPrefix(usageResetNotificationIdentifierPrefix)
        }
        let replacedIDs = usageResetNotificationIdentifiersToReplace(
            existingCABIDs,
            sourceKeys: sourceKeys
        )
        let retainedCount = existingCABIDs.count - replacedIDs.count
        let availableCount = max(0, Self.maximumPendingNotificationCount - retainedCount)
        let scheduledPlans = plans.prefix(availableCount)
        center.removePendingNotificationRequests(withIdentifiers: replacedIDs)

        for plan in scheduledPlans {
            let content = UNMutableNotificationContent()
            content.title = plan.title
            content.body = plan.body
            content.sound = .default
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: plan.date
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            try await center.add(UNNotificationRequest(
                identifier: plan.identifier,
                content: content,
                trigger: trigger
            ))
        }
        return retainedCount + scheduledPlans.count
    }

    func cancelScheduledNotifications() async {
        let existing = await center.pendingNotificationRequests()
        let existingIDs = usageResetNotificationIdentifiersToReplace(
            existing.map(\.identifier),
            sourceKeys: nil
        )
        center.removePendingNotificationRequests(withIdentifiers: existingIDs)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
