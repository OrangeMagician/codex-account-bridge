import AppKit
import SwiftUI

@main
struct CABDesktopApp: App {
    @StateObject private var store = CABStore()
    @StateObject private var menuBar = MenuBarUsageStore()

    var body: some Scene {
        WindowGroup(id: "cab-main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(menuBar)
                .cabPreservingActiveColors()
                .task {
                    menuBar.startMonitoring()
                    PublicResetMonitor.shared.startMonitoring()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CABCommands(store: store)
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
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("软件设置") {
                store.sidebarSelection = CABStore.appSettingsSelection
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("cab-main-") == true }) {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    openWindow(id: "cab-main")
                }
            }
            .keyboardShortcut(",", modifiers: [.command])
        }
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
