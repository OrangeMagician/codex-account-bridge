import Foundation
import SwiftUI
import UserNotifications
import CryptoKit

struct LowQuotaSettings: Codable, Equatable {
    var enabled = false
    var threshold = 10
    var fiveHour = true
    var weekly = true
    var quietEnabled = false
    var quietStartHour = 22
    var quietEndHour = 8

    func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        guard quietEnabled, quietStartHour != quietEndHour else { return false }
        let hour = calendar.component(.hour, from: date)
        return quietStartHour < quietEndHour
            ? (quietStartHour..<quietEndHour).contains(hour)
            : hour >= quietStartHour || hour < quietEndHour
    }
}

struct LowQuotaAlert: Equatable {
    let key: String
    let source: String
    let account: String
    let period: String
    let remaining: Int
    let reset: Date
}

func lowQuotaAlerts(sources: [UsageNotificationSource], settings: LowQuotaSettings, sent: [String: Date], now: Date = Date(), calendar: Calendar = .current) -> [LowQuotaAlert] {
    guard settings.enabled, !settings.isQuiet(at: now, calendar: calendar) else { return [] }
    var alerts: [LowQuotaAlert] = []
    for source in sources {
        for report in source.reports where report.error == nil {
            guard let usage = report.usage else { continue }
            let limits = usageCodexRateLimits(for: usage)
            for (kind, enabled, window) in [("5h", settings.fiveHour, limits.primary), ("周", settings.weekly, limits.secondary)] {
                guard enabled, let window, window.usedPercent.isFinite,
                      let reset = window.resetDate, reset > now else { continue }
                let remaining = max(0, min(100, 100 - window.usedPercent))
                guard remaining <= Double(max(1, min(99, settings.threshold))) else { continue }
                let raw = "\(source.key)\u{0}\(report.name)\u{0}\(kind)\u{0}\(window.resetsAt ?? 0)"
                let key = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
                guard sent[key] == nil else { continue }
                alerts.append(LowQuotaAlert(key: key, source: source.title, account: report.name, period: kind, remaining: Int(remaining), reset: reset))
            }
        }
    }
    return alerts
}

@MainActor
final class LowQuotaMonitor: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = LowQuotaMonitor()
    @Published private(set) var settings: LowQuotaSettings
    @Published private(set) var updating = false
    @Published var error: String?
    private let defaults: UserDefaults
    private var sent: [String: Date]
    private var inFlight: Set<String> = []
    private var generation = 0
    private lazy var center: UNUserNotificationCenter = {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: "lowQuotaSettings.v1").flatMap { try? JSONDecoder().decode(LowQuotaSettings.self, from: $0) } ?? LowQuotaSettings()
        sent = defaults.data(forKey: "lowQuotaSent.v1").flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        super.init()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func setEnabled(_ enabled: Bool) {
        guard !updating else { return }
        updating = true
        Task {
            defer { updating = false }
            if enabled {
                do {
                    guard try await center.requestAuthorization(options: [.alert, .sound]) else { throw UsageResetNotificationError.permissionDenied }
                    update { $0.enabled = true }; error = nil
                } catch { self.error = error.localizedDescription }
            } else {
                update { $0.enabled = false }
                let requests = await center.pendingNotificationRequests()
                center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix("cab.low-quota.") })
                error = nil
            }
        }
    }

    func update(_ mutate: (inout LowQuotaSettings) -> Void) {
        mutate(&settings)
        settings.threshold = min(99, max(1, settings.threshold))
        settings.quietStartHour = min(23, max(0, settings.quietStartHour))
        settings.quietEndHour = min(23, max(0, settings.quietEndHour))
        generation += 1
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "lowQuotaSettings.v1") }
    }

    func evaluate(_ source: UsageNotificationSource) async {
        let now = Date(), capturedGeneration = generation
        sent = sent.filter { $0.value > now }
        let alerts = lowQuotaAlerts(sources: [source], settings: settings, sent: sent, now: now)
        for alert in alerts where !inFlight.contains(alert.key) {
            guard capturedGeneration == generation, settings.enabled else { return }
            inFlight.insert(alert.key)
            defer { inFlight.remove(alert.key) }
            let content = UNMutableNotificationContent()
            content.title = cabLocalized("Codex 额度偏低")
            content.body = String(format: cabLocalized("%@ · %@ 的 %@ 额度剩余 %d%%。"), alert.source, alert.account, cabLocalized(alert.period), alert.remaining)
            content.sound = .default
            do {
                let identifier = "cab.low-quota." + alert.key
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                if capturedGeneration != generation || !settings.enabled {
                    center.removePendingNotificationRequests(withIdentifiers: [identifier])
                    center.removeDeliveredNotifications(withIdentifiers: [identifier])
                    continue
                }
                sent[alert.key] = alert.reset
                if let data = try? JSONEncoder().encode(sent) { defaults.set(data, forKey: "lowQuotaSent.v1") }
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct LowQuotaSettingsView: View {
    @ObservedObject var monitor = LowQuotaMonitor.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("低额度提醒", isOn: Binding(get: { monitor.settings.enabled }, set: monitor.setEnabled))
                .toggleStyle(.switch).disabled(monitor.updating)
            Text("每个账号的每个额度周期最多提醒一次。提醒不会切换账号或启动任务。")
                .font(.caption).foregroundStyle(.secondary)
            if monitor.settings.enabled {
                HStack {
                    Picker("剩余额度阈值", selection: Binding(get: { monitor.settings.threshold }, set: { value in monitor.update { $0.threshold = value } })) {
                        ForEach([5, 10, 20, 30], id: \.self) { Text("\($0)%").tag($0) }
                    }
                    Toggle("5 小时", isOn: Binding(get: { monitor.settings.fiveHour }, set: { value in monitor.update { $0.fiveHour = value } }))
                    Toggle("周", isOn: Binding(get: { monitor.settings.weekly }, set: { value in monitor.update { $0.weekly = value } }))
                }
                Toggle("静默时段", isOn: Binding(get: { monitor.settings.quietEnabled }, set: { value in monitor.update { $0.quietEnabled = value } }))
                if monitor.settings.quietEnabled {
                    HStack {
                        hourPicker("开始", value: monitor.settings.quietStartHour) { value in monitor.update { $0.quietStartHour = value } }
                        hourPicker("结束", value: monitor.settings.quietEndHour) { value in monitor.update { $0.quietEndHour = value } }
                    }
                    Text("按本机时区生效；跨午夜时段也受支持。静默结束后在下一次额度刷新时检查。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = monitor.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }
    }
    private func hourPicker(_ title: LocalizedStringKey, value: Int, set: @escaping (Int) -> Void) -> some View {
        Picker(title, selection: Binding(get: { value }, set: set)) {
            ForEach(0..<24) { hour in Text(String(format: "%02d:00", hour)).tag(hour) }
        }
    }
}
