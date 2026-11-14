import AppKit
import Darwin
import Foundation

enum MenuBarDisplayStyle: String, Codable, CaseIterable, Identifiable {
    case percentage, progress
    var id: String { rawValue }
    var title: String { cabLocalized(self == .percentage ? "百分比" : "进度条") }
}

struct MenuBarPreferences: Codable, Equatable {
    var displayStyle: MenuBarDisplayStyle = .percentage
    var showsAccount = false

    init() {}

    private enum CodingKeys: String, CodingKey { case displayStyle, showsAccount }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        displayStyle = (try? values.decode(MenuBarDisplayStyle.self, forKey: .displayStyle)) ?? .percentage
        showsAccount = try values.decodeIfPresent(Bool.self, forKey: .showsAccount) ?? false
    }
}

enum LocalDesktopHome: Equatable {
    case running(String)
    case multiple(homes: Set<String>, front: String?)
    case notRunning
    case unknown

    var frontHome: String? {
        switch self {
        case let .running(home): return home
        case let .multiple(_, front): return front
        default: return nil
        }
    }

    func contains(home: String) -> Bool {
        let path = canonicalDesktopHome(home)
        switch self {
        case let .running(single): return canonicalDesktopHome(single) == path
        case let .multiple(homes, _): return homes.contains(path)
        default: return false
        }
    }
}

func canonicalDesktopHome(_ home: String) -> String {
    URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
}

func desktopProcessHome(_ pid: pid_t) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 4 else { return nil }
    var bytes = [UInt8](repeating: 0, count: size)
    let result = bytes.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
    guard result == 0 else { return nil }
    let defaultHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
    return desktopHomeFromProcessArguments(Array(bytes.prefix(size)), defaultHome: defaultHome).map(canonicalDesktopHome)
}

// WindowServer returns on-screen windows in front-to-back order, even while CAB
// itself is frontmost. Only the owning PID and the window layer are needed.
func onScreenDesktopWindowPIDs() -> [pid_t] {
    guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return windows.compactMap { window in
        guard window[kCGWindowLayer as String] as? Int == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double, width > 1,
              let height = bounds["Height"] as? Double, height > 1,
              (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
        return window[kCGWindowOwnerPID as String] as? pid_t
    }
}

func frontDesktopWindowPID(in pids: Set<pid_t>) -> pid_t? {
    onScreenDesktopWindowPIDs().first(where: pids.contains)
}

@MainActor
func currentDesktopWindowHomes() -> Set<String> {
    let visible = Set(onScreenDesktopWindowPIDs())
    return Set(CodexDesktopLifecycle().runningApplications.compactMap { app in
        visible.contains(app.processIdentifier) ? desktopProcessHome(app.processIdentifier) : nil
    })
}

@MainActor
func currentLocalDesktopHome() -> LocalDesktopHome {
    let apps = CodexDesktopLifecycle().runningApplications
    guard let first = apps.first else { return .notRunning }
    if apps.count == 1 {
        return desktopProcessHome(first.processIdentifier).map(LocalDesktopHome.running) ?? .unknown
    }
    let pids = Set(apps.map(\.processIdentifier))
    let homes = Dictionary(uniqueKeysWithValues: pids.compactMap { pid in desktopProcessHome(pid).map { (pid, $0) } })
    let activePID = apps.first(where: \.isActive)?.processIdentifier ?? frontDesktopWindowPID(in: pids)
    return .multiple(homes: Set(homes.values), front: activePID.flatMap { homes[$0] })
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
    case let .multiple(_, front):
        guard let front else { return nil }
        home = front
    case .notRunning:
        guard let path = status.currentLogin?.home else { return nil }
        home = path
    case .unknown: return nil
    }
    let normalized = canonicalDesktopHome(home)
    return status.accounts.first { canonicalDesktopHome($0.home) == normalized }
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
        if case .multiple(_, nil) = desktop { return cabLocalized("多个账号窗口已打开") }
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
    func loadUsage(target: BridgeTarget, remoteHost: String, accountNames: [String]?, force: Bool) async throws -> UsageReport
}

extension MenuBarUsageService {
    func loadUsage(target: BridgeTarget, remoteHost: String, accountNames: [String]?, force: Bool) async throws -> UsageReport {
        try await loadUsage(target: target, remoteHost: remoteHost, accountNames: accountNames)
    }
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
    private var activationMonitor: Task<Void, Never>?
    private var usageObserver: Task<Void, Never>?
    private var lastAttempt: Date?
    private let preferencesKey = "menuBarPreferences.v1"

    init(service: any MenuBarUsageService = CABService(), defaults: UserDefaults = .standard,
         desktopHome: @escaping @MainActor () -> LocalDesktopHome = currentLocalDesktopHome) {
        self.service = service
        self.defaults = defaults
        self.desktopHome = desktopHome
        let preferences = defaults.data(forKey: preferencesKey)
            .flatMap { try? JSONDecoder().decode(MenuBarPreferences.self, from: $0) } ?? MenuBarPreferences()
        self.preferences = preferences
    }

    func updatePreferences(_ change: (inout MenuBarPreferences) -> Void) {
        var updated = preferences
        change(&updated)
        preferences = updated
        if let data = try? JSONEncoder().encode(updated) { defaults.set(data, forKey: preferencesKey) }
    }

    func startMonitoring() {
        guard monitor == nil else { return }
        usageObserver = Task { @MainActor [weak self] in
            let updates = await UsageRepository.shared.updates()
            for await update in updates {
                guard let self, !Task.isCancelled else { return }
                self.receiveSharedUsage(update)
            }
        }
        activationMonitor = Task { @MainActor [weak self] in
            let changes = NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didActivateApplicationNotification)
                .map { ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier }
            for await identifier in changes {
                guard let self, !Task.isCancelled else { return }
                guard identifier == "com.openai.codex", self.desktopHome() != self.snapshot.desktop else { continue }
                await self.refresh(force: false)
            }
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(force: false)
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            }
        }
    }

    deinit {
        monitor?.cancel()
        activationMonitor?.cancel()
        usageObserver?.cancel()
    }

    func receiveSharedUsage(_ update: UsageRepository.Update) {
        guard let account = snapshot.account, account.isLoggedIn, desktopHome() == snapshot.desktop,
              let report = update.reports[.init(target: "local", account: account.name)],
              let result = report.accounts.first(where: { $0.name == account.name }),
              result.error == nil, let usage = result.usage else { return }
        snapshot.usage = usage
        snapshot.fetchedAt = result.fetchedAt ?? report.fetchedAt
        snapshot.error = nil
        snapshot.checkedAt = Date()
        lastAttempt = Date()
    }

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
            let report = try await service.loadUsage(target: .local, remoteHost: "", accountNames: [account.name], force: force)
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
            await LowQuotaMonitor.shared.evaluate(UsageNotificationSource(key: "local", title: cabLocalized("这台 Mac"), reports: [result]))
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
