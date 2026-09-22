import CABContinuity
import Foundation
import SwiftUI

enum LoginBrowser {
    case systemDefault
    case selected(BrowserChoice, privateWindow: Bool)
}

struct UsageCacheEntry {
    let reports: [String: AccountUsageReport]
    let fetchedAt: Date?
    let checkedAtByAccount: [String: Date]
    let error: String?
}

@MainActor
final class CABStore: ObservableObject {
    static let maximumOutputCharacters = 500_000
    @Published var target: BridgeTarget = .local
    @Published var status = BridgeStatus(sharedSessions: false, rotation: RotationStatus(enabled: false, accounts: [], nextIndex: 0), currentLogin: nil, accounts: [])
    @Published var sidebarSelection = CABStore.globalSettingsSelection
    @Published var newAccountName = ""
    @Published var existingAccountName = "current"
    @Published var rotationOrder: [String] = []
    @Published var rotationIncluded: Set<String> = []
    @Published var output = ""
    @Published var errorMessage: String?
    @Published var isBusy = false
    @Published var isStatusRefreshing = false
    var statusRefreshGeneration = 0
    @Published var remoteServers: [RemoteServer] = []
    @Published var selectedRemoteID: UUID?
    @Published var showServerManager = false
    @Published var lastDesktopAccount: String?
    @Published var preserveSessionsOnDesktopSwitch = false
    @Published var interfaceLanguage: InterfaceLanguage = .system
    @Published var usageRefreshInterval: UsageRefreshInterval = .fifteenMinutes
    @Published var usageWakeSettings = UsageWakeSettings()
    @Published var usageResetNotificationsEnabled = false
    @Published var isUsageResetNotificationUpdating = false
    @Published var scheduledUsageResetNotificationCount = 0
    @Published var usageResetNotificationError: String?
    @Published var usageByAccount: [String: AccountUsageReport] = [:]
    @Published var usageFetchedAt: Date?
    @Published var usageLoadError: String?
    @Published var isUsageRefreshing = false
    @Published var usageResettingAccount: String?
    @Published var usageResetResult: UsageResetResult?
    @Published var tokenUsage: TokenUsageReport?
    @Published var tokenUsageLoadError: String?
    @Published var isTokenUsageRefreshing = false
    @Published var isCodexUpdating = false
    @Published var codexUpdateStatus: CodexUpdateStatus?
    @Published var codexUpdateError: String?
    @Published var isCodexUpdateChecking = false
    @Published private(set) var loginAccountName: String?
    @Published private(set) var loginStatusConfirmed = false
    @Published private(set) var canManuallyCheckLogin = false
    @Published var agentBindings: [AgentBindingStatus] = []
    @Published var agentSelections: [String: String] = [:]
    @Published var agentBindingError: String?
    @Published var bulkAgentAccount = ""
    @Published var pendingRemoteSessionChange: RemoteSessionProcessRequest?
    @Published var pendingRemoteCodexSwitch: RemoteCodexSwitchRequest?
    @Published var legacySessions: LegacySessionReport?
    @Published var pendingLegacyProcesses: [CodexProcessStatus]?
    @Published var pendingDesktopSwitch: DesktopSwitchProcessRequest?
    @Published var pendingDesktopSwitchError: String?
    @Published var desktopSwitchPartialResult: DesktopSwitchPartialResult?

    let tools = ManagementToolsStore()
    let service = CABService()
    lazy var usageResetNotificationService = UsageResetNotificationService()
    let defaults = UserDefaults.standard
    let remoteServersKey = "remoteServers.v1"
    let selectedRemoteKey = "selectedRemoteServer.v1"
    let lastDesktopAccountKey = "lastDesktopAccount.v1"
    let preserveSessionsKey = "preserveSessionsOnDesktopSwitch.v1"
    let interfaceLanguageKey = "interfaceLanguage.v1"
    let usageRefreshIntervalKey = "usageRefreshInterval.v1"
    let usageWakeSettingsKey = "usageWakeSettings.v1"
    let usageWakeStateKey = "usageWakeState.v1"
    let usageResetNotificationsKey = "usageResetNotifications.v1"
    var hasSavedDesktopSessionPreference = false
    var loginOutputBuffer = ""
    var loginBrowserOpened = false
    var loginStatusMonitor: Task<Void, Never>?
    var usageCacheByKey: [String: UsageCacheEntry] = [:]
    var usageRefreshingKeys: Set<String> = []
    var usageWakeState = UsageWakeState()
    var usageWakeInFlightKeys: Set<String> = []
    var usageSchedulerTask: Task<Void, Never>?
    var tokenUsageByKey: [String: TokenUsageReport] = [:]
    var tokenUsageErrorByKey: [String: String] = [:]
    var tokenUsageRefreshingKeys: Set<String> = []
    var codexUpdateStatusByKey: [String: CodexUpdateStatus] = [:]
    var codexUpdateErrorByKey: [String: String] = [:]
    var codexUpdateCheckingKeys: Set<String> = []

