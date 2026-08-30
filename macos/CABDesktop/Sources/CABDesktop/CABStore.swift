import Foundation
import SwiftUI

private enum LoginBrowser {
    case systemDefault
    case selected(BrowserChoice, privateWindow: Bool)
}

private struct UsageCacheEntry {
    let reports: [String: AccountUsageReport]
    let fetchedAt: Date?
    let checkedAt: Date
    let error: String?
}

@MainActor
final class CABStore: ObservableObject {
    private static let maximumOutputCharacters = 500_000
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
    @Published var remoteServers: [RemoteServer] = []
    @Published var selectedRemoteID: UUID?
    @Published var showServerManager = false
    @Published var lastDesktopAccount: String?
    @Published var preserveSessionsOnDesktopSwitch = false
    @Published var usageRefreshInterval: UsageRefreshInterval = .fifteenMinutes
    @Published var usageByAccount: [String: AccountUsageReport] = [:]
    @Published var usageFetchedAt: Date?
    @Published var usageLoadError: String?
    @Published var isUsageRefreshing = false
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

    private let service = CABService()
    private let defaults = UserDefaults.standard
    private let remoteServersKey = "remoteServers.v1"
    private let selectedRemoteKey = "selectedRemoteServer.v1"
    private let lastDesktopAccountKey = "lastDesktopAccount.v1"
    private let preserveSessionsKey = "preserveSessionsOnDesktopSwitch.v1"
    private let usageRefreshIntervalKey = "usageRefreshInterval.v1"
    private var hasSavedDesktopSessionPreference = false
    private var loginOutputBuffer = ""
    private var loginBrowserOpened = false
    private var loginStatusMonitor: Task<Void, Never>?
    private var usageCacheByKey: [String: UsageCacheEntry] = [:]
    private var usageRefreshingKeys: Set<String> = []

