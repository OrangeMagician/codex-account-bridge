import SwiftUI

struct TokenActivityDay: Identifiable {
    let date: Date
    let tokens: Int64
    let threads: Int64
    let isFuture: Bool
    var id: String { TokenActivityData.key(date) }
}

struct TokenActivityData {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 1
        return calendar
    }

    static func key(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let value = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        return value.flatMap { self.key($0) == key ? $0 : nil }
    }

    static func days(_ report: TokenUsageReport, now: Date = Date()) -> [TokenActivityDay] {
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let start = calendar.date(byAdding: .day, value: -(weekday - 1) - 364, to: today)!
        // Tolerate duplicate day rows from older servers without crashing the UI.
        let values = Dictionary(grouping: report.daily, by: \.date)
        return (0..<371).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            let rows = values[key(day), default: []]
            return TokenActivityDay(date: day, tokens: rows.reduce(0) { $0 + $1.tokens },
                                    threads: rows.reduce(0) { $0 + $1.threads }, isFuture: day > today)
        }
    }

    static func level(_ value: Int64, maximum: Int64) -> Int {
        guard value > 0 else { return 0 }
        // Square-root scaling keeps modest active days visible beside large days.
        return min(4, max(1, Int(ceil(sqrt(Double(value) / Double(max(maximum, 1))) * 4))))
    }

    static func formatted(_ value: Int64) -> String {
        if value >= 1_000_000_000 { return String(format: "%.2fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return value.formatted()
    }
}

private enum TokenActivityMode: String, CaseIterable {
    case daily = "每日", weekly = "每周", total = "累计"
}

struct TokenUsageDetails: View {
    let report: TokenUsageReport
    @State private var mode: TokenActivityMode = .daily
    @State private var selectedDay: String?
    @State private var hoveredDay: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading, spacing: 12) {
                metric("累计 Token", value: TokenActivityData.formatted(report.totalTokens), exact: report.totalTokens)
                metric("峰值日", value: TokenActivityData.formatted(report.maxDailyTokens), exact: report.maxDailyTokens)
                metric("活跃天数", value: String(report.activeDays))
                metric("当前连续", value: String(report.currentStreak))
                metric("最长连续", value: String(report.longestStreak))
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            if let input = report.inputTokens, let cached = report.cachedInputTokens, let output = report.outputTokens {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 10) {
                    metric("输入（不含缓存）", value: TokenActivityData.formatted(max(0, input - cached)), exact: max(0, input - cached))
                    metric("缓存输入", value: TokenActivityData.formatted(cached), exact: cached)
                    metric("输出", value: TokenActivityData.formatted(output), exact: output)
                }
            }
            HStack {
                Text("Token 活动").font(.headline)
                Spacer()
                Picker("Token 活动范围", selection: $mode) {
                    ForEach(TokenActivityMode.allCases, id: \.self) { mode in
                        Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            switch mode {
            case .daily: heatmap
            case .weekly: weeklyChart
            case .total:
                Text("已记录 \(report.threadCount) 个 Codex 会话")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if report.source == "session_events" {
                Text("按实际记录日期统计（UTC）；总量含缓存输入，输出已含推理 Token。")
                    .font(.caption).foregroundStyle(.secondary)
                if (report.unavailableThreads ?? 0) > 0 || (report.incompleteFiles ?? 0) > 0 {
                    Label("部分会话缺少完整 Token 记录，统计仅包含可读取的用量。", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .help(String(format: cabLocalized("缺少记录的会话：%d；不完整文件：%d"), report.unavailableThreads ?? 0, report.incompleteFiles ?? 0))
                }
            } else {
                Label("当前为旧版索引估算，请更新目标端 CAB 后刷新。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func metric(_ title: LocalizedStringKey, value: String, exact: Int64? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().help(exact.map { "\($0.formatted()) Token" } ?? value)
        }
    }

    private func color(_ level: Int) -> Color {
        level == 0 ? Color.secondary.opacity(0.12) : Color.accentColor.opacity([0, 0.35, 0.55, 0.75, 1][level])
    }

    private var heatmap: some View {
        let days = TokenActivityData.days(report)
        let maximum = days.map(\.tokens).max() ?? 1
        let selected: TokenActivityDay = days.first(where: { $0.id == (hoveredDay ?? selectedDay) })
            ?? days.last(where: { !$0.isFuture && $0.tokens > 0 })
            ?? days.last(where: { !$0.isFuture })!
        return VStack(alignment: .leading, spacing: 8) {
            heatmapGrid(days: days, maximum: maximum, selected: selected.id)

            HStack(alignment: .firstTextBaseline) {
                Text("\(days[0].id) – \(days.last { !$0.isFuture }!.id)")
                Spacer()
                Text("少")
                ForEach(0..<5) { level in
                    RoundedRectangle(cornerRadius: 2).fill(color(level)).frame(width: 10, height: 10)
                }
                Text("多")
            }
            .font(.caption2).foregroundStyle(.secondary)
            Text(detail(selected)).font(.caption).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
            if report.daily.isEmpty {
                Text("尚无已记录的会话 Token。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func heatmapGrid(days: [TokenActivityDay], maximum: Int64, selected: String) -> some View {
        Color.clear.aspectRatio(53.0 / 7.0, contentMode: .fit)
            .overlay(alignment: .topLeading) {
        GeometryReader { geometry in
            let cell = max(1, (geometry.size.width - 28 - 52 * 3) / 53)
            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: 3) {
                    Color.clear.frame(height: 16)
                    ForEach(0..<7) { weekday in
                        Text(LocalizedStringKey(weekday == 1 ? "一" : weekday == 3 ? "三" : weekday == 5 ? "五" : ""))
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize().opacity(cell >= 7 ? 1 : 0)
                            .frame(width: 22, height: cell)
                    }
                }
                HStack(alignment: .top, spacing: 3) {
                    ForEach(0..<53) { week in
                        heatmapColumn(Array(days[(week * 7)..<(week * 7 + 7)]), cell: cell, maximum: maximum, selected: selected)
                    }
                }
            }
        }
            }.padding(.bottom, 13)
    }

    private func heatmapColumn(_ days: [TokenActivityDay], cell: CGFloat, maximum: Int64, selected: String) -> some View {
        let start = days[0].date
        let monthStart = TokenActivityData.calendar.component(.day, from: start) <= 7
        return VStack(spacing: 3) {
            Text(monthStart ? String(TokenActivityData.calendar.component(.month, from: start)) : "")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize()
                .frame(width: cell, height: 16, alignment: .leading)
            ForEach(days) { day in
                Button { selectedDay = day.id } label: {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(day.isFuture ? Color.clear : color(TokenActivityData.level(day.tokens, maximum: maximum)))
                        .overlay {
                            if day.id == selected {
                                RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary.opacity(0.7), lineWidth: 1)
                            }
                        }
                        .frame(width: cell, height: cell)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(day.isFuture)
                .help(detail(day))
                .accessibilityLabel(detail(day))
                .onHover { inside in hoveredDay = inside ? day.id : nil }
            }
        }
    }

    private func detail(_ day: TokenActivityDay) -> String {
        String(format: cabLocalized("%@ · %@ Token · %lld 个会话"), day.id, day.tokens.formatted(), day.threads)
    }

    private var weeklyChart: some View {
        let calendar = TokenActivityData.calendar
        let current = calendar.dateInterval(of: .weekOfYear, for: Date())!.start
        let weeks = (0..<12).map { calendar.date(byAdding: .weekOfYear, value: $0 - 11, to: current)! }
        let grouped = Dictionary(grouping: report.daily) { day in
            TokenActivityData.date(day.date).flatMap { calendar.dateInterval(of: .weekOfYear, for: $0)?.start } ?? .distantPast
        }
        let values = weeks.map { week in grouped[week, default: []].reduce(Int64(0)) { $0 + $1.tokens } }
        let maximum = max(values.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.accentColor)
                        .frame(height: max(2, CGFloat(values[index]) / CGFloat(maximum) * 100))
                    Text(String(TokenActivityData.key(week).suffix(5))).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .help("\(TokenActivityData.key(week)) · \(values[index].formatted()) Token")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(TokenActivityData.key(week)) · \(values[index].formatted()) Token")
            }
        }
        .frame(height: 130, alignment: .bottom)
    }
}
