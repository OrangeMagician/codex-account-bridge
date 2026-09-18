import AppKit
import SwiftUI
import Testing
@testable import CABDesktop

private let menuBarTestDate = Date(timeIntervalSince1970: 1_800_000_000)
private let menuBarTestAccount = AccountStatus(name: "Personal", home: "/accounts/personal", login: "present", default: false, remote: false)

private func testUsage(used: Double = 32) -> CodexUsageSnapshot {
    CodexUsageSnapshot(planType: "plus", rateLimits: UsageRateLimitSnapshot(
        limitID: "codex", limitName: nil,
        primary: UsageWindow(usedPercent: used, windowDurationMins: 300, resetsAt: 1_800_007_200),
        secondary: UsageWindow(usedPercent: 58, windowDurationMins: 10_080, resetsAt: 1_800_172_800),
        credits: nil, individualLimit: nil, spendControlReached: nil, planType: nil, rateLimitReachedType: nil
    ), rateLimitsByLimitID: nil, resetCredits: nil)
}

private final class MenuBarTestService: MenuBarUsageService {
    var status = BridgeStatus(defaultAccount: "Different CLI account", sharedSessions: false,
        rotation: RotationStatus(enabled: false),
        currentLogin: CurrentLoginStatus(home: "/default", login: "present", registeredAs: "Default"),
        accounts: [menuBarTestAccount])
    var usage = testUsage()
    var fails = false
    var requestedAccounts: [[String]?] = []
    var targets: [BridgeTarget] = []
    var beforeUsageReturn: (() -> Void)?

    func loadStatus(target: BridgeTarget, remoteHost: String) async throws -> BridgeStatus {
        targets.append(target)
        return status
    }

    func loadUsage(target: BridgeTarget, remoteHost: String, accountNames: [String]?) async throws -> UsageReport {
        targets.append(target)
        requestedAccounts.append(accountNames)
        beforeUsageReturn?()
        if fails { throw NSError(domain: "test", code: 1) }
        return UsageReport(fetchedAt: menuBarTestDate, accounts: [AccountUsageReport(name: menuBarTestAccount.name, usage: usage, error: nil)])
    }
}

@Suite("Local menu bar usage")
struct MenuBarUsageTests {
    @Test func parsesOnlyDesktopHomeAfterArguments() {
        func buffer(environment: String) -> [UInt8] {
            [2, 0, 0, 0] + Array("/Applications/Codex.app/Contents/MacOS/Codex\0\0Codex\0--test\0\(environment)\0\0".utf8)
        }
        #expect(desktopHomeFromProcessArguments(buffer(environment: "PATH=/usr/bin\0CODEX_HOME=/accounts/personal\0HOME=/Users/test"), defaultHome: "/default") == "/accounts/personal")
        #expect(desktopHomeFromProcessArguments(buffer(environment: "PATH=/usr/bin"), defaultHome: "/default") == "/default")
        #expect(desktopHomeFromProcessArguments(buffer(environment: "CODEX_HOME=relative"), defaultHome: "/default") == nil)
        #expect(desktopHomeFromProcessArguments([1, 0, 0, 0, 65], defaultHome: "/default") == nil)
    }

    @Test func currentDesktopWinsOverCLIDefaultAndUnknownNeverFallsBack() {
        let service = MenuBarTestService()
        #expect(menuBarAccount(in: service.status, desktop: .running("/accounts/personal/")) == menuBarTestAccount)
        #expect(menuBarAccount(in: service.status, desktop: .unknown) == nil)
        #expect(menuBarAccount(in: service.status, desktop: .notRunning) == nil)
        #expect(menuBarAccount(in: service.status, desktop: .running("/unregistered")) == nil)
        service.status.currentLogin = CurrentLoginStatus(home: menuBarTestAccount.home, login: "present", registeredAs: menuBarTestAccount.name)
        #expect(menuBarAccount(in: service.status, desktop: .notRunning) == menuBarTestAccount)
    }

    @Test func distinguishesUnknownUnlimitedAndExpiredValues() {
        #expect(menuBarPercent(.unavailable) == "—")
        #expect(menuBarPercent(.unlimited) == "∞")
        #expect(menuBarPercent(.measured(UsageWindow(usedPercent: .nan, windowDurationMins: nil, resetsAt: nil))) == "—")
        var snapshot = MenuBarSnapshot(account: menuBarTestAccount, desktop: .running(menuBarTestAccount.home), usage: testUsage(), checkedAt: menuBarTestDate)
        #expect(menuBarPercent(snapshot.periods.fiveHour) == "68%")
        #expect(menuBarPercent(snapshot.periods.weekly) == "42%")
        snapshot.checkedAt = menuBarTestDate.addingTimeInterval(7_201)
        #expect(snapshot.periods.fiveHour == .unavailable)
        #expect(menuBarPercent(snapshot.periods.weekly) == "42%")
    }

