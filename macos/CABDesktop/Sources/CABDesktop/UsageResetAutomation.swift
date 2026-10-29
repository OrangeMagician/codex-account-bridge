import Foundation
import SwiftUI

func expiringUsageResetCredits(report: AccountUsageReport, now: Date) -> [UsageResetCredit] {
    guard report.error == nil, let credits = report.usage?.resetCredits,
          credits.availableCount > 0 else { return [] }
    return (credits.credits ?? []).filter {
        guard $0.isAvailable, let id = $0.creditID, !id.isEmpty,
              let expires = $0.expiresAt else { return false }
        let remaining = TimeInterval(expires) - now.timeIntervalSince1970
        return remaining > 0 && remaining <= 600
    }.sorted {
        if $0.expiresAt != $1.expiresAt { return ($0.expiresAt ?? 0) < ($1.expiresAt ?? 0) }
        return $0.id < $1.id
    }
}

/// Only official, explicitly identified credits are redeemed. Uncertain requests
/// remain in UsageResetAttempts for manual reconciliation with the original key.
@MainActor
final class UsageResetAutomation: ObservableObject {
    static let enabledKey = "usageResetAutomation.enabled.v1"
    private static let completedKey = "usageResetAutomation.completed.v1"
    @Published private(set) var enabled: Bool
    @Published private(set) var lastResult: String?
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private var completed: [String: Date]
    private var nextCheck: [String: Date] = [:]
    private var checking = false
    private var generation = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.enabledKey) == nil || defaults.bool(forKey: Self.enabledKey)
        completed = defaults.data(forKey: Self.completedKey)
            .flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        generation += 1
        nextCheck.removeAll()
    }

    func tick(
        endpoints: [UsageWakeEndpoint],
        now: () -> Date = Date.init,
        allowed: () -> Bool,
        loadAccounts: (UsageWakeEndpoint) async throws -> [String],
        loadUsage: (UsageWakeEndpoint, [String]) async throws -> [AccountUsageReport],
        reset: (UsageWakeEndpoint, String, String, UUID) async throws -> UsageResetResult,
        cache: (UsageWakeEndpoint, [AccountUsageReport]) -> Void
    ) async {
        guard enabled, !checking, allowed() else { return }
        checking = true
        defer { checking = false }
        let capturedGeneration = generation
        completed = completed.filter { $0.value > now() }
        for endpoint in endpoints {
            guard enabled, generation == capturedGeneration, allowed(), !Task.isCancelled else { return }
            if let next = nextCheck[endpoint.key], next > now() { continue }
            // Read failures retry in a minute; successful discovery runs at least
            // every five minutes, with an exact earlier check for known expiries.
            nextCheck[endpoint.key] = now().addingTimeInterval(60)
            do {
                let accounts = try await loadAccounts(endpoint)
                guard !accounts.isEmpty else {
                    nextCheck[endpoint.key] = now().addingTimeInterval(300)
                    continue
                }
                let reports = try await loadUsage(endpoint, accounts)
                cache(endpoint, reports)
                guard enabled, generation == capturedGeneration, allowed(), !Task.isCancelled else { return }
                let checkedAt = now()
                var next = checkedAt.addingTimeInterval(reports.contains { $0.error != nil } ? 60 : 300)
                for report in reports where accounts.contains(report.name) && report.error == nil {
                    for credit in report.usage?.resetCredits?.credits ?? [] where credit.isAvailable {
                        guard let expires = credit.expiresAt, TimeInterval(expires) > checkedAt.timeIntervalSince1970 else { continue }
                        next = min(next, max(checkedAt.addingTimeInterval(30), Date(timeIntervalSince1970: TimeInterval(expires) - 600)))
                    }
                }
                nextCheck[endpoint.key] = next
                // At most one card per account per tick. The next card is checked
                // against a new official snapshot on the following tick.
                let candidates = reports.compactMap { report -> (String, UsageResetCredit)? in
                    guard accounts.contains(report.name), let credit = expiringUsageResetCredits(report: report, now: now()).first(where: {
                        completed[completionKey(endpoint.key, report.name, $0.id)] == nil
                    }) else { return nil }
                    return (report.name, credit)
                }.sorted { ($0.1.expiresAt ?? 0) < ($1.1.expiresAt ?? 0) }
                for (account, credit) in candidates {
                    guard enabled, generation == capturedGeneration, allowed(), !Task.isCancelled else { return }
                    guard let creditID = credit.creditID, let expires = credit.expiresAt,
                          TimeInterval(expires) > now().timeIntervalSince1970 else { continue }
                    let attempts = UsageResetAttempts(defaults: defaults)
                    do {
                        guard !attempts.hasPending(scope: endpoint.key, account: account) else {
                            throw BridgeError.commandFailed(cabLocalized("上次重置结果尚未确认，请重试原来的重置卡，暂勿选择其他卡。"))
                        }
                        let attempt = try attempts.begin(scope: endpoint.key, account: account, creditID: creditID)
                        let result = try await reset(endpoint, account, creditID, attempt.id)
                        guard result.account == account else { throw BridgeError.invalidUsage("额度重置结果与所选账号不一致。") }
                        attempts.complete(scope: endpoint.key, account: account)
                        if result.outcome != .nothingToReset {
                            completed[completionKey(endpoint.key, account, creditID)] = Date(timeIntervalSince1970: TimeInterval(expires))
                            defaults.set(try JSONEncoder().encode(completed), forKey: Self.completedKey)
                        } else {
                            nextCheck[endpoint.key] = now().addingTimeInterval(60)
                        }
                        lastResult = "\(endpoint.host.isEmpty ? cabLocalized("这台 Mac") : endpoint.host) · \(account)：\(resultMessage(result.outcome))"
                        error = nil
                        // Reading after a confirmed response never repeats a mutation.
                        let updated = try await loadUsage(endpoint, [account])
                        cache(endpoint, updated)
                    } catch {
                        self.error = "\(endpoint.host.isEmpty ? cabLocalized("这台 Mac") : endpoint.host) · \(account)：\(error.localizedDescription)"
                    }
                }
            } catch {
                self.error = "\(endpoint.host.isEmpty ? cabLocalized("这台 Mac") : endpoint.host)：\(error.localizedDescription)"
            }
        }
    }

    private func completionKey(_ scope: String, _ account: String, _ credit: String) -> String {
        [scope, account, credit].map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
    }

    private func resultMessage(_ outcome: UsageResetOutcome) -> String {
        switch outcome {
        case .reset: return cabLocalized("已自动使用临期重置卡")
        case .alreadyRedeemed: return cabLocalized("此重置卡已使用")
        case .nothingToReset: return cabLocalized("官方返回当前无需重置，未消耗卡片")
        case .noCredit: return cabLocalized("没有可用重置次数")
        }
    }
}

struct UsageResetAutomationSettingsView: View {
    @ObservedObject var automation: UsageResetAutomation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("临期重置卡自动使用", systemImage: "clock.arrow.circlepath")
                Spacer()
                Toggle("临期重置卡自动使用", isOn: Binding(get: { automation.enabled }, set: automation.setEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Text("默认开启。重置卡到期前 10 分钟内，无论剩余额度多少，直接使用，不再确认。适用于本机及已配置的远程账号。")
                .font(.caption).foregroundStyle(.secondary)
            Text("仅在 CAB 运行且设备唤醒、服务可连接时执行；不受刷新间隔和暂停自动刷新时段影响。")
                .font(.caption).foregroundStyle(.secondary)
            if let result = automation.lastResult {
                Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let error = automation.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }
}
