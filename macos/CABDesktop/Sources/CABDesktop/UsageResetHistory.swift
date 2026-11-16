import Foundation
import SwiftUI

enum UsageResetTrigger: String, Codable, CaseIterable {
    case manual, automatic
    var title: String { cabLocalized(self == .manual ? "手动使用" : "自动使用") }
}

struct UsageResetHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let account: String
    let target: String
    let host: String
    let trigger: UsageResetTrigger
    let requestedAt: Date
    var completedAt: Date?
    var outcome: UsageResetOutcome?
    var uncertain = false

    var resultTitle: String {
        switch outcome {
        case .reset: return cabLocalized("使用成功")
        case .alreadyRedeemed: return cabLocalized("已兑换（本次未重复使用）")
        case .nothingToReset: return cabLocalized("无需重置（未使用）")
        case .noCredit: return cabLocalized("无可用卡（未使用）")
        case nil: return cabLocalized(uncertain ? "结果未确认，请刷新额度核对" : "等待使用结果")
        }
    }
    var location: String { target == BridgeTarget.local.rawValue ? cabLocalized("这台 Mac") : host }
}

/// One entry per idempotency key, including retries after a lost response.
/// Only confirmed official responses are recorded as successful redemptions.
@MainActor
final class UsageResetHistory: ObservableObject {
    static let shared = UsageResetHistory()
    static let storageKey = "cab.usageReset.history.v1"
    @Published private(set) var entries: [UsageResetHistoryEntry]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([UsageResetHistoryEntry].self, from: $0) } ?? []
        // A terminated process cannot know whether its in-flight request succeeded.
        for index in entries.indices where entries[index].outcome == nil { entries[index].uncertain = true }
    }

    func perform(id: UUID, account: String, target: BridgeTarget, host: String,
                 trigger: UsageResetTrigger,
                 operation: () async throws -> UsageResetResult) async throws -> UsageResetResult {
        if !entries.contains(where: { $0.id == id }) {
            entries.insert(.init(id: id, account: account, target: target.rawValue,
                                 host: target == .remote ? host : "", trigger: trigger, requestedAt: Date()), at: 0)
            save()
        }
        do {
            let result = try await operation()
            guard result.account == account else {
                throw BridgeError.invalidUsage("额度重置结果与所选账号不一致。")
            }
            if let index = entries.firstIndex(where: { $0.id == id }) {
                // A retry may return alreadyRedeemed; retain an earlier confirmed success.
                if entries[index].outcome != .reset { entries[index].outcome = result.outcome }
                entries[index].completedAt = Date()
                entries[index].uncertain = false
            }
            save()
            return result
        } catch {
            if let index = entries.firstIndex(where: { $0.id == id }), entries[index].outcome == nil {
                entries[index].uncertain = true
                entries[index].completedAt = Date()
            }
            save()
            throw error
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.storageKey) }
    }
}

struct UsageResetHistoryView: View {
    @ObservedObject var history: UsageResetHistory
    @State private var visibleCount = 20

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if history.entries.isEmpty {
                    Text("暂无使用记录").foregroundStyle(.secondary)
                } else {
                    ForEach(history.entries.prefix(visibleCount)) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.account).fontWeight(.medium).textSelection(.enabled)
                                Text(entry.trigger.title).font(.caption).foregroundStyle(.secondary)
                                Spacer(minLength: 12)
                                Text(entry.requestedAt, format: .dateTime.year().month().day().hour().minute().second())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(entry.location).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Label(entry.resultTitle, systemImage: entry.outcome == .reset ? "checkmark.circle" : "info.circle")
                                .font(.caption).foregroundStyle(entry.outcome == .reset ? Color.green : Color.secondary)
                        }
                        if entry.id != history.entries.prefix(visibleCount).last?.id { Divider() }
                    }
                    if history.entries.count > visibleCount {
                        Button("显示更多") { visibleCount += 20 }.buttonStyle(.borderless)
                    }
                }
                Text("记录本机发起的手动和自动使用，重启后保留。从此版本开始记录，之前的使用无法补录。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        } label: { Label("重置卡使用记录", systemImage: "clock.arrow.circlepath") }
    }
}
