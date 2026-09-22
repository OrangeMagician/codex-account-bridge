import SwiftUI

struct SystemSettingsView: View {
    @EnvironmentObject private var store: CABStore
    @EnvironmentObject private var menuBar: MenuBarUsageStore
    @State private var pendingUsageWakeEnable = false
    @State private var usageWakeExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("系统设置", systemImage: "gearshape")
                    .font(.title2.bold())

                GroupBox {
                    HStack {
                        Label("界面语言", systemImage: "globe")
                        Spacer()
                        Picker("界面语言", selection: Binding(
                            get: { store.interfaceLanguage },
                            set: store.setInterfaceLanguage
                        )) {
                            ForEach(InterfaceLanguage.allCases) { language in
                                Text(language.title).tag(language)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    .padding(8)
                } label: {
                    Text("通用")
                }

                GroupBox {
                    MenuBarPreferencesView(model: menuBar).padding(8)
                } label: {
                    Label("状态栏", systemImage: "menubar.rectangle")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("自动刷新额度", systemImage: "arrow.clockwise")
                            Spacer()
                            Picker("刷新间隔", selection: Binding(
                                get: { store.usageRefreshInterval },
                                set: store.setUsageRefreshInterval
                            )) {
                                ForEach(UsageRefreshInterval.allCases) { interval in
                                    Text(interval.title).tag(interval)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }

                        Divider()

                        HStack(spacing: 10) {
                            Label("额度重置通知", systemImage: "bell.badge")
                            if let error = store.usageResetNotificationError {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help(error)
                                    .accessibilityLabel(error)
                            } else if store.usageResetNotificationsEnabled && store.scheduledUsageResetNotificationCount > 0 {
                                Text("\(store.scheduledUsageResetNotificationCount) \(cabLocalized("个已安排"))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.isUsageResetNotificationUpdating {
                                ProgressView().controlSize(.small)
                            }
                            Toggle("额度重置通知", isOn: Binding(
                                get: { store.usageResetNotificationsEnabled },
                                set: store.setUsageResetNotificationsEnabled
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(store.isUsageResetNotificationUpdating)
                            .help("在官方额度周期到达重置时间时发送 macOS 通知")
                        }

                        Divider()

                        LowQuotaSettingsView()
                        Divider()

                        UsageWakeControlsView(
                            pendingEnable: $pendingUsageWakeEnable,
                            isExpanded: $usageWakeExpanded
                        )
                    }
                    .padding(8)
                } label: {
                    Text("额度与通知")
                }
            }
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 500)
    }
}

private struct UsageWakeControlsView: View {
    @EnvironmentObject private var store: CABStore
    @Binding var pendingEnable: Bool
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .frame(width: 12)
                        Label("额度周期唤醒", systemImage: "bolt.horizontal.circle")
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if store.usageWakeSettings.enabled {
                    Text(cabLocalized("已开启"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.green.opacity(0.12), in: Capsule())
                }
                Toggle("额度周期唤醒", isOn: Binding(
                    get: { store.usageWakeSettings.enabled },
                    set: { enabled in
                        if enabled {
                            pendingEnable = true
                        } else {
                            store.setUsageWakeEnabled(false)
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            if isExpanded {
                details
            }
        }
        .confirmationDialog("启用额度周期唤醒？", isPresented: $pendingEnable, titleVisibility: .visible) {
            Button("确认启用") {
                store.setUsageWakeEnabled(true)
                pendingEnable = false
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("启用后，CAB 会在额度恢复或你设置的时间先查询额度。只有五小时或周周期尚未开始倒计时时，才向官方 Codex 发送一次极小的真实请求。")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("只发送最低消耗的官方 Codex 请求；普通额度查询不会消耗 Token。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("额度恢复后启动周期", isOn: Binding(
                get: { store.usageWakeSettings.wakeOnRecovery },
                set: store.setUsageWakeRecoveryEnabled
            ))

            HStack {
                Text("周期启动时间").fontWeight(.medium)
                Spacer()
                Button {
                    store.addUsageWakeProbeTime()
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(store.usageWakeSettings.weeklyProbeTimes.count >= usageWakeMaximumEntries)
            }
            ForEach(Array(store.usageWakeSettings.weeklyProbeTimes.enumerated()), id: \.offset) { index, time in
                HStack {
                    DatePicker(
                        "时间 \(index + 1)",
                        selection: probeDateBinding(index: index),
                        displayedComponents: .hourAndMinute
                    )
                    Spacer()
                    Button(role: .destructive) {
                        store.removeUsageWakeProbeTime(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("删除时间 \(time.id)")
                }
            }

            HStack {
                Text("暂停自动刷新时段").fontWeight(.medium)
                Spacer()
                Button {
                    store.addUsageWakeQuietPeriod()
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(store.usageWakeSettings.quietPeriods.count >= usageWakeMaximumEntries)
            }
            ForEach(Array(store.usageWakeSettings.quietPeriods.enumerated()), id: \.offset) { index, period in
                HStack(spacing: 8) {
                    DatePicker(
                        "开始",
                        selection: quietStartDateBinding(index: index),
                        displayedComponents: .hourAndMinute
                    )
                    Text("至").foregroundStyle(.secondary)
                    DatePicker(
                        "结束",
                        selection: quietEndDateBinding(index: index),
                        displayedComponents: .hourAndMinute
                    )
                    Spacer()
                    Button(role: .destructive) {
                        store.removeUsageWakeQuietPeriod(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("删除暂停时段 \(period.id)")
                }
            }

            Text("设定时间会优先执行；到点仅在五小时或周周期没有倒计时时发送一次。其他自动刷新在暂停时段内不运行。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    private func probeDateBinding(index: Int) -> Binding<Date> {
        Binding(
            get: {
                guard store.usageWakeSettings.weeklyProbeTimes.indices.contains(index) else { return Date() }
                return store.usageWakeDate(for: store.usageWakeSettings.weeklyProbeTimes[index])
            },
            set: { store.setUsageWakeProbeTime(at: index, date: $0) }
        )
    }

    private func quietStartDateBinding(index: Int) -> Binding<Date> {
        Binding(
            get: {
                guard store.usageWakeSettings.quietPeriods.indices.contains(index) else { return Date() }
                return store.usageWakeDate(for: store.usageWakeSettings.quietPeriods[index].start)
            },
            set: { store.setUsageWakeQuietStart(at: index, date: $0) }
        )
    }

    private func quietEndDateBinding(index: Int) -> Binding<Date> {
        Binding(
            get: {
                guard store.usageWakeSettings.quietPeriods.indices.contains(index) else { return Date() }
                return store.usageWakeDate(for: store.usageWakeSettings.quietPeriods[index].end)
            },
            set: { store.setUsageWakeQuietEnd(at: index, date: $0) }
        )
    }
}
