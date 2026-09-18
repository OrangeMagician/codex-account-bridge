import SwiftUI

@main
struct CABDesktopApp: App {
    @StateObject private var store = CABStore()
    @StateObject private var menuBar = MenuBarUsageStore()

    var body: some Scene {
        WindowGroup(id: "cab-main") {
            ContentView()
                .environmentObject(store)
                .cabPreservingActiveColors()
                .task { menuBar.startMonitoring() }
        }
        .windowStyle(.titleBar)
        .commands {
            CABCommands(store: store)
        }

        Settings {
            SystemSettingsView()
                .environmentObject(store)
                .environmentObject(menuBar)
                .environment(\.locale, Locale(identifier: store.interfaceLanguage.localeIdentifier))
                .cabPreservingActiveColors()
        }

        MenuBarExtra {
            MenuBarUsagePanel(model: menuBar)
                .environment(\.locale, Locale(identifier: store.interfaceLanguage.localeIdentifier))
        } label: {
            MenuBarUsageLabel(model: menuBar)
        }
        .menuBarExtraStyle(.window)
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