    init() {
        lastDesktopAccount = defaults.string(forKey: lastDesktopAccountKey)
        hasSavedDesktopSessionPreference = defaults.object(forKey: preserveSessionsKey) != nil
        preserveSessionsOnDesktopSwitch = defaults.bool(forKey: preserveSessionsKey)
        if let savedLanguage = defaults.string(forKey: interfaceLanguageKey),
           let language = InterfaceLanguage(rawValue: savedLanguage) {
            interfaceLanguage = language
        }
        usageResetNotificationsEnabled = defaults.bool(forKey: usageResetNotificationsKey)
        if let savedInterval = UsageRefreshInterval(rawValue: defaults.integer(forKey: usageRefreshIntervalKey)),
           defaults.object(forKey: usageRefreshIntervalKey) != nil {
            usageRefreshInterval = savedInterval
        }
        if let data = defaults.data(forKey: usageWakeSettingsKey),
           var decoded = try? JSONDecoder().decode(UsageWakeSettings.self, from: data) {
            decoded.normalize()
            usageWakeSettings = decoded
        }
        if let data = defaults.data(forKey: usageWakeStateKey),
           let decoded = try? JSONDecoder().decode(UsageWakeState.self, from: data) {
            usageWakeState = decoded
        }
        if let data = defaults.data(forKey: remoteServersKey),
           let decoded = try? JSONDecoder().decode([RemoteServer].self, from: data) {
            remoteServers = decoded
        }
        if let value = defaults.string(forKey: selectedRemoteKey), let id = UUID(uuidString: value), remoteServers.contains(where: { $0.id == id }) {
            selectedRemoteID = id
        } else {
            selectedRemoteID = remoteServers.first?.id
        }
    }

    var selectedRemoteServer: RemoteServer? {
        remoteServers.first { $0.id == selectedRemoteID }
    }

    var remoteHost: String { selectedRemoteServer?.host ?? "" }
    var targetTitle: String {
        if target == .local { return target.title }
        return selectedRemoteServer?.name.nonEmpty ?? "远程服务器"
    }

    var selectedAccountStatus: AccountStatus? {
        status.accounts.first { $0.name == selectedAccount }
    }

    var selectedAccount: String? {
        get { showingGlobalSettings || showingTools ? nil : sidebarSelection }
        set { sidebarSelection = newValue ?? Self.globalSettingsSelection }
    }

    var showingTools: Bool { ["cab.tools", "cab.projects", "cab.history"].contains(sidebarSelection) }

    var showingGlobalSettings: Bool {
        sidebarSelection == Self.globalSettingsSelection
    }

    var canImportCurrentLogin: Bool {
        status.currentLogin?.isLoggedIn == true && status.currentLogin?.isRegistered == false
    }

    var defaultDesktopAccount: String? { status.currentLogin?.registeredAs }

    func usesDefaultCodexHome(_ account: AccountStatus) -> Bool {
        account.home == status.currentLogin?.home
    }

    func usage(for accountName: String) -> AccountUsageReport? {
        usageByAccount[accountName]
    }

    func isLoginInProgress(_ accountName: String) -> Bool {
        loginAccountName == accountName
    }

    var availableBrowsers: [BrowserChoice] {
        service.installedBrowsers()
    }

    var availablePrivateBrowsers: [BrowserChoice] {
        service.installedPrivateBrowsers()
    }

    func discoverSSHHosts() throws -> [String] {
        try service.discoverSSHHosts()
    }

    func cancelRefresh() {
        service.cancelReadOperations()
        Task { await UsageRepository.shared.cancel() }
    }

    func refresh() {
        Task { await reload() }
    }

    func refreshUsage() {
        Task { await reloadUsage(force: true) }
    }

    func refreshTokenUsage() {
        Task { await reloadTokenUsage(force: true) }
    }

    func refreshCodexUpdateStatus() {
        Task { await reloadCodexUpdateStatus(force: true) }
    }

    func updateLocalCodex() {
        updateCodex(target: .local, remoteHost: "", label: "本机 Codex CLI")
    }

    func updateRemoteCodex() {
        updateCodex(target: .remote, remoteHost: remoteHost, label: "远程 Codex CLI")
    }

    func refreshUsage(accountName: String) {
        guard status.accounts.contains(where: { $0.name == accountName }) else { return }
        Task { await reloadUsage(force: true, accountNames: [accountName]) }
    }