    @MainActor
    @Test func preferencesPersistAndMigrateOldLayouts() {
        let suite = "CAB.MenuBar.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MenuBarUsageStore(defaults: defaults, desktopHome: { .unknown })
        #expect(model.preferences == MenuBarPreferences())
        model.updatePreferences { $0.displayStyle = .progress; $0.showsAccount = true }
        let restored = MenuBarUsageStore(defaults: defaults, desktopHome: { .unknown })
        #expect(restored.preferences.displayStyle == .progress)
        #expect(restored.preferences.showsAccount)
        let old = Data(#"{"layout":"icon","showsAccount":true,"showsFiveHour":false,"showsWeekly":false}"#.utf8)
        defaults.set(old, forKey: "menuBarPreferences.v1")
        let migrated = MenuBarUsageStore(defaults: defaults, desktopHome: { .unknown })
        #expect(migrated.preferences.displayStyle == .percentage)
        #expect(migrated.preferences.showsAccount)
    }

    @MainActor
    @Test func refreshIsLocalAndPreservesOnlySameAccountCacheOnFailure() async {
        let service = MenuBarTestService()
        var home = LocalDesktopHome.running(menuBarTestAccount.home)
        let model = MenuBarUsageStore(service: service, desktopHome: { home })
        await model.refresh(now: menuBarTestDate)
        #expect(service.targets.allSatisfy { $0 == .local })
        #expect(service.requestedAccounts == [[menuBarTestAccount.name]])
        #expect(model.snapshot.usage == testUsage())
        service.fails = true
        await model.refresh(now: menuBarTestDate)
        #expect(model.snapshot.usage == testUsage())
        #expect(model.snapshot.error != nil)
        home = .running("/different")
        await model.refresh(force: false, now: menuBarTestDate)
        #expect(model.snapshot.usage == nil)
        #expect(model.snapshot.account == nil)
    }

    @MainActor
    @Test func discardsResponsesWhenDesktopChangesDuringRefresh() async {
        let service = MenuBarTestService()
        var home = LocalDesktopHome.running(menuBarTestAccount.home)
        service.beforeUsageReturn = { home = .running("/different") }
        let model = MenuBarUsageStore(service: service, desktopHome: { home })
        await model.refresh(now: menuBarTestDate)
        #expect(model.snapshot.account == nil)
        #expect(model.snapshot.usage == nil)
        #expect(model.snapshot.desktop == home)
    }

    @MainActor
    @Test func respectsManualRefreshAndReusesCache() async {
        let suite = "CAB.MenuBar.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0, forKey: "usageRefreshInterval.v1")
        let service = MenuBarTestService()
        let model = MenuBarUsageStore(service: service, defaults: defaults, desktopHome: { .running(menuBarTestAccount.home) })
        await model.refresh(force: false, now: menuBarTestDate)
        #expect(service.requestedAccounts.isEmpty)
        #expect(model.snapshot.account == menuBarTestAccount)
        await model.refresh(now: menuBarTestDate)
        await model.refresh(force: false, now: menuBarTestDate.addingTimeInterval(3_600))
        #expect(service.requestedAccounts.count == 1)
        await model.refresh(now: menuBarTestDate.addingTimeInterval(3_600))
        #expect(service.requestedAccounts.count == 2)
    }

    @MainActor
    @Test func rendersNativePanelAndCompactLabels() async throws {
        let model = MenuBarUsageStore(service: MenuBarTestService(), desktopHome: { .running(menuBarTestAccount.home) })
        await model.refresh(now: menuBarTestDate)
        for style in MenuBarDisplayStyle.allCases {
            var preferences = MenuBarPreferences()
            preferences.displayStyle = style
            let image = menuBarLabelImage(snapshot: model.snapshot, preferences: preferences)
            #expect(image.size.height == 22)
            #expect(image.size.width < 210)
            #expect(image.isTemplate)
            if let directory = ProcessInfo.processInfo.environment["CAB_MENU_BAR_RENDER_DIR"] {
                let canvas = NSImage(size: NSSize(width: image.size.width + 20, height: 32), flipped: false) { rect in
                    NSColor.white.setFill()
                    rect.fill()
                    image.draw(at: NSPoint(x: 10, y: 5), from: .zero, operation: .sourceOver, fraction: 1)
                    return true
                }
                try savePNG(canvas, to: "\(directory)/label-\(style.rawValue).png")
            }
        }
        if let directory = ProcessInfo.processInfo.environment["CAB_MENU_BAR_RENDER_DIR"] {
            for scheme in [ColorScheme.light, .dark] {
                let content = MenuBarUsagePanel(model: model)
                    .environment(\.locale, Locale(identifier: "zh-Hans"))
                    .environment(\.colorScheme, scheme)
                    .background(scheme == .dark ? Color(nsColor: .init(white: 0.12, alpha: 1)) : .white)
                try saveNativeView(content, dark: scheme == .dark, to: "\(directory)/panel-\(scheme == .dark ? "dark" : "light").png")
            }
            try saveNativeView(MenuBarPreferencesView(model: model).padding(20).frame(width: 320).background(.white), dark: false, to: "\(directory)/preferences.png")
        }
    }
}

@MainActor
private func savePNG(_ image: NSImage, to path: String) throws {
    let data = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: data))
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
}

@MainActor
private func saveNativeView<Content: View>(_ content: Content, dark: Bool, to path: String) throws {
    _ = NSApplication.shared
    let hosting = NSHostingView(rootView: content)
    let size = hosting.fittingSize
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = hosting
    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
}