    init() {
        lastDesktopAccount = defaults.string(forKey: lastDesktopAccountKey)
        hasSavedDesktopSessionPreference = defaults.object(forKey: preserveSessionsKey) != nil
        preserveSessionsOnDesktopSwitch = defaults.bool(forKey: preserveSessionsKey)
        if let savedInterval = UsageRefreshInterval(rawValue: defaults.integer(forKey: usageRefreshIntervalKey)),
           defaults.object(forKey: usageRefreshIntervalKey) != nil {
            usageRefreshInterval = savedInterval
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
        get { showingGlobalSettings ? nil : sidebarSelection }
        set { sidebarSelection = newValue ?? Self.globalSettingsSelection }
    }

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

    func refresh() {
        Task { await reload() }
    }

    func refreshUsage() {
        Task { await reloadUsage(force: true) }
    }

    func setUsageRefreshInterval(_ interval: UsageRefreshInterval) {
        usageRefreshInterval = interval
        defaults.set(interval.rawValue, forKey: usageRefreshIntervalKey)
        Task { await reloadUsage(force: false) }
    }

    func setPreserveSessionsOnDesktopSwitch(_ enabled: Bool) {
        preserveSessionsOnDesktopSwitch = enabled
        hasSavedDesktopSessionPreference = true
        defaults.set(enabled, forKey: preserveSessionsKey)
    }

    func changeTarget(_ next: BridgeTarget) {
        target = next
        selectedAccount = nil
        restoreUsageForCurrentTarget()
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
        selectedAccount = nil
        restoreUsageForCurrentTarget()
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

    func stopProcessesAndSwitchRemoteCodex(_ request: RemoteCodexSwitchRequest) {
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
                do {
                    try await service.stopCodexProcesses(
                        request.processes.map(\.pid),
                        target: .remote,
                        remoteHost: request.remoteHost
                    )
                } catch {
                    let remaining = try await service.loadRemoteSwitchCodexProcesses(remoteHost: request.remoteHost)
                    if remaining.contains(where: { request.processes.map(\.pid).contains($0.pid) }) {
                        throw error
                    }
                }
                let remaining = try await service.loadRemoteSwitchCodexProcesses(remoteHost: request.remoteHost)
                if remaining.isEmpty {
                    pendingRemoteCodexSwitch = nil
                    try await applyRemoteCodexSwitch(request.accountName, remoteHost: request.remoteHost)
                } else {
                    pendingRemoteCodexSwitch = RemoteCodexSwitchRequest(
                        remoteHost: request.remoteHost,
                        accountName: request.accountName,
                        processes: remaining
                    )
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applyRemoteCodexSwitch(_ name: String, remoteHost: String) async throws {
        let arguments = ["remote", "use", name]
        output = "$ cab \(arguments.joined(separator: " "))\n"
        let result = try await service.execute(arguments, target: .remote, remoteHost: remoteHost) { [weak self] chunk in
            Task { @MainActor in self?.appendOutput(chunk) }
        }
        guard result.exitCode == 0 else {
            throw BridgeError.commandFailed(result.errorOutput.isEmpty ? result.output : result.errorOutput)
        }
        await reload()
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

    func switchCodexDesktop(to account: AccountStatus) {
        guard target == .local, account.isLoggedIn else {
            errorMessage = "只能用这台 Mac 上已登录的账号启动 Codex 桌面客户端。"
            return
        }
        guard !isUsageRefreshing else {
            errorMessage = "正在读取额度，请等待当前官方 Codex 查询结束后再切换桌面账号。"
            return
        }
        guard !isBusy else { return }
        performDesktopSwitch(to: account, checkProcesses: true)
    }

    func closeProcessesAndContinueDesktopSwitch(_ request: DesktopSwitchProcessRequest) {
        guard !isBusy else { return }
        Task {
            isBusy = true
            errorMessage = nil
            do {
                try await service.stopLocalCodexProcesses(request.processes.map(\.pid))
                let remaining = try await service.runningNonDesktopCodexProcesses(knownHomes: status.accounts.map(\.home))
                isBusy = false
                if remaining.isEmpty {
                    pendingDesktopSwitch = nil
                    performDesktopSwitch(to: request.account, checkProcesses: true)
                } else {
                    pendingDesktopSwitch = DesktopSwitchProcessRequest(account: request.account, processes: remaining)
                }
            } catch {
                isBusy = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performDesktopSwitch(to account: AccountStatus, checkProcesses: Bool) {
        guard !isBusy else { return }
        Task {
            isBusy = true
            errorMessage = nil
            var desktopWasStopped = false
            var workspaceSync: CodexWorkspaceSyncResult?
            var threadIndexBackup: URL?
            var sessionModeChanged = false
            var originalSharedSessions = status.sharedSessions
            var fallbackHome = previousDesktopHome(fallback: account.home)
            let sessionMode = preserveSessionsOnDesktopSwitch ? "保留项目与共享会话" : "保持项目与会话独立"
            output = "正在检查切换条件，准备应用“\(sessionMode)”设置…\n"
            do {
                let liveStatus = try await service.loadStatus(target: .local, remoteHost: "")
                status = liveStatus
                originalSharedSessions = liveStatus.sharedSessions
                fallbackHome = previousDesktopHome(fallback: account.home)
                if checkProcesses && (preserveSessionsOnDesktopSwitch || preserveSessionsOnDesktopSwitch != liveStatus.sharedSessions) {
                    let conflicts = try await service.runningNonDesktopCodexProcesses(knownHomes: liveStatus.accounts.map(\.home))
                    if !conflicts.isEmpty {
                        pendingDesktopSwitch = DesktopSwitchProcessRequest(account: account, processes: conflicts)
                        isBusy = false
                        return
                    }
                }
                appendOutput("预检通过，正在关闭 Codex 桌面客户端并切换账号…\n")
                try await service.stopCodexDesktop()
                desktopWasStopped = true
                sessionModeChanged = try await applyDesktopSessionPreferenceIfNeeded(currentSharedSessions: originalSharedSessions)
                if preserveSessionsOnDesktopSwitch {
                    workspaceSync = try service.synchronizeCodexWorkspaceState(
                        sourceHome: fallbackHome,
                        targetHome: account.home,
                        knownHomes: status.accounts.map(\.home)
                    )
                    if let workspaceSync {
                        let backupMessage = workspaceSync.backupURL.map { "，原状态已备份为 \($0.lastPathComponent)" } ?? ""
                        appendOutput("已同步 \(workspaceSync.projectCount) 个桌面项目及会话归属\(backupMessage)。\n")
                    }
                }
                if preserveSessionsOnDesktopSwitch || sessionModeChanged,
                   let backup = try await service.prepareCodexThreadIndexRebuild(codexHome: account.home) {
                    threadIndexBackup = backup
                    appendOutput("已备份线程索引到 \(backup.lastPathComponent)，官方 Codex 将从会话文件重建可见对话列表。\n")
                }
                try await service.startCodexDesktop(codexHome: account.home)
                desktopWasStopped = false
                lastDesktopAccount = account.name
                defaults.set(account.name, forKey: lastDesktopAccountKey)
                appendOutput("已使用账号 \(account.name) 启动 Codex 桌面客户端；\(preserveSessionsOnDesktopSwitch ? "项目和会话历史已保留" : "项目和会话保持独立")。\n")
            } catch {
                var message = error.localizedDescription
                if desktopWasStopped {
                    if let workspaceSync {
                        do {
                            try service.restoreCodexWorkspaceState(workspaceSync)
                            appendOutput("切换未完成，已恢复目标账号原有的项目状态。\n")
                        } catch {
                            message += "\n同时无法自动恢复目标账号的项目状态：\(error.localizedDescription)"
                        }
                    }
                    if let threadIndexBackup {
                        do {
                            try service.restoreCodexThreadIndex(backupURL: threadIndexBackup, codexHome: account.home)
                            appendOutput("切换未完成，已恢复目标账号原有的线程索引。\n")
                        } catch {
                            message += "\n同时无法自动恢复目标账号的线程索引：\(error.localizedDescription)"
                        }
                    }
                    if sessionModeChanged {
                        let arguments = originalSharedSessions
                            ? ["sessions", "enable", "--acknowledge-cross-account-context", "--confirm-codex-stopped"]
                            : ["sessions", "disable", "--confirm-codex-stopped"]
                        do {
                            let result = try await service.execute(arguments, target: .local, remoteHost: "")
                            if result.exitCode != 0 {
                                let loaded = try? await service.loadStatus(target: .local, remoteHost: "")
                                guard loaded?.sharedSessions == originalSharedSessions else {
                                    throw BridgeError.commandFailed(result.errorOutput.isEmpty ? result.output : result.errorOutput)
                                }
                            }
                            if let loaded = try? await service.loadStatus(target: .local, remoteHost: "") { status = loaded }
                            appendOutput("切换未完成，已恢复原有的项目与会话保留设置。\n")
                        } catch {
                            message += "\n同时无法自动恢复会话保留设置：\(error.localizedDescription)"
                        }
                    }
                    do {
                        try await service.startCodexDesktop(codexHome: fallbackHome)
                        appendOutput("切换未完成，已重新启动原 Codex 桌面账号。\n")
                    } catch {
                        message += "\n同时无法自动恢复 Codex 桌面客户端：\(error.localizedDescription)"
                    }
                }
                errorMessage = message
            }
            isBusy = false
        }
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
                try await service.stopCodexProcesses(request.processes.map(\.pid), target: target, remoteHost: remoteHost)
                try await applySessionSharingChange(request.enabled)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func applySessionSharingChange(_ enabled: Bool) async throws {
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
            try await service.stopCodexProcesses(processes.map(\.pid), target: target, remoteHost: remoteHost)
            try await applyLegacyImport()
        } catch { errorMessage = error.localizedDescription } }
    }

    private func applyLegacyImport() async throws {
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
        do {
            try service.launchCodexInTerminal(target: target, remoteHost: remoteHost)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyDesktopSessionPreferenceIfNeeded(currentSharedSessions: Bool) async throws -> Bool {
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

    private func previousDesktopHome(fallback: String) -> String {
        if let lastDesktopAccount,
           let account = status.accounts.first(where: { $0.name == lastDesktopAccount }) {
            return account.home
        }
        return status.currentLogin?.home ?? fallback
    }

    private func reload(forceUsage: Bool = false) async {
        isBusy = true
        let key = currentUsageCacheKey
        let capturedTarget = target
        let capturedHost = remoteHost
        do {
            let loaded = try await service.loadStatus(target: capturedTarget, remoteHost: capturedHost)
            guard key == currentUsageCacheKey else {
                isBusy = false
                return
            }
            status = loaded
            if capturedTarget == .remote {
                do {
                    let report = try await service.loadAgentBindings(remoteHost: capturedHost)
                    guard key == currentUsageCacheKey else { isBusy = false; return }
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
            if let loginAccountName,
               loaded.accounts.first(where: { $0.name == loginAccountName })?.isLoggedIn == true {
                markLoginStatusConfirmed(accountName: loginAccountName)
            }
            if !hasSavedDesktopSessionPreference && capturedTarget == .local {
                preserveSessionsOnDesktopSwitch = loaded.sharedSessions
            }
            if !showingGlobalSettings && !loaded.accounts.contains(where: { $0.name == selectedAccount }) {
                selectedAccount = loaded.defaultAccount ?? loaded.accounts.first?.name
            }
            let configured = loaded.rotation.orderedAccounts
            rotationOrder = configured + loaded.accounts.map(\.name).filter { !configured.contains($0) }
            rotationIncluded = Set(configured)
            errorMessage = nil
            isBusy = false
            await reloadUsage(force: forceUsage)
        } catch {
            errorMessage = error.localizedDescription
            isBusy = false
        }
    }

    private func reloadUsage(force: Bool) async {
        let key = currentUsageCacheKey
        if let cached = usageCacheByKey[key] {
            applyUsageCache(cached)
            if !force {
                guard let duration = usageRefreshInterval.duration else { return }
                if Date().timeIntervalSince(cached.checkedAt) < duration { return }
            }
        } else if !force && usageRefreshInterval == .manual {
            applyUsageCache(nil)
            return
        }
        guard !usageRefreshingKeys.contains(key) else { return }
        usageRefreshingKeys.insert(key)
        isUsageRefreshing = true
        defer {
            usageRefreshingKeys.remove(key)
            isUsageRefreshing = !usageRefreshingKeys.isEmpty
        }
        let capturedTarget = target
        let capturedHost = remoteHost
        do {
            let report = try await service.loadUsage(target: capturedTarget, remoteHost: capturedHost)
            let entry = UsageCacheEntry(
                reports: Dictionary(uniqueKeysWithValues: report.accounts.map { ($0.name, $0) }),
                fetchedAt: report.fetchedAt,
                checkedAt: Date(),
                error: nil
            )
            usageCacheByKey[key] = entry
            if key == currentUsageCacheKey { applyUsageCache(entry) }
        } catch {
            let previous = usageCacheByKey[key]
            let entry = UsageCacheEntry(
                reports: previous?.reports ?? [:],
                fetchedAt: previous?.fetchedAt,
                checkedAt: Date(),
                error: error.localizedDescription
            )
            usageCacheByKey[key] = entry
            if key == currentUsageCacheKey { applyUsageCache(entry) }
        }
    }

    private var currentUsageCacheKey: String {
        switch target {
        case .local:
            return "local"
        case .remote:
            return "remote:\(selectedRemoteID?.uuidString ?? remoteHost)"
        }
    }

    private func restoreUsageForCurrentTarget() {
        applyUsageCache(usageCacheByKey[currentUsageCacheKey])
    }

    private func applyUsageCache(_ entry: UsageCacheEntry?) {
        usageByAccount = entry?.reports ?? [:]
        usageFetchedAt = entry?.fetchedAt
        usageLoadError = entry?.error
    }

    private func persistRemoteServers() {
        if let data = try? JSONEncoder().encode(remoteServers) {
            defaults.set(data, forKey: remoteServersKey)
        }
        if let selectedRemoteID {
            defaults.set(selectedRemoteID.uuidString, forKey: selectedRemoteKey)
        } else {
            defaults.removeObject(forKey: selectedRemoteKey)
        }
    }

    private static let emptyStatus = BridgeStatus(sharedSessions: false, rotation: RotationStatus(enabled: false, accounts: [], nextIndex: 0), currentLogin: nil, accounts: [])
    static let globalSettingsSelection = "__cab_global_settings__"

    private func run(
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

    private func beginLoginStatusMonitoring(accountName: String) {
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

    private func detectCompletedLogin(
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

    private func markLoginStatusConfirmed(accountName: String) {
        guard loginAccountName == accountName else { return }
        if !loginStatusConfirmed {
            appendOutput("\n已检测到官方 Codex 登录成功，正在完成状态与额度更新…\n")
        }
        loginStatusConfirmed = true
        canManuallyCheckLogin = false
    }

    private func clearLoginProgress() {
        loginStatusMonitor?.cancel()
        loginStatusMonitor = nil
        loginAccountName = nil
        loginStatusConfirmed = false
        canManuallyCheckLogin = false
    }

    private func receiveOutput(_ chunk: String, loginBrowser: LoginBrowser?) {
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

    private func appendOutput(_ text: String) {
        output += text
        if output.count > Self.maximumOutputCharacters {
            output = "… 较早的输出已截断 …\n" + String(output.suffix(Self.maximumOutputCharacters))
        }
    }

    private func runSequence(_ commands: [[String]]) {
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

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
