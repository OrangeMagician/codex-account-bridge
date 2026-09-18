import AppKit
import Darwin
import Foundation

enum MenuBarLayout: String, Codable, CaseIterable, Identifiable {
    case compact, stacked, icon
    var id: String { rawValue }
    var title: String {
        cabLocalized(self == .compact ? "单行" : self == .stacked ? "双行" : "仅图标")
    }
}

struct MenuBarPreferences: Codable, Equatable {
    var layout: MenuBarLayout = .compact
    var showsAccount = false
    var showsFiveHour = true
    var showsWeekly = true

    mutating func normalize() {
        if !showsFiveHour && !showsWeekly { showsFiveHour = true }
    }
}

enum LocalDesktopHome: Equatable {
    case running(String)
    case notRunning
    case unknown
}

// Inspect only the official desktop's launch environment. Never inspect credentials
// or infer the current account from a previous CAB launch or the selected sidebar.
@MainActor
func currentLocalDesktopHome() -> LocalDesktopHome {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
        .filter { !$0.isTerminated }
    guard !apps.isEmpty else { return .notRunning }
    var homes = Set<String>()
    for app in apps {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, app.processIdentifier]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 4 else { return .unknown }
        var bytes = [UInt8](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
        guard result == 0,
              let home = desktopHomeFromProcessArguments(Array(bytes.prefix(size)), defaultHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
        else { return .unknown }
        homes.insert(home)
    }
    return homes.count == 1 ? .running(homes.first!) : .unknown
}

func desktopHomeFromProcessArguments(_ bytes: [UInt8], defaultHome: String) -> String? {
    guard bytes.count > MemoryLayout<Int32>.size else { return nil }
    let argc = bytes.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
    guard argc > 0, argc < bytes.count else { return nil }
    var cursor = 4
    func readString() -> String? {
        guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
        defer { cursor = end + 1 }
        return String(bytes: bytes[cursor..<end], encoding: .utf8)
    }
    guard readString() != nil else { return nil } // executable path
    while cursor < bytes.count && bytes[cursor] == 0 { cursor += 1 }
    for _ in 0..<argc { guard readString() != nil else { return nil } }
    while cursor < bytes.count && bytes[cursor] != 0 {
        guard let entry = readString() else { return nil }
        if entry.hasPrefix("CODEX_HOME=") {
            let home = String(entry.dropFirst("CODEX_HOME=".count))
            guard home.hasPrefix("/") else { return nil }
            return home
        }
    }
    return defaultHome
}

func menuBarAccount(in status: BridgeStatus, desktop: LocalDesktopHome) -> AccountStatus? {
    let home: String
    switch desktop {
    case let .running(path): home = path
    case .notRunning:
        guard let path = status.currentLogin?.home else { return nil }
        home = path
    case .unknown: return nil
    }
    let normalized = URL(fileURLWithPath: home).standardizedFileURL.path
    return status.accounts.first { URL(fileURLWithPath: $0.home).standardizedFileURL.path == normalized }
}

func menuBarPercent(_ value: UsagePeriodDisplayValue) -> String {
    switch value {
    case .unlimited: return "∞"
    case .unavailable: return "—"
    case let .measured(window):
        guard window.usedPercent.isFinite else { return "—" }
        return "\(Int(window.remainingPercent.rounded()))%"
    }
}

struct MenuBarSnapshot: Equatable {
    var account: AccountStatus?
    var desktop: LocalDesktopHome = .unknown
    var usage: CodexUsageSnapshot?
    var fetchedAt: Date?
    var error: String?
    var checkedAt = Date()

    var hasExpiredWindow: Bool {
        guard let usage else { return false }
        let periods = usagePeriodDisplays(for: usage)
        return [periods.fiveHour, periods.weekly].contains {
            if case let .measured(window) = $0, let reset = window.resetDate { return reset <= checkedAt }
            return false
        }
    }

    var periods: UsagePeriodDisplays {
        guard account?.isLoggedIn == true, let usage else {
            return UsagePeriodDisplays(fiveHour: .unavailable, weekly: .unavailable)
        }
        let raw = usagePeriodDisplays(for: usage)
        func valid(_ value: UsagePeriodDisplayValue) -> UsagePeriodDisplayValue {
            if case let .measured(window) = value,
               let reset = window.resetDate, reset <= checkedAt { return .unavailable }
            return value
        }
        return UsagePeriodDisplays(fiveHour: valid(raw.fiveHour), weekly: valid(raw.weekly))
    }

    var sourceTitle: String {
        cabLocalized(desktop == .notRunning ? "本机默认账号" : "本机当前账号")
    }

    var unavailableReason: String? {
        if desktop == .unknown { return cabLocalized("无法确认本机当前账号") }
        if account == nil { return cabLocalized("当前账号尚未纳入 CAB") }
        if account?.isLoginUnknown == true { return cabLocalized("登录状态未知") }
        if account?.isLoggedIn != true { return cabLocalized("未登录") }
        return nil
    }
}

protocol MenuBarUsageService {
    func loadStatus(target: BridgeTarget, remoteHost: String) async throws -> BridgeStatus
    func loadUsage(target: BridgeTarget, remoteHost: String, accountNames: [String]?) async throws -> UsageReport
}

extension CABService: MenuBarUsageService {}

@MainActor
final class MenuBarUsageStore: ObservableObject {
    @Published private(set) var preferences: MenuBarPreferences
    @Published private(set) var snapshot = MenuBarSnapshot()
    @Published private(set) var isRefreshing = false
    private let service: any MenuBarUsageService
    private let defaults: UserDefaults
    private let desktopHome: @MainActor () -> LocalDesktopHome
    private var monitor: Task<Void, Never>?
    private var lastAttempt: Date?
    private let preferencesKey = "menuBarPreferences.v1"

    init(service: any MenuBarUsageService = CABService(), defaults: UserDefaults = .standard,
         desktopHome: @escaping @MainActor () -> LocalDesktopHome = currentLocalDesktopHome) {
        self.service = service
        self.defaults = defaults
        self.desktopHome = desktopHome
        var preferences = defaults.data(forKey: preferencesKey)
            .flatMap { try? JSONDecoder().decode(MenuBarPreferences.self, from: $0) } ?? MenuBarPreferences()
        preferences.normalize()
        self.preferences = preferences
    }

    func updatePreferences(_ change: (inout MenuBarPreferences) -> Void) {
        var updated = preferences
        change(&updated)
        updated.normalize()
        preferences = updated
        if let data = try? JSONEncoder().encode(updated) { defaults.set(data, forKey: preferencesKey) }
    }

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(force: false)
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            }
        }
    }

    deinit { monitor?.cancel() }

    func launchCurrentAccount() {
        guard let account = snapshot.account, account.isLoggedIn else { return }
        do {
            try CABService().launchCodexInTerminal(target: .local, remoteHost: "", accountName: account.name)
        } catch {
            snapshot.error = error.localizedDescription
        }
    }

    func refresh(force: Bool = true, now: Date = Date()) async {
        guard !isRefreshing else { return }
        let desktop = desktopHome()
        let changed = desktop != snapshot.desktop
        snapshot.checkedAt = now
        if changed { snapshot = MenuBarSnapshot(desktop: desktop, checkedAt: now) }
        let interval = defaults.object(forKey: "usageRefreshInterval.v1") == nil ? .fifteenMinutes
            : UsageRefreshInterval(rawValue: defaults.integer(forKey: "usageRefreshInterval.v1")) ?? .fifteenMinutes
        if !force && !changed, let lastAttempt {
            guard let duration = interval.duration, now.timeIntervalSince(lastAttempt) >= duration else { return }
        }
        isRefreshing = true
        defer { isRefreshing = false }
        lastAttempt = now
        do {
            let status = try await service.loadStatus(target: .local, remoteHost: "")
            guard desktopHome() == desktop else {
                snapshot = MenuBarSnapshot(desktop: desktopHome(), checkedAt: now)
                lastAttempt = nil
                return
            }
            let account = menuBarAccount(in: status, desktop: desktop)
            if snapshot.account?.home != account?.home || snapshot.account?.name != account?.name {
                snapshot = MenuBarSnapshot(account: account, desktop: desktop, checkedAt: now)
            } else {
                snapshot.account = account
                snapshot.desktop = desktop
            }
            guard let account, account.isLoggedIn else {
                snapshot.usage = nil
                snapshot.fetchedAt = nil
                snapshot.error = nil
                return
            }
            guard force || interval != .manual else { return }
            let report = try await service.loadUsage(target: .local, remoteHost: "", accountNames: [account.name])
            guard desktopHome() == desktop else {
                snapshot = MenuBarSnapshot(desktop: desktopHome(), checkedAt: now)
                lastAttempt = nil
                return
            }
            guard let result = report.accounts.first(where: { $0.name == account.name }), let usage = result.usage else {
                snapshot.error = cabLocalized("刷新失败，正在显示上次成功获取的额度。")
                return
            }
            snapshot.usage = usage
            snapshot.fetchedAt = report.fetchedAt
            snapshot.error = nil
        } catch {
            if desktopHome() != desktop {
                snapshot = MenuBarSnapshot(desktop: desktopHome(), checkedAt: now)
                lastAttempt = nil
            } else {
                snapshot.error = cabLocalized("刷新失败，正在显示上次成功获取的额度。")
            }
        }
    }
}
