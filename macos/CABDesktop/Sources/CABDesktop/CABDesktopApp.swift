import SwiftUI

@main
struct CABDesktopApp: App {
    @StateObject private var store = CABStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .cabPreservingActiveColors()
        }
        .windowStyle(.titleBar)
        .commands {
            CABCommands(store: store)
        }

        Settings {
            SystemSettingsView()
                .environmentObject(store)
                .environment(\.locale, Locale(identifier: store.interfaceLanguage.localeIdentifier))
                .cabPreservingActiveColors()
        }

        MenuBarExtra("app.name", systemImage: "person.2.circle") {
            CABMenuBarView(store: store)
        }
        .environment(\.locale, Locale(identifier: store.interfaceLanguage.localeIdentifier))
    }
}

extension View {
    @ViewBuilder
    func cabPreservingActiveColors() -> some View {
        if #available(macOS 15.0, *) {
            environment(\.appearsActive, true)
        } else {
            environment(\.controlActiveState, .active)
        }
    }
}

private struct CABMenuBarView: View {
    @ObservedObject var store: CABStore

    var body: some View {
        Button("打开 CAB Desktop") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        Divider()
        Label(store.targetTitle, systemImage: store.target.icon)
        if store.status.accounts.isEmpty {
            Text("尚未添加账号")
        } else {
            ForEach(store.status.accounts) { account in
                Button {
                    store.launchCodex(account: account.name)
                } label: {
                    Label(menuAccountTitle(account, store: store), systemImage: account.isLoggedIn ? "terminal" : "person.crop.circle.badge.exclamationmark")
                }
                .disabled(!account.isLoggedIn || store.isBusy)
            }
        }
        Divider()
        Button("刷新额度") { store.refreshUsage() }
            .disabled(store.isUsageRefreshing)
        if let fetchedAt = store.usageFetchedAt {
            Text("更新于 \(fetchedAt, style: .relative)")
        }
        Text(cabLocalized(store.status.rotation.enabled ? "轮换：已开启" : "轮换：已关闭"))
        Divider()
        Button("退出") { NSApp.terminate(nil) }
    }
}

private struct CABCommands: Commands {
    @ObservedObject var store: CABStore

    var body: some Commands {
        CommandMenu("操作") {
            Button("刷新") { store.refresh() }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(store.isBusy)
            Button("刷新额度") { store.refreshUsage() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.isUsageRefreshing)
            Divider()
            Button("在终端启动") { store.launchCodex() }
                .keyboardShortcut(.return, modifiers: [.command])
        }
    }
}

@MainActor
private func menuAccountTitle(_ account: AccountStatus, store: CABStore) -> String {
    var parts = [account.name]
    if account.default { parts.append(cabLocalized("默认")) }
    if let usage = store.usage(for: account.name)?.usage {
        let periods = usagePeriodDisplays(for: usage)
        parts.append("5h \(menuPercent(periods.fiveHour))")
        parts.append("\(cabLocalized("周")) \(menuPercent(periods.weekly))")
    } else if !account.isLoggedIn {
        parts.append(cabLocalized("未登录"))
    }
    return parts.joined(separator: " · ")
}

private func menuPercent(_ value: UsagePeriodDisplayValue) -> String {
    guard let remaining = value.remainingPercent else { return "—" }
    return "\(Int(remaining.rounded()))%"
}
