import AppKit
import SwiftUI

// A single template image keeps both rows inside the macOS status bar's height
// and lets the system handle light/dark appearance and selected-item contrast.
@MainActor
func menuBarLabelImage(snapshot: MenuBarSnapshot, preferences: MenuBarPreferences) -> NSImage {
    let periods = snapshot.periods
    var lines: [String] = []
    if preferences.showsFiveHour { lines.append("5h \(menuBarPercent(periods.fiveHour))") }
    if preferences.showsWeekly { lines.append("\(cabLocalized("周")) \(menuBarPercent(periods.weekly))") }
    let stacked = preferences.layout == .stacked
    let font = NSFont.monospacedDigitSystemFont(ofSize: stacked ? 9 : 11, weight: .medium)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    if !stacked { lines = [lines.joined(separator: "  ·  ")] }
    let account = preferences.showsAccount && preferences.layout != .icon ? String((snapshot.account?.name ?? "CAB").prefix(10)) : ""
    let accountAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.black]
    let accountWidth = account.isEmpty ? 0 : ceil((account as NSString).size(withAttributes: accountAttributes).width) + 8
    let textWidth = preferences.layout == .icon ? 0 : (lines.map { ceil(($0 as NSString).size(withAttributes: attributes).width) }.max() ?? 0) + 7
    let warning = snapshot.error != nil || snapshot.unavailableReason != nil || snapshot.hasExpiredWindow
    let image = NSImage(size: NSSize(width: 18 + accountWidth + textWidth + (warning ? 8 : 0), height: 22), flipped: false) { _ in
        let icon = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
        icon?.draw(in: NSRect(x: 0, y: 3, width: 16, height: 16))
        if !account.isEmpty {
            (account as NSString).draw(at: NSPoint(x: 22, y: 4), withAttributes: accountAttributes)
        }
        if preferences.layout != .icon {
            for (index, line) in lines.enumerated() {
                let y: CGFloat = stacked && lines.count > 1 ? (index == 0 ? 11 : 0) : 4
                (line as NSString).draw(at: NSPoint(x: 20 + accountWidth, y: y), withAttributes: attributes)
            }
        }
        if warning {
            ("!" as NSString).draw(at: NSPoint(x: 18 + accountWidth + textWidth, y: 4), withAttributes: accountAttributes)
        }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "\(snapshot.sourceTitle) · \(snapshot.account?.name ?? "CAB") · 5h \(menuBarPercent(periods.fiveHour)) · \(cabLocalized("周")) \(menuBarPercent(periods.weekly))"
    return image
}

struct MenuBarUsageLabel: View {
    @ObservedObject var model: MenuBarUsageStore
    var body: some View {
        Image(nsImage: menuBarLabelImage(snapshot: model.snapshot, preferences: model.preferences))
    }
}

struct MenuBarUsagePanel: View {
    @ObservedObject var model: MenuBarUsageStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.locale) private var locale
    @State private var customizes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.snapshot.account?.name ?? "CAB")
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(model.snapshot.sourceTitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isRefreshing)
                .help("刷新额度")
                .accessibilityLabel("刷新额度")
            }

            if let reason = model.snapshot.unavailableReason {
                Label(reason, systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 14) {
                MenuBarQuotaRow(title: "5 小时额度", value: model.snapshot.periods.fiveHour)
                MenuBarQuotaRow(title: "周额度", value: model.snapshot.periods.weekly)
            }

            VStack(alignment: .leading, spacing: 4) {
                if model.snapshot.hasExpiredWindow {
                    Text("额度周期已重置，等待刷新")
                }
                if let error = model.snapshot.error {
                    Label(model.snapshot.usage == nil ? cabLocalized("暂时无法获取额度") : error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if model.isRefreshing {
                    Text("正在刷新…")
                } else if let date = model.snapshot.fetchedAt {
                    // Keep menu content static between data updates; no live relative Text.
                    Text("更新于 \(date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(locale)))")
                } else {
                    Text("尚未获取额度")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            DisclosureGroup("自定义状态栏", isExpanded: $customizes) {
                MenuBarPreferencesView(model: model)
                    .padding(.top, 12)
            }
            .font(.callout)
            Divider()
            HStack {
                Button("打开 CAB Desktop") {
                    openWindow(id: "cab-main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Menu {
                    Button("在终端启动") {
                        model.launchCurrentAccount()
                    }
                    .disabled(model.snapshot.account?.isLoggedIn != true)
                    Divider()
                    Button("退出") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("更多操作")
                .accessibilityLabel("更多操作")
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(20)
        .frame(width: 320)
        .cabPreservingActiveColors()
        .task { await model.refresh(force: false) }
    }
}

private struct MenuBarQuotaRow: View {
    let title: LocalizedStringKey
    let value: UsagePeriodDisplayValue
    @Environment(\.locale) private var locale

    private var tint: Color {
        guard let remaining = value.remainingPercent else { return .secondary }
        return remaining <= 10 ? .red : remaining <= 25 ? .orange : .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text("剩余").font(.caption).foregroundStyle(.secondary)
                Text(menuBarPercent(value)).font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
            }
            ProgressView(value: value.remainingPercent ?? 0, total: 100)
                .tint(tint)
                .accessibilityLabel(title)
                .accessibilityValue(menuBarPercent(value))
            if case let .measured(window) = value, let date = window.resetDate {
                Text("重置于 \(date.formatted(Date.FormatStyle().month().day().hour().minute().locale(locale)))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(value == .unlimited ? "无限制" : "官方接口暂未返回")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct MenuBarPreferencesView: View {
    @ObservedObject var model: MenuBarUsageStore

    private func binding<T>(_ keyPath: WritableKeyPath<MenuBarPreferences, T>) -> Binding<T> {
        Binding(get: { model.preferences[keyPath: keyPath] }, set: { value in
            model.updatePreferences { $0[keyPath: keyPath] = value }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("显示样式").font(.caption).foregroundStyle(.secondary)
                Picker("显示样式", selection: binding(\.layout)) {
                    ForEach(MenuBarLayout.allCases) { layout in Text(layout.title).tag(layout) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            Toggle("显示账号名", isOn: binding(\.showsAccount))
                .disabled(model.preferences.layout == .icon)
            HStack(spacing: 16) {
                Toggle("5 小时额度", isOn: binding(\.showsFiveHour))
                    .disabled(!model.preferences.showsWeekly)
                Toggle("周额度", isOn: binding(\.showsWeekly))
                    .disabled(!model.preferences.showsFiveHour)
            }
            .disabled(model.preferences.layout == .icon)
            Text("始终显示本机账号的剩余额度，刷新频率跟随额度设置。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
    }
}