    func consumeUsageReset(for confirmation: UsageResetConfirmation) {
        guard usageResettingAccount == nil, !isBusy else { return }
        let accountName = confirmation.accountName
        let capturedTarget = target
        let capturedHost = remoteHost
        let capturedCacheKey = currentUsageCacheKey
        usageResettingAccount = accountName
        isBusy = true
        Task {
            defer {
                usageResettingAccount = nil
                isBusy = false
            }
            do {
                let result = try await service.resetUsage(
                    target: capturedTarget,
                    remoteHost: capturedHost,
                    accountName: accountName,
                    creditID: confirmation.credit?.creditID,
                    idempotencyKey: UUID()
                )
                guard result.account == accountName else {
                    throw BridgeError.invalidUsage("额度重置结果与所选账号不一致。")
                }
                if capturedCacheKey == currentUsageCacheKey {
                    await reloadUsage(force: true)
                }
                usageResetResult = result
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func startUsageRefreshScheduler() {
        guard usageSchedulerTask == nil else { return }
        usageSchedulerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                await self.runUsageRefreshSchedulerTick()
            }
        }
    }

    func stopUsageRefreshScheduler() {
        usageSchedulerTask?.cancel()
        usageSchedulerTask = nil
    }

    func setUsageRefreshInterval(_ interval: UsageRefreshInterval) {
        usageRefreshInterval = interval
        defaults.set(interval.rawValue, forKey: usageRefreshIntervalKey)
        Task { await reloadUsage(force: false) }
    }

    func setUsageWakeEnabled(_ enabled: Bool) {
        usageWakeSettings.enabled = enabled
        persistUsageWakeSettings()
    }

    func setUsageWakeRecoveryEnabled(_ enabled: Bool) {
        usageWakeSettings.wakeOnRecovery = enabled
        persistUsageWakeSettings()
    }

    func updateUsageWakeSettings(_ update: (inout UsageWakeSettings) -> Void) {
        update(&usageWakeSettings)
        usageWakeSettings.normalize()
        persistUsageWakeSettings()
    }

    func usageWakeDate(for time: UsageTimeOfDay) -> Date {
        time.date(on: Date()) ?? Date()
    }

    func addUsageWakeProbeTime() {
        guard usageWakeSettings.weeklyProbeTimes.count < usageWakeMaximumEntries else { return }
        let now = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        updateUsageWakeSettings { settings in
            guard let time = UsageTimeOfDay(hour: Calendar.current.component(.hour, from: now), minute: Calendar.current.component(.minute, from: now)) else { return }
            settings.weeklyProbeTimes.append(time)
        }
    }

    func removeUsageWakeProbeTime(at index: Int) {
        guard usageWakeSettings.weeklyProbeTimes.indices.contains(index) else { return }
        updateUsageWakeSettings { $0.weeklyProbeTimes.remove(at: index) }
    }

    func setUsageWakeProbeTime(at index: Int, date: Date) {
        guard usageWakeSettings.weeklyProbeTimes.indices.contains(index) else { return }
        let time = UsageTimeOfDay(date: date)
        updateUsageWakeSettings { $0.weeklyProbeTimes[index] = time }
    }

    func addUsageWakeQuietPeriod() {
        guard usageWakeSettings.quietPeriods.count < usageWakeMaximumEntries else { return }
        let start = UsageTimeOfDay(hour: 23, minute: 0)!
        let end = UsageTimeOfDay(hour: 7, minute: 0)!
        updateUsageWakeSettings { $0.quietPeriods.append(UsageQuietPeriod(start: start, end: end)) }
    }

    func removeUsageWakeQuietPeriod(at index: Int) {
        guard usageWakeSettings.quietPeriods.indices.contains(index) else { return }
        updateUsageWakeSettings { $0.quietPeriods.remove(at: index) }
    }

    func setUsageWakeQuietStart(at index: Int, date: Date) {
        guard usageWakeSettings.quietPeriods.indices.contains(index) else { return }
        let time = UsageTimeOfDay(date: date)
        updateUsageWakeSettings { $0.quietPeriods[index].start = time }
    }

    func setUsageWakeQuietEnd(at index: Int, date: Date) {
        guard usageWakeSettings.quietPeriods.indices.contains(index) else { return }
        let time = UsageTimeOfDay(date: date)
        updateUsageWakeSettings { $0.quietPeriods[index].end = time }
    }

    func setUsageResetNotificationsEnabled(_ enabled: Bool) {
        guard !isUsageResetNotificationUpdating else { return }
        Task {
            isUsageResetNotificationUpdating = true
            defer { isUsageResetNotificationUpdating = false }
            if enabled {
                do {
                    guard try await usageResetNotificationService.requestAuthorization() else {
                        throw UsageResetNotificationError.permissionDenied
                    }
                    let count = try await scheduleUsageResetNotifications()
                    usageResetNotificationsEnabled = true
                    defaults.set(true, forKey: usageResetNotificationsKey)
                    scheduledUsageResetNotificationCount = count
                    usageResetNotificationError = nil
                } catch {
                    usageResetNotificationsEnabled = false
                    defaults.set(false, forKey: usageResetNotificationsKey)
                    scheduledUsageResetNotificationCount = 0
                    usageResetNotificationError = error.localizedDescription
                    errorMessage = error.localizedDescription
                }
            } else {
                await usageResetNotificationService.cancelScheduledNotifications()
                usageResetNotificationsEnabled = false
                defaults.set(false, forKey: usageResetNotificationsKey)
                scheduledUsageResetNotificationCount = 0
                usageResetNotificationError = nil
            }
        }
    }

    func setPreserveSessionsOnDesktopSwitch(_ enabled: Bool) {
        preserveSessionsOnDesktopSwitch = enabled
        hasSavedDesktopSessionPreference = true
        defaults.set(enabled, forKey: preserveSessionsKey)
    }

    func setInterfaceLanguage(_ language: InterfaceLanguage) {
        interfaceLanguage = language
        defaults.set(language.rawValue, forKey: interfaceLanguageKey)
    }

    func changeTarget(_ next: BridgeTarget) {
        target = next
        if !showingTools { selectedAccount = nil }
        restoreUsageForCurrentTarget()
        restoreTokenUsageForCurrentTarget()
        restoreCodexUpdateStatusForCurrentTarget()
        if next == .remote && remoteServers.isEmpty {
            status = Self.emptyStatus
            showServerManager = true
        } else {
            refresh()
        }
    }

    func selectRemoteServer(_ id: UUID?) {
        selectedRemoteID = id
        if let id { defaults.set(id.uuidString, forKey: selectedRemoteKey) }
        if !showingTools { selectedAccount = nil }
        restoreUsageForCurrentTarget()
        restoreTokenUsageForCurrentTarget()
        restoreCodexUpdateStatusForCurrentTarget()
        refresh()
    }

    func saveRemoteServers(_ servers: [RemoteServer]) -> Bool {
        let names = servers.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        let hosts = servers.map { $0.host.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !names.contains(where: \.isEmpty) else {
            errorMessage = "服务器名称不能为空。"
            return false
        }
        guard hosts.allSatisfy({ $0.range(of: "^[A-Za-z0-9][A-Za-z0-9._@:\\[\\]%-]{0,254}$", options: .regularExpression) != nil }) else {
            errorMessage = "SSH 主机只能填写别名、主机名、IP 或 user@host，不能包含空格或命令参数。"
            return false
        }
        remoteServers = servers
        for index in remoteServers.indices {
            remoteServers[index].name = names[index]
            remoteServers[index].host = hosts[index]
        }
        if selectedRemoteID == nil || !remoteServers.contains(where: { $0.id == selectedRemoteID }) {
            selectedRemoteID = remoteServers.first?.id
        }
        persistRemoteServers()
        if usageResetNotificationsEnabled {
            Task { await refreshUsageResetNotificationsIfNeeded() }
        }
        if target == .remote { refresh() }
        return true
    }

    func addAccount() {
        let name = newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil else {
            errorMessage = BridgeError.invalidAccountName.localizedDescription
            return
        }
        run(["account", "add", name], refreshUsageAfterSuccess: true) { [weak self] in
            self?.newAccountName = ""
            self?.selectedAccount = name
        }
    }

    func importCurrentLogin() {
        let name = existingAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil else {
            errorMessage = BridgeError.invalidAccountName.localizedDescription
            return
        }
        run(["account", "import-current", name], refreshUsageAfterSuccess: true) { [weak self] in
            self?.selectedAccount = name
        }
    }

    func loginInDefaultBrowser(_ name: String) {
        run(["login", name], loginAccount: name, refreshUsageAfterSuccess: true)
    }
    func loginWithDeviceCode(_ name: String) {
        run(["login", "--device-auth", name], loginBrowser: .systemDefault, loginAccount: name, refreshUsageAfterSuccess: true)
    }
    func loginInBrowser(_ name: String, browser: BrowserChoice) {
        run(["login", "--browser-auth", name], loginBrowser: .selected(browser, privateWindow: false), loginAccount: name, refreshUsageAfterSuccess: true)
    }
    func loginPrivately(_ name: String, browser: BrowserChoice) {
        run(["login", "--browser-auth", name], loginBrowser: .selected(browser, privateWindow: true), loginAccount: name, refreshUsageAfterSuccess: true)
    }

    func checkPendingLoginStatus() {
        guard let accountName = loginAccountName, canManuallyCheckLogin else { return }
        let capturedTarget = target
        let capturedHost = remoteHost
        let capturedKey = currentUsageCacheKey
        Task {
            _ = await detectCompletedLogin(
                accountName: accountName,
                target: capturedTarget,
                remoteHost: capturedHost,
                usageKey: capturedKey
            )
        }
    }

    func setDefault(_ name: String) { run(["use", name]) }
    func switchRemoteCodex(to name: String) {
        guard target == .remote, !isBusy else { return }
        guard status.accounts.first(where: { $0.name == name })?.isLoggedIn == true else {
            errorMessage = "只能切换到远程服务器上已登录的账号。"
            return
        }
        let capturedHost = remoteHost
        Task {
            isBusy = true
            errorMessage = nil
            defer { isBusy = false }
            do {
                let processes = try await service.loadRemoteSwitchCodexProcesses(remoteHost: capturedHost)
                if processes.isEmpty {
                    try await applyRemoteCodexSwitch(name, remoteHost: capturedHost)
                } else {
                    pendingRemoteCodexSwitch = RemoteCodexSwitchRequest(
                        remoteHost: capturedHost,
                        accountName: name,
                        processes: processes
                    )
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func confirmRemoteCodexSwitch(_ request: RemoteCodexSwitchRequest) {
        guard target == .remote, !isBusy else { return }
        guard remoteHost == request.remoteHost else {
            pendingRemoteCodexSwitch = nil
            errorMessage = "远程服务器已变更，请在当前服务器上重新发起切换。"
            return
        }
        Task {
            isBusy = true
            errorMessage = nil
            defer { isBusy = false }
            do {
                try await selectRemoteCodexAccount(request.accountName, remoteHost: request.remoteHost)
                pendingRemoteCodexSwitch = nil
                appendOutput(String(format: cabLocalized("远程新连接将使用 %@；正在运行的任务保留原账号并继续执行。请在任务完成后重新连接以使用新账号。\n"), request.accountName))
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func applyRemoteCodexSwitch(_ name: String, remoteHost: String) async throws {
        try await selectRemoteCodexAccount(name, remoteHost: remoteHost)
        await reload()
    }

    func selectRemoteCodexAccount(_ name: String, remoteHost: String) async throws {
        let arguments = ["remote", "use", name]
        output = "$ cab \(arguments.joined(separator: " "))\n"
        let recordID = tools.beginRecord(host: remoteHost, source: status.remoteAccount ?? "", destination: name)
        do {
            _ = try await switchRemoteAccountSafely(name) { arguments in
                try await service.execute(arguments, target: .remote, remoteHost: remoteHost) { [weak self] chunk in
                    Task { @MainActor in self?.appendOutput(chunk) }
                }
            }
            tools.record(recordID, stage: "新连接账号已更新，现有任务继续运行", outcome: "已完成")
        } catch {
            tools.record(recordID, stage: "账号选择未完成，请刷新确认", outcome: "结果待确认")
            throw error
        }
    }

    func setAgentSelection(service: String, account: String) {
        agentSelections[service] = account
    }

    func applyAgentBinding(_ request: AgentBindingRequest) {
        guard target == .remote, !isBusy else { return }
        var arguments = ["agent"]
        if let account = request.account, !account.isEmpty {
            arguments += ["bind", "--service", request.service, "--account", account]
        } else {
            arguments += ["unbind", "--service", request.service]
        }
        if request.active { arguments.append("--confirm-restart-agent") }
        run(arguments)
    }

    func applyAllAgentBindings(account: String) {
        guard target == .remote, !isBusy, !account.isEmpty else { return }
        run(["agent", "bind-all", "--account", account, "--confirm-restart-agent"])
    }

    func prepareSessionSharingChange(_ enabled: Bool) {
        guard !isBusy else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let report = try await service.loadCodexProcesses(target: target, remoteHost: remoteHost)
                if report.processes.isEmpty { try await applySessionSharingChange(enabled) }
                else { pendingRemoteSessionChange = RemoteSessionProcessRequest(enabled: enabled, processes: report.processes) }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stopProcessesAndApplySessionChange(_ request: RemoteSessionProcessRequest) {
        guard !isBusy else { return }
        Task {
            isBusy = true; defer { isBusy = false }
            do {
                try await service.stopCodexProcesses(
                    request.processes.map(\.pid),
                    target: target,
                    remoteHost: remoteHost,
                    forceAfterTimeout: true
                )
                try await applySessionSharingChange(request.enabled)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func applySessionSharingChange(_ enabled: Bool) async throws {
        let arguments = enabled ? ["sessions", "enable", "--acknowledge-cross-account-context", "--confirm-codex-stopped"] : ["sessions", "disable", "--confirm-codex-stopped"]
        output = "$ cab \(arguments.joined(separator: " "))\n"
        let result = try await service.execute(arguments, target: target, remoteHost: remoteHost) { [weak self] chunk in Task { @MainActor in self?.appendOutput(chunk) } }
        if result.exitCode != 0 { throw BridgeError.commandFailed(result.errorOutput.isEmpty ? result.output : result.errorOutput) }
        await reload()
    }

    func prepareLegacyImport() {
        guard target == .remote, !isBusy else { return }
        Task { isBusy = true; defer { isBusy = false }; do {
            let report = try await service.loadCodexProcesses(target: target, remoteHost: remoteHost)
            if report.processes.isEmpty { try await applyLegacyImport() } else { pendingLegacyProcesses = report.processes }
        } catch { errorMessage = error.localizedDescription } }
    }

    func stopProcessesAndImportLegacy(_ processes: [CodexProcessStatus]) {
        guard !isBusy else { return }
        Task { isBusy = true; defer { isBusy = false }; do {
            try await service.stopCodexProcesses(
                processes.map(\.pid),
                target: target,
                remoteHost: remoteHost,
                forceAfterTimeout: true
            )
            try await applyLegacyImport()
        } catch { errorMessage = error.localizedDescription } }
    }

    func applyLegacyImport() async throws {
        let arguments = ["sessions", "import-current", "--acknowledge-cross-account-context", "--confirm-codex-stopped"]
        output = "$ cab \(arguments.joined(separator: " "))\n"
        let result = try await service.execute(arguments, target: target, remoteHost: remoteHost)
        if result.exitCode != 0 { throw BridgeError.commandFailed(result.errorOutput.isEmpty ? result.output : result.errorOutput) }
        legacySessions = try await service.loadLegacySessions(remoteHost: remoteHost)
        await reload()
    }

    func remove(_ name: String) {
        run(["account", "remove", name], refreshUsageAfterSuccess: true) { [weak self] in
            if self?.selectedAccount == name { self?.selectedAccount = nil }
        }
    }

    func setRotationIncluded(_ name: String, included: Bool) {
        if included { rotationIncluded.insert(name) } else { rotationIncluded.remove(name) }
    }

    func moveRotation(_ name: String, offset: Int) {
        guard let index = rotationOrder.firstIndex(of: name) else { return }
        let destination = index + offset
        guard rotationOrder.indices.contains(destination) else { return }
        rotationOrder.swapAt(index, destination)
    }

    func saveRotation() {
        let ordered = rotationOrder.filter(rotationIncluded.contains)
        guard !ordered.isEmpty else {
            errorMessage = "请至少选择一个账号；开启自动轮换需要两个账号。"
            return
        }
        run(["rotation", "configure", "--accounts", ordered.joined(separator: ",")])
    }

    func setRotationEnabled(_ enabled: Bool) {
        if enabled {
            let ordered = rotationOrder.filter(rotationIncluded.contains)
            guard ordered.count >= 2 else {
                errorMessage = "开启自动轮换前，请至少选择两个账号。"
                return
            }
            runSequence([
                ["rotation", "configure", "--accounts", ordered.joined(separator: ",")],
                ["rotation", "enable"],
            ])
        } else {
            run(["rotation", "disable"])
        }
    }

    func resetRotation() { run(["rotation", "reset"]) }

    func launchCodex() {
        launchCodex(account: nil)
    }

    func launchCodex(account: String?) {
        do {
            try service.launchCodexInTerminal(target: target, remoteHost: remoteHost, accountName: account)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateCodex(target: BridgeTarget, remoteHost: String, label: String) {
        guard !isBusy, !isCodexUpdating else { return }
        let capturedTarget = target
        let capturedHost = remoteHost
        isCodexUpdating = true
        isBusy = true
        errorMessage = nil
        output = "$ cab update\n"
        Task {
            defer {
                isCodexUpdating = false
                isBusy = false
            }
            do {
                let result = try await service.updateCodex(
                    target: capturedTarget,
                    remoteHost: capturedHost,
                    onOutput: { [weak self] chunk in
                        Task { @MainActor in self?.appendOutput(chunk) }
                    }
                )
                appendOutput("\n\(label)更新完成。\n")
                if result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    appendOutput("官方 Codex 没有返回额外信息。\n")
                }
                await reload()
            } catch {
                errorMessage = "\(label)更新失败：\(error.localizedDescription)"
            }
        }
    }

    func applyDesktopSessionPreferenceIfNeeded(currentSharedSessions: Bool) async throws -> Bool {
        let modeChanged = preserveSessionsOnDesktopSwitch != currentSharedSessions
        guard modeChanged else { return false }
        if try await service.hasRunningCodexProcesses(target: .local, remoteHost: "") {
            throw BridgeError.commandFailed("检测到仍在运行的 Codex CLI 或编辑器任务。桌面端已关闭，请结束这些任务后重试，以免迁移中的会话文件被同时写入。")
        }
        let arguments = preserveSessionsOnDesktopSwitch
            ? ["sessions", "enable", "--acknowledge-cross-account-context", "--confirm-codex-stopped"]
            : ["sessions", "disable", "--confirm-codex-stopped"]
        appendOutput("$ cab \(arguments.joined(separator: " "))\n")
        let result = try await service.execute(arguments, target: .local, remoteHost: "") { [weak self] chunk in
            Task { @MainActor in self?.appendOutput(chunk) }
        }
        if result.exitCode != 0 {
            if let loaded = try? await service.loadStatus(target: .local, remoteHost: ""),
               loaded.sharedSessions == preserveSessionsOnDesktopSwitch {
                status = loaded
                return modeChanged
            }
            throw BridgeError.commandFailed(result.errorOutput.isEmpty ? result.output : result.errorOutput)
        }
        if let loaded = try? await service.loadStatus(target: .local, remoteHost: "") { status = loaded }
        return modeChanged
    }

    func previousDesktopHome(fallback: String) -> String {
        if let lastDesktopAccount,
           let account = status.accounts.first(where: { $0.name == lastDesktopAccount }) {
            return account.home
        }
        return status.currentLogin?.home ?? fallback
    }

    func reload(forceUsage: Bool = false) async {
        statusRefreshGeneration += 1
        let generation = statusRefreshGeneration
        isStatusRefreshing = true
        defer { if generation == statusRefreshGeneration { isStatusRefreshing = false } }
        isBusy = true
        let key = currentUsageCacheKey
        let capturedTarget = target
        let capturedHost = remoteHost
        do {
            let loaded = try await service.loadStatus(target: capturedTarget, remoteHost: capturedHost)
            guard key == currentUsageCacheKey, generation == statusRefreshGeneration else {
                if generation == statusRefreshGeneration { isBusy = false }
                return
            }
            status = loaded
            if capturedTarget == .remote {
                do {
                    let report = try await service.loadAgentBindings(remoteHost: capturedHost)
                    guard key == currentUsageCacheKey, generation == statusRefreshGeneration else { if generation == statusRefreshGeneration { isBusy = false }; return }
                    agentBindings = report.agents
                    agentSelections = Dictionary(uniqueKeysWithValues: report.agents.map { ($0.service, $0.account ?? "") })
                    let loggedInNames = Set(loaded.accounts.filter(\.isLoggedIn).map(\.name))
                    if !loggedInNames.contains(bulkAgentAccount) {
                        bulkAgentAccount = loaded.remoteAccount.flatMap { loggedInNames.contains($0) ? $0 : nil }
                            ?? loaded.defaultAccount.flatMap { loggedInNames.contains($0) ? $0 : nil }
                            ?? loaded.accounts.first(where: \.isLoggedIn)?.name
                            ?? ""
                    }
                    agentBindingError = nil
                    legacySessions = loaded.sharedSessions ? try? await service.loadLegacySessions(remoteHost: capturedHost) : nil
                } catch {
                    guard key == currentUsageCacheKey, generation == statusRefreshGeneration else { return }
                    agentBindings = []
                    agentBindingError = error.localizedDescription
                    legacySessions = nil
                }
            } else {
                agentBindings = []
                agentSelections = [:]
                bulkAgentAccount = ""
                agentBindingError = nil
                legacySessions = nil
            }
            guard key == currentUsageCacheKey, generation == statusRefreshGeneration else { return }
            if let loginAccountName,
               loaded.accounts.first(where: { $0.name == loginAccountName })?.isLoggedIn == true {
                markLoginStatusConfirmed(accountName: loginAccountName)
            }
            if !hasSavedDesktopSessionPreference && capturedTarget == .local {
                preserveSessionsOnDesktopSwitch = loaded.sharedSessions
            }
            if !showingGlobalSettings && !showingTools && !loaded.accounts.contains(where: { $0.name == selectedAccount }) {
                selectedAccount = loaded.defaultAccount ?? loaded.accounts.first?.name
            }
            let configured = loaded.rotation.orderedAccounts
            rotationOrder = configured + loaded.accounts.map(\.name).filter { !configured.contains($0) }
            rotationIncluded = Set(configured)
            errorMessage = nil
            isBusy = false
            async let usage: () = reloadUsage(force: forceUsage)
            async let tokens: () = reloadTokenUsage(force: forceUsage)
            async let update: () = reloadCodexUpdateStatus(force: forceUsage)
            _ = await (usage, tokens, update)
        } catch {
            guard key == currentUsageCacheKey, generation == statusRefreshGeneration else { return }
            if error is CancellationError { isBusy = false; return }
            errorMessage = error.localizedDescription
            isBusy = false
        }
    }

    func persistRemoteServers() {
        if let data = try? JSONEncoder().encode(remoteServers) {
            defaults.set(data, forKey: remoteServersKey)
        }
        if let selectedRemoteID {
            defaults.set(selectedRemoteID.uuidString, forKey: selectedRemoteKey)
        } else {
            defaults.removeObject(forKey: selectedRemoteKey)
        }
    }

    static let emptyStatus = BridgeStatus(sharedSessions: false, rotation: RotationStatus(enabled: false, accounts: [], nextIndex: 0), currentLogin: nil, accounts: [])
    static let globalSettingsSelection = "__cab_global_settings__"

    func run(
        _ arguments: [String],
        loginBrowser: LoginBrowser? = nil,
        loginAccount: String? = nil,
        refreshUsageAfterSuccess: Bool = false,
        afterSuccess: (() -> Void)? = nil
    ) {
        guard !isBusy else { return }
        Task {
            isBusy = true
            let capturedTarget = target
            let capturedHost = remoteHost
            let capturedKey = currentUsageCacheKey
            let shouldWaitForNewLogin = loginAccount.map { accountName in
                status.accounts.first(where: { $0.name == accountName })?.isLoggedIn != true
            } ?? false
            output = "$ cab \(arguments.joined(separator: " "))\n"
            loginOutputBuffer = ""
            loginBrowserOpened = false
            if let loginAccount {
                beginLoginStatusMonitoring(accountName: loginAccount)
            }
            do {
                let result = try await service.execute(arguments, target: capturedTarget, remoteHost: capturedHost) { [weak self] chunk in
                    Task { @MainActor in self?.receiveOutput(chunk, loginBrowser: loginBrowser) }
                }
                if result.exitCode != 0 {
                    throw BridgeError.commandFailed(result.errorOutput.isEmpty ? result.output : result.errorOutput)
                }
                afterSuccess?()
                loginStatusMonitor?.cancel()
                loginStatusMonitor = nil
                if let loginAccount, shouldWaitForNewLogin, !loginStatusConfirmed {
                    for _ in 0..<8 {
                        if await detectCompletedLogin(
                            accountName: loginAccount,
                            target: capturedTarget,
                            remoteHost: capturedHost,
                            usageKey: capturedKey
                        ) {
                            break
                        }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
                await reload(forceUsage: refreshUsageAfterSuccess)
                if loginAccount != nil { clearLoginProgress() }
            } catch {
                if loginAccount != nil { clearLoginProgress() }
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    func beginLoginStatusMonitoring(accountName: String) {
        loginStatusMonitor?.cancel()
        loginAccountName = accountName
        loginStatusConfirmed = false
        let accountWasLoggedIn = status.accounts.first(where: { $0.name == accountName })?.isLoggedIn == true
        canManuallyCheckLogin = !accountWasLoggedIn
        guard !accountWasLoggedIn else { return }

        let capturedTarget = target
        let capturedHost = remoteHost
        let capturedKey = currentUsageCacheKey
        loginStatusMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 750_000_000)
                } catch {
                    return
                }
                guard let self else { return }
                if await self.detectCompletedLogin(
                    accountName: accountName,
                    target: capturedTarget,
                    remoteHost: capturedHost,
                    usageKey: capturedKey
                ) {
                    return
                }
            }
        }
    }

    func detectCompletedLogin(
        accountName: String,
        target: BridgeTarget,
        remoteHost: String,
        usageKey: String
    ) async -> Bool {
        guard loginAccountName == accountName, usageKey == currentUsageCacheKey else { return true }
        do {
            let loaded = try await service.loadStatus(target: target, remoteHost: remoteHost)
            guard loginAccountName == accountName, usageKey == currentUsageCacheKey else { return true }
            status = loaded
            guard loaded.accounts.first(where: { $0.name == accountName })?.isLoggedIn == true else { return false }
            markLoginStatusConfirmed(accountName: accountName)
            return true
        } catch {
            return false
        }
    }

    func markLoginStatusConfirmed(accountName: String) {
        guard loginAccountName == accountName else { return }
        if !loginStatusConfirmed {
            appendOutput("\n已检测到官方 Codex 登录成功，正在完成状态与额度更新…\n")
        }
        loginStatusConfirmed = true
        canManuallyCheckLogin = false
    }

    func clearLoginProgress() {
        loginStatusMonitor?.cancel()
        loginStatusMonitor = nil
        loginAccountName = nil
        loginStatusConfirmed = false
        canManuallyCheckLogin = false
    }

    func receiveOutput(_ chunk: String, loginBrowser: LoginBrowser?) {
        appendOutput(chunk)
        guard let loginBrowser, !loginBrowserOpened else { return }
        loginOutputBuffer += chunk
        if loginOutputBuffer.count > 256_000 {
            loginOutputBuffer = String(loginOutputBuffer.suffix(256_000))
        }
        guard let url = service.officialLoginURL(in: loginOutputBuffer) else { return }
        do {
            let destination: String
            switch loginBrowser {
            case .systemDefault:
                try service.openDefaultBrowser(url: url)
                destination = "系统默认浏览器"
                loginBrowserOpened = true
                appendOutput("\n已在\(destination)打开官方设备登录页面，请输入上方的一次性代码。\n")
            case let .selected(browser, privateWindow):
                try service.openBrowser(browser, url: url, privateWindow: privateWindow)
                destination = privateWindow ? "\(browser.title) 无痕窗口" : browser.title
                loginBrowserOpened = true
                appendOutput("\n已在\(destination)打开官方 ChatGPT 登录页面。\n")
            }
        } catch {
            loginBrowserOpened = true
            errorMessage = error.localizedDescription
        }
    }

    func appendOutput(_ text: String) {
        output += text
        if output.count > Self.maximumOutputCharacters {
            output = "… 较早的输出已截断 …\n" + String(output.suffix(Self.maximumOutputCharacters))
        }
    }

    func runSequence(_ commands: [[String]]) {
        Task {
            isBusy = true
            output = ""
            do {
                for arguments in commands {
                    appendOutput("$ cab \(arguments.joined(separator: " "))\n")
                    let result = try await service.execute(arguments, target: target, remoteHost: remoteHost) { [weak self] chunk in
                        Task { @MainActor in self?.appendOutput(chunk) }
                    }
                    if result.exitCode != 0 {
                        throw BridgeError.commandFailed(result.errorOutput.isEmpty ? result.output : result.errorOutput)
                    }
                }
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }
}

func desktopSwitchWarning(
    stage: String,
    sourcePath: String,
    targetPath: String,
    error: Error
) -> DesktopSwitchWarning {
    DesktopSwitchWarning(
        stage: stage,
        sourcePath: URL(fileURLWithPath: sourcePath, isDirectory: true).standardizedFileURL.path,
        targetPath: URL(fileURLWithPath: targetPath, isDirectory: true).standardizedFileURL.path,
        detail: error.localizedDescription
    )
}

func desktopSwitchStopFailureMessage(
    stopError: Error?,
    remaining: [CodexProcessConflict]
) -> String {
    let pids = remaining.map { String($0.pid) }.joined(separator: ", ")
    if remaining.contains(where: { $0.label == "VS Code 的 Codex 扩展" }) {
        return String(
            format: cabLocalized("VS Code 的 Codex 扩展仍在运行（PID %@）。它可能拒绝退出或被 VS Code 自动重新启动；请先在 VS Code 中停止该扩展或退出 VS Code，然后重试。"),
            pids
        )
    }
    let detail = stopError.map { " \($0.localizedDescription)" } ?? ""
    return (String(format: cabLocalized("仍有 Codex 进程未退出（PID %@）。"), pids) + detail)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
