import SwiftUI

enum PublicResetTodayStatus: Equatable {
    case occurred, none, checking, unknown

    var title: String {
        switch self {
        case .occurred: return "今日有重置"
        case .none: return "今日暂无重置"
        case .checking: return "正在检查"
        case .unknown: return "暂时无法确认"
        }
    }

    var icon: String {
        switch self {
        case .occurred: return "checkmark.circle.fill"
        case .none: return "clock"
        case .checking: return "arrow.clockwise"
        case .unknown: return "questionmark.circle"
        }
    }
}

func publicResetTodayStatus(snapshot: PublicResetSnapshot?, checking: Bool, error: String?, now: Date = Date(), calendar: Calendar = .current) -> PublicResetTodayStatus {
    guard let snapshot, snapshot.isFresh(at: now), calendar.isDate(snapshot.generatedAt, inSameDayAs: now), error == nil else {
        return checking ? .checking : .unknown
    }
    return snapshot.records.contains {
        $0.isCompleted && $0.resetType != "banked" && ($0.date.map { $0 <= now } ?? false)
            && publicResetOccurredToday($0, now: now, calendar: calendar)
    } ? .occurred : .none
}

struct PublicResetOverviewCard: View {
    @ObservedObject var monitor: PublicResetMonitor
    var performsLiveChecks = true

    var body: some View {
        GroupBox {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let status = publicResetTodayStatus(snapshot: monitor.snapshot, checking: monitor.checking, error: monitor.error, now: context.date)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) {
                        statusLabel(status)
                        Spacer()
                        reminderToggle
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        statusLabel(status)
                        reminderToggle
                    }
                }
            }
            .padding(8)
        } label: { Label("今日重置", systemImage: "arrow.counterclockwise.circle") }
        .task {
            guard performsLiveChecks else { return }
            // With notifications disabled, reads only run while this card is visible.
            while !Task.isCancelled {
                await monitor.checkForDisplay()
                do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                catch { return }
            }
        }
    }

    private func statusLabel(_ status: PublicResetTodayStatus) -> some View {
        Label(cabLocalized(status.title), systemImage: status.icon)
            .font(.title3.weight(.semibold))
            .foregroundStyle(status == .occurred ? Color.green : Color.primary)
            .help("按本机日期显示公开全局重置公告；不代表具体账号额度已恢复。")
    }

    private var reminderToggle: some View {
        Toggle("重置提醒", isOn: Binding(get: { monitor.enabled }, set: monitor.setEnabled))
            .toggleStyle(.switch).fixedSize().disabled(monitor.updating)
            .help("检测到新的公开重置公告时发送通知。")
    }
}
