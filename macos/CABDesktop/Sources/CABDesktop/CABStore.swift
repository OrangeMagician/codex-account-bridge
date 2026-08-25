import Foundation
import SwiftUI

private enum LoginBrowser {
    case systemDefault
    case selected(BrowserChoice, privateWindow: Bool)
}

@MainActor
final class CABStore: ObservableObject {
    @Published var target: BridgeTarget = .local
    @Published var status = BridgeStatus(sharedSessions: false, rotation: RotationStatus(enabled: false, accounts: [], nextIndex: 0), currentLogin: nil, accounts: [])
    @Published var selectedAccount: String?
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
    @Published var showingGlobalSettings = true
    @Published var lastDesktopAccount: String?

    private let service = CABService()
    private let defaults = UserDefaults.standard
    private let remoteServersKey = "remoteServers.v1"
    private let selectedRemoteKey = "selectedRemoteServer.v1"
    private let lastDesktopAccountKey = "lastDesktopAccount.v1"
    private var loginOutputBuffer = ""
    private var loginBrowserOpened = false

    init() {
        lastDesktopAccount = defaults.string(forKey: lastDesktopAccountKey)
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

    var canImportCurrentLogin: Bool {
        status.currentLogin?.isLoggedIn == true && status.currentLogin?.isRegistered == false
    }

    var sidebarSelection: String? {
        get { showingGlobalSettings ? Self.globalSettingsSelection : selectedAccount }
        set {
            if newValue == Self.globalSettingsSelection {
                showingGlobalSettings = true
            } else {
                showingGlobalSettings = false
                selectedAccount = newValue
            }
        }
    }

    var defaultDesktopAccount: String? { status.currentLogin?.registeredAs }

    func usesDefaultCodexHome(_ account: AccountStatus) -> Bool {
        account.home == status.currentLogin?.home
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

    func changeTarget(_ next: BridgeTarget) {
        target = next
        selectedAccount = nil
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
        run(["account", "add", name]) { [weak self] in
            self?.newAccountName = ""
            self?.selectedAccount = name
            self?.showingGlobalSettings = false
        }
    }

    func importCurrentLogin() {
        let name = existingAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil else {
            errorMessage = BridgeError.invalidAccountName.localizedDescription
            return
        }
        run(["account", "import-current", name]) { [weak self] in
            self?.selectedAccount = name
            self?.showingGlobalSettings = false
        }
    }

    func loginInDefaultBrowser(_ name: String) { run(["login", name]) }
    func loginWithDeviceCode(_ name: String) {
        run(["login", "--device-auth", name], loginBrowser: .systemDefault)
    }
    func loginInBrowser(_ name: String, browser: BrowserChoice) {
        run(["login", "--browser-auth", name], loginBrowser: .selected(browser, privateWindow: false))
    }
    func loginPrivately(_ name: String, browser: BrowserChoice) {
        run(["login", "--browser-auth", name], loginBrowser: .selected(browser, privateWindow: true))
    }

    func setDefault(_ name: String) { run(["use", name]) }
    func setRemote(_ name: String) { run(["remote", "use", name]) }

    func switchCodexDesktop(to account: AccountStatus) {
        guard target == .local, account.isLoggedIn else {
            errorMessage = "只能用这台 Mac 上已登录的账号启动 Codex 桌面客户端。"
            return
        }
        guard !isBusy else { return }
        Task {
            isBusy = true
            output = "正在关闭 Codex 桌面客户端，并使用 \(account.name) 的独立 CODEX_HOME 重新启动…\n"
            do {
                try await service.restartCodexDesktop(codexHome: account.home)
                lastDesktopAccount = account.name
                defaults.set(account.name, forKey: lastDesktopAccountKey)
                output += "已使用账号 \(account.name) 启动 Codex 桌面客户端。\n"
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    func setSessionSharingEnabled(_ enabled: Bool) {
        guard !isBusy else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                if try await service.hasRunningCodexProcesses(target: target, remoteHost: remoteHost) {
                    throw BridgeError.commandFailed("检测到目标机器仍有 Codex 在运行。请退出桌面端、CLI 和编辑器插件后，再修改会话共享。")
                }
                let arguments = enabled
                    ? ["sessions", "enable", "--acknowledge-cross-account-context", "--confirm-codex-stopped"]
                    : ["sessions", "disable", "--confirm-codex-stopped"]
                output = "$ cab \(arguments.joined(separator: " "))\n"
                let result = try await service.execute(arguments, target: target, remoteHost: remoteHost) { [weak self] chunk in
                    Task { @MainActor in self?.output += chunk }
                }
                if result.exitCode != 0 {
                    throw BridgeError.commandFailed(result.errorOutput.isEmpty ? result.output : result.errorOutput)
                }
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func remove(_ name: String) {
        run(["account", "remove", name]) { [weak self] in
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

    private func reload() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let loaded = try await service.loadStatus(target: target, remoteHost: remoteHost)
            status = loaded
            if selectedAccount == nil || !loaded.accounts.contains(where: { $0.name == selectedAccount }) {
                selectedAccount = loaded.defaultAccount ?? loaded.accounts.first?.name
            }
            let configured = loaded.rotation.orderedAccounts
            rotationOrder = configured + loaded.accounts.map(\.name).filter { !configured.contains($0) }
            rotationIncluded = Set(configured)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
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

    private func run(_ arguments: [String], loginBrowser: LoginBrowser? = nil, afterSuccess: (() -> Void)? = nil) {
        guard !isBusy else { return }
        Task {
            isBusy = true
            output = "$ cab \(arguments.joined(separator: " "))\n"
            loginOutputBuffer = ""
            loginBrowserOpened = false
            do {
                let result = try await service.execute(arguments, target: target, remoteHost: remoteHost) { [weak self] chunk in
                    Task { @MainActor in self?.receiveOutput(chunk, loginBrowser: loginBrowser) }
                }
                if result.exitCode != 0 {
                    throw BridgeError.commandFailed(result.errorOutput.isEmpty ? result.output : result.errorOutput)
                }
                afterSuccess?()
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func receiveOutput(_ chunk: String, loginBrowser: LoginBrowser?) {
        output += chunk
        guard let loginBrowser, !loginBrowserOpened else { return }
        loginOutputBuffer += chunk
        guard let url = service.officialLoginURL(in: loginOutputBuffer) else { return }
        do {
            let destination: String
            switch loginBrowser {
            case .systemDefault:
                try service.openDefaultBrowser(url: url)
                destination = "系统默认浏览器"
                loginBrowserOpened = true
                output += "\n已在\(destination)打开官方设备登录页面，请输入上方的一次性代码。\n"
            case let .selected(browser, privateWindow):
                try service.openBrowser(browser, url: url, privateWindow: privateWindow)
                destination = privateWindow ? "\(browser.title) 无痕窗口" : browser.title
                loginBrowserOpened = true
                output += "\n已在\(destination)打开官方 ChatGPT 登录页面。\n"
            }
        } catch {
            loginBrowserOpened = true
            errorMessage = error.localizedDescription
        }
    }

    private func runSequence(_ commands: [[String]]) {
        Task {
            isBusy = true
            output = ""
            do {
                for arguments in commands {
                    output += "$ cab \(arguments.joined(separator: " "))\n"
                    let result = try await service.execute(arguments, target: target, remoteHost: remoteHost) { [weak self] chunk in
                        Task { @MainActor in self?.output += chunk }
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
