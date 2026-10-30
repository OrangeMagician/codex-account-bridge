import SwiftUI

struct PublicResetSettingsView: View {
    @ObservedObject var monitor = PublicResetMonitor.shared
    var performsLiveChecks = true
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("Codex 全局重置提醒", systemImage: "globe.badge.chevron.backward")
                Spacer()
                if monitor.updating || monitor.checking { ProgressView().controlSize(.small) }
                Toggle("Codex 全局重置提醒", isOn: Binding(get: { monitor.enabled }, set: monitor.setEnabled))
                    .labelsHidden().toggleStyle(.switch).disabled(monitor.updating)
            }
            Text("开启后每 5 分钟检查公开公告，区分全局重置与重置卡发放。首次检查只展示现有消息，不补发历史通知。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("概览显示今日重置状态；关闭提醒后只在概览页检查，不发送通知。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if monitor.enabled {
                if let snapshot = monitor.snapshot {
                    if let latest = snapshot.records.filter({ $0.resetType != "banked" }).max(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) {
                        Text(cabLocalized(publicResetOccurredToday(latest)
                                          ? "今天检测到全局重置公告" : "今天暂无全局重置公告"))
                            .font(.callout)
                        if !publicResetOccurredToday(latest) {
                            Text("最近全局重置公告").font(.caption).foregroundStyle(.secondary)
                        }
                        recordDetails(latest)
                    } else {
                        Text("当前记录中暂无已完成全局重置信号。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let banked = snapshot.records.filter({ $0.resetType != "global" }).max(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }) {
                        Text("最近重置卡公告").font(.callout)
                        recordDetails(banked)
                    }
                    Text("数据更新时间：\(snapshot.generatedAt.formatted(.dateTime.year().month().day().hour().minute().locale(locale)))")
                        .font(.caption).foregroundStyle(.secondary)
                } else if monitor.checking {
                    Text("正在检查公开重置信号…").font(.caption).foregroundStyle(.secondary)
                }
                if let error = monitor.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else if let error = monitor.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            Link("来源：Did Codex Reset（非官方）", destination: URL(string: locale.language.languageCode?.identifier == "zh"
                     ? "https://didcodexreset.com/zh.html" : "https://didcodexreset.com/")!)
                .font(.caption)
            Text("公开信号仅供参考，不代表你的账号额度已恢复。应用退出后停止检查。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task { if performsLiveChecks { monitor.startMonitoring() } }
    }

    private func recordDetails(_ record: PublicResetRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let date = record.date {
                Text(date.formatted(.dateTime.year().month().day().hour().minute().locale(locale)))
            } else { Text("时间未知") }
            Text(record.plans)
            if let confidence = record.confidence, confidence.isFinite, (0...1).contains(confidence) {
                Text("置信度：\(Int(confidence * 100))%")
            }
            if let url = record.sourceURL { Link("查看来源公告", destination: url).foregroundStyle(.tint) }
        }.font(.caption).foregroundStyle(.secondary)
    }
}
