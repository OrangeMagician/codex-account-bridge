import SwiftUI

@main
struct CABDesktopApp: App {
    @StateObject private var store = CABStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("刷新状态") { store.refresh() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("CAB", systemImage: "person.2.circle") {
            Button("打开 CAB Desktop") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
            Button("启动 Codex") { store.launchCodex() }
            Divider()
            Text(store.status.rotation.enabled ? "轮换：已开启" : "轮换：已关闭")
            Button("退出") { NSApp.terminate(nil) }
        }
    }
}
