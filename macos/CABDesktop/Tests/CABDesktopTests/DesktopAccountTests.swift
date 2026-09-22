import AppKit
import SwiftUI
import Testing
@testable import CABDesktop

@Suite("Current desktop account")
@MainActor
struct DesktopAccountTests {
    private let personal = AccountStatus(name: "Personal", home: "/accounts/personal", login: "present", default: true, remote: false)
    private let work = AccountStatus(name: "Work", home: "/accounts/work", login: "present", default: false, remote: true)

    private func status() -> BridgeStatus {
        BridgeStatus(defaultAccount: personal.name, sharedSessions: false,
            rotation: RotationStatus(enabled: false),
            currentLogin: CurrentLoginStatus(home: personal.home, login: "present", registeredAs: personal.name),
            accounts: [personal, work])
    }

    @Test func runningAccountWinsOverDefaultLastLaunchAndSelection() {
        let store = CABStore(desktopHome: { .running(self.work.home + "/") })
        store.status = status()
        store.lastDesktopAccount = personal.name
        store.selectedAccount = personal.name
        #expect(store.currentDesktopAccount == work)
        #expect(store.isCurrentDesktopAccount(work))
        #expect(!store.isCurrentDesktopAccount(personal))
        #expect(store.previousDesktopHome(fallback: personal.home) == work.home + "/")
        store.selectedAccount = work.name
        #expect(store.currentDesktopAccount == work)
        store.target = .remote
        #expect(store.currentDesktopAccount == nil)
        #expect(!store.isCurrentDesktopAccount(work))
    }

    @Test func processChangesRefreshEvenWhenUsageRefreshIsManual() {
        var home = LocalDesktopHome.running(work.home)
        let store = CABStore(desktopHome: { home })
        store.status = status()
        store.usageRefreshInterval = .manual
        #expect(store.currentDesktopAccount == work)
        home = .running(personal.home)
        store.refreshLocalDesktopAccount()
        #expect(store.currentDesktopAccount == personal)
        for unavailable in [LocalDesktopHome.notRunning, .unknown, .running("/unregistered")] {
            home = unavailable
            store.refreshLocalDesktopAccount()
            #expect(store.currentDesktopAccount == nil)
            #expect(!store.isCurrentDesktopAccount(personal))
            #expect(!store.isCurrentDesktopAccount(work))
            #expect(!store.currentDesktopAccountDescription.isEmpty)
        }
    }

    @Test func sameAccountSwitchUsesFreshProcessStateAndDoesNothing() async {
        var home = LocalDesktopHome.running(personal.home)
        let store = CABStore(desktopHome: { home })
        store.status = status()
        home = .running(work.home)
        // A stale sheet must re-check the actual process before it could stop anything.
        store.switchCodexDesktop(to: work)
        #expect(store.currentDesktopAccount == work)
        #expect(!store.isBusy)
        #expect(store.output.isEmpty)
        #expect(store.pendingDesktopSwitch == nil)
        #expect(store.errorMessage == nil)
        store.performDesktopSwitch(to: work, checkProcesses: true)
        #expect(!store.isBusy)
        #expect(store.output.isEmpty)
    }

    @Test func verifiesLiveDetectionWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CAB_VERIFY_LIVE_DESKTOP"] == "1" else { return }
        let live = currentLocalDesktopHome()
        guard case .running = live else {
            Issue.record("Expected a running desktop for this opt-in local check")
            return
        }
        let store = CABStore()
        store.status = try await CABService().loadStatus(target: .local, remoteHost: "")
        let account = try #require(store.currentDesktopAccount)
        #expect(store.status.accounts.filter { store.isCurrentDesktopAccount($0) }.count == 1)
        print("Verified running desktop account: \(account.name)")
    }

    @Test func rendersCurrentAndOtherAccountsWhenRequested() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CAB_DESKTOP_ACCOUNT_RENDER_DIR"] else { return }
        _ = NSApplication.shared
        let store = CABStore(desktopHome: { .running(self.personal.home) })
        store.status = status()
        store.interfaceLanguage = .simplifiedChinese
        for selection in [personal.name, work.name, CABStore.globalSettingsSelection] {
            store.sidebarSelection = selection
            for dark in [false, true] {
                let content = ContentView(performsLiveChecks: false).environmentObject(store)
                    .frame(width: 1000, height: 800)
                    .environment(\.colorScheme, dark ? .dark : .light).cabPreservingActiveColors()
                let hosting = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = hosting
                hosting.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 150_000_000)
                hosting.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(selection)-\(dark).png"))
            }
        }
    }
}
