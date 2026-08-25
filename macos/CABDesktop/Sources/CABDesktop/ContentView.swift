import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: CABStore
    @State private var pendingDesktopSwitch: AccountStatus?
    @State private var pendingSessionSharing: Bool?
    @State private var pendingReauthentication: ReauthenticationRequest?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    targetHeader
                    if store.showingGlobalSettings {
                        globalSettingsPage
                    } else {
                        if store.canImportCurrentLogin { existingLoginCard }
                        if let account = store.selectedAccountStatus {
                            accountCard(account)
                        } else {
                            emptyAccountCard
                        }
                    }
                    if !store.output.isEmpty { outputCard }
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 620)
        .toolbar {
            ToolbarItemGroup {
                Button(action: store.refresh) { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(store.isBusy)
                Button(action: store.launchCodex) { Label("在终端启动", systemImage: "terminal") }
                    .keyboardShortcut("r", modifiers: [.command])
            }
        }
        .overlay {
            if store.isBusy {
                ProgressView().controlSize(.small).padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "未知错误")
        }
        .sheet(isPresented: $store.showServerManager) {
            ServerManagerView()
                .environmentObject(store)
        }
        .confirmationDialog("切换 Codex 桌面账号？", isPresented: Binding(get: { pendingDesktopSwitch != nil }, set: { if !$0 { pendingDesktopSwitch = nil } }), titleVisibility: .visible) {
            Button("关闭桌面端并切换", role: .destructive) {
                if let account = pendingDesktopSwitch { store.switchCodexDesktop(to: account) }
                pendingDesktopSwitch = nil
            }
            Button("取消", role: .cancel) { pendingDesktopSwitch = nil }
        } message: {
            Text("这会关闭正在运行的 Codex/ChatGPT 桌面客户端和其中的活动任务，再以所选账号的独立 CODEX_HOME 重新启动。请先保存正在进行的工作。")
        }
        .confirmationDialog("更改会话共享？", isPresented: Binding(get: { pendingSessionSharing != nil }, set: { if !$0 { pendingSessionSharing = nil } }), titleVisibility: .visible) {
            Button(pendingSessionSharing == true ? "确认共享会话" : "确认恢复独立") {
                if let enabled = pendingSessionSharing { store.setSessionSharingEnabled(enabled) }
                pendingSessionSharing = nil
            }
            Button("取消", role: .cancel) { pendingSessionSharing = nil }
        } message: {
            Text("操作前必须退出所有 Codex 进程。共享后不同账号可以看到同一份任务历史，其中可能包含另一个账号的上下文。")
        }
        .confirmationDialog("重新登录账号？", isPresented: Binding(get: { pendingReauthentication != nil }, set: { if !$0 { pendingReauthentication = nil } }), titleVisibility: .visible) {
            Button("继续官方登录", role: .destructive) {
                if let request = pendingReauthentication { startReauthentication(request) }
                pendingReauthentication = nil
            }
            Button("取消", role: .cancel) { pendingReauthentication = nil }
        } message: {
            Text(reauthenticationWarning)
        }
        .task { await MainActor.run { store.refresh() } }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("管理位置", selection: Binding(get: { store.target }, set: store.changeTarget)) {
                ForEach(BridgeTarget.allCases) { target in
                    Label(target.title, systemImage: target.icon).tag(target)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            if store.target == .remote {
                HStack(spacing: 8) {
                    Picker("服务器", selection: Binding(get: { store.selectedRemoteID }, set: store.selectRemoteServer)) {
                        ForEach(store.remoteServers) { server in
                            Text(server.name).tag(Optional(server.id))
                        }
                    }
                    .labelsHidden()
                    .disabled(store.remoteServers.isEmpty)
                    Button { store.showServerManager = true } label: { Image(systemName: "slider.horizontal.3") }
                        .help("管理服务器")
                }
                .padding(.horizontal)
            }

            List(selection: Binding(get: { store.sidebarSelection }, set: { store.sidebarSelection = $0 })) {
                Section("管理") {
                    Label("全局设置", systemImage: "gearshape")
                        .tag(Optional(CABStore.globalSettingsSelection))
                }
                Section("账号") {
                    ForEach(store.status.accounts) { account in
                        HStack(spacing: 9) {
                            Image(systemName: account.isLoggedIn ? "checkmark.circle.fill" : "exclamationmark.circle")
                                .foregroundStyle(account.isLoggedIn ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name)
                                HStack(spacing: 5) {
                                    if account.default { Text("默认") }
                                    if account.remote { Text("远程") }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .tag(account.name)
                    }
                }
            }
            .listStyle(.sidebar)

            HStack {
                TextField("新账号名称", text: $store.newAccountName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(store.addAccount)
                Button(action: store.addAccount) { Image(systemName: "plus") }
                    .buttonStyle(.borderedProminent)
                    .help("添加账号")
            }
            .padding()
        }
        .navigationTitle("app.name")
    }

    private var targetHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(store.targetTitle).font(.largeTitle.bold())
                if store.target == .remote {
                    Text(store.remoteHost).foregroundStyle(.secondary)
                } else {
                    Text("账号凭据保持独立，CAB 不读取令牌内容。") .foregroundStyle(.secondary)
                }
            }
            Spacer()
            statusBadge(store.status.sharedSessions ? "会话共享已开启" : "会话独立", color: store.status.sharedSessions ? .orange : .green)
        }
    }

    private var globalSettingsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            globalOverviewCard
            if store.target == .local { desktopSwitcherCard }
            sessionSharingCard
            rotationCard
        }
    }

    private var globalOverviewCard: some View {
        GroupBox {
            HStack(spacing: 28) {
                summaryValue("账号", value: "\(store.status.accounts.count)")
                summaryValue("默认 CLI", value: store.status.defaultAccount ?? "未设置")
                summaryValue("远程默认", value: store.status.remoteAccount ?? "未设置")
                summaryValue("会话", value: store.status.sharedSessions ? "共享" : "独立")
                Spacer()
            }
            .padding(8)
        } label: {
            Label("全局概览", systemImage: "square.grid.2x2")
        }
    }

    private var desktopSwitcherCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("切换 Codex 桌面端账号").font(.headline)
                    Text("“设为默认”只影响 cab run 和终端，不会切换已运行的桌面端。这里会以所选账号的 CODEX_HOME 重启官方桌面客户端。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let name = store.defaultDesktopAccount {
                    Label("系统默认 ~/.codex 当前登记为 \(name)", systemImage: "house")
                        .font(.callout)
                }
                if let name = store.lastDesktopAccount {
                    Label("CAB 上次启动：\(name)", systemImage: "clock.arrow.circlepath")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if loggedInAccounts.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("没有已登录账号").font(.headline)
                        Text("请先打开一个账号，在账号详情中完成官方登录。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    VStack(spacing: 0) {
                        ForEach(loggedInAccounts) { account in
                            HStack {
                                Image(systemName: "person.crop.circle.fill").foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name).fontWeight(.medium)
                                    Text(store.usesDefaultCodexHome(account) ? "Codex 默认目录" : "独立账号目录")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("用此账号启动") { pendingDesktopSwitch = account }
                            }
                            .padding(.vertical, 9)
                            if account.id != loggedInAccounts.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(8)
        } label: {
            Label("Codex 桌面端", systemImage: "macwindow")
        }
    }

    private var sessionSharingCard: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("跨账号会话历史").font(.headline)
                    Text(store.status.sharedSessions ? "账号共用任务历史；切换桌面账号后仍可看到共享会话。" : "每个账号保持独立任务历史；切换账号后不会继承其他账号的会话。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("这是全局隐私策略，修改前必须退出所有 Codex 进程。")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Toggle("共享", isOn: Binding(get: { store.status.sharedSessions }, set: { pendingSessionSharing = $0 }))
                    .toggleStyle(.switch)
            }
            .padding(8)
        } label: {
            Label("会话共享", systemImage: "rectangle.2.swap")
        }
    }

    private func summaryValue(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }
    }

    private var loggedInAccounts: [AccountStatus] {
        store.status.accounts.filter(\.isLoggedIn)
    }

    private func accountCard(_ account: AccountStatus) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.name).font(.title2.bold())
                        Text(account.home).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    statusBadge(account.isLoggedIn ? "已登录" : "未登录", color: account.isLoggedIn ? .green : .orange)
                }
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    if account.isLoggedIn {
                        HStack {
                            Label("账号已登录，正常切换无需重新认证", systemImage: "checkmark.shield")
                                .foregroundStyle(.secondary)
                            Spacer()
                            reauthenticationMenu(account)
                            if store.target == .local {
                                Button("切换 Codex 桌面端") { pendingDesktopSwitch = account }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        if store.usesDefaultCodexHome(account) {
                            Text("此账号直接使用 ~/.codex。完成重新登录会替换 Codex 桌面端使用的认证，请仅在确实需要更换该账号身份时操作。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        loginActions(account)
                    }
                    HStack {
                        Spacer()
                        Button("设为默认") { store.setDefault(account.name) }.disabled(account.default)
                        Button("设为远程") { store.setRemote(account.name) }.disabled(account.remote)
                        Button("移除登记", role: .destructive) { store.remove(account.name) }
                    }
                }
            }
            .padding(8)
        } label: {
            Label("账号详情", systemImage: "person.crop.circle")
        }
    }

    @ViewBuilder
    private func loginActions(_ account: AccountStatus) -> some View {
        HStack {
            Button("默认浏览器登录") { store.loginInDefaultBrowser(account.name) }
                .buttonStyle(.borderedProminent)
            Menu("指定浏览器登录") {
                ForEach(store.availableBrowsers) { browser in
                    Button(browser.title) { store.loginInBrowser(account.name, browser: browser) }
                }
            }
            .disabled(store.availableBrowsers.isEmpty)
            Menu("无痕浏览器登录") {
                ForEach(store.availablePrivateBrowsers) { browser in
                    Button(browser.title) { store.loginPrivately(account.name, browser: browser) }
                }
            }
            .disabled(store.availablePrivateBrowsers.isEmpty)
            Button("设备码登录") { store.loginWithDeviceCode(account.name) }
            Spacer()
        }
        Text("前三种方式均使用普通 ChatGPT OAuth；设备码仅用于无浏览器环境。")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func reauthenticationMenu(_ account: AccountStatus) -> some View {
        Menu("重新登录…") {
            Button("默认浏览器") {
                pendingReauthentication = ReauthenticationRequest(account: account, method: .defaultBrowser)
            }
            Section("指定浏览器") {
                ForEach(store.availableBrowsers) { browser in
                    Button(browser.title) {
                        pendingReauthentication = ReauthenticationRequest(account: account, method: .selectedBrowser(browser, privateWindow: false))
                    }
                }
            }
            Section("无痕浏览器") {
                ForEach(store.availablePrivateBrowsers) { browser in
                    Button(browser.title) {
                        pendingReauthentication = ReauthenticationRequest(account: account, method: .selectedBrowser(browser, privateWindow: true))
                    }
                }
            }
            Divider()
            Button("设备码") {
                pendingReauthentication = ReauthenticationRequest(account: account, method: .deviceCode)
            }
        }
    }

    private var reauthenticationWarning: String {
        guard let request = pendingReauthentication else { return "" }
        let desktopImpact = store.usesDefaultCodexHome(request.account)
            ? "该账号使用系统默认 ~/.codex，完成登录会替换官方 Codex 桌面端使用的认证。"
            : "完成登录会替换此独立账号目录中现有的认证。"
        return "账号 \(request.account.name) 当前已经登录，正常切换不需要重新认证。\(desktopImpact)仅在确实要更换登录身份时继续。"
    }

    private func startReauthentication(_ request: ReauthenticationRequest) {
        switch request.method {
        case .defaultBrowser:
            store.loginInDefaultBrowser(request.account.name)
        case let .selectedBrowser(browser, privateWindow):
            if privateWindow {
                store.loginPrivately(request.account.name, browser: browser)
            } else {
                store.loginInBrowser(request.account.name, browser: browser)
            }
        case .deviceCode:
            store.loginWithDeviceCode(request.account.name)
        }
    }

    private var existingLoginCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("检测到现有 Codex 登录").font(.headline)
                        Text("可以直接登记默认 ~/.codex，无需再次登录。凭据不会被读取或复制。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusBadge("已登录", color: .green)
                }
                HStack {
                    TextField("本地显示名称", text: $store.existingAccountName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit(store.importCurrentLogin)
                    Button("登记现有登录", action: store.importCurrentLogin)
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    if let home = store.status.currentLogin?.home {
                        Text(home).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
        } label: {
            Label("现有登录", systemImage: "person.crop.circle.badge.checkmark")
        }
    }

    private var emptyAccountCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("尚未配置账号").font(.title3.weight(.semibold))
            Text("在左下角输入名称添加账号，然后使用官方登录。")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private var rotationCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("新启动轮换").font(.headline)
                        Text("每次执行 cab run 前选择下一个账号；限额、认证失败和异常不会触发切换。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { store.status.rotation.enabled }, set: store.setRotationEnabled))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel("启用新启动轮换")
                }

                if store.rotationOrder.isEmpty {
                    Text("至少添加两个账号后才能启用。")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.rotationOrder.enumerated()), id: \.element) { index, name in
                            HStack {
                                Toggle(isOn: Binding(get: { store.rotationIncluded.contains(name) }, set: { store.setRotationIncluded(name, included: $0) })) {
                                    Text(name)
                                }
                                Spacer()
                                if store.status.rotation.nextAccount == name && store.status.rotation.enabled {
                                    Text("下一个").font(.caption).foregroundStyle(.blue)
                                }
                                Button { store.moveRotation(name, offset: -1) } label: { Image(systemName: "chevron.up") }
                                    .buttonStyle(.plain).disabled(index == 0).help("上移")
                                Button { store.moveRotation(name, offset: 1) } label: { Image(systemName: "chevron.down") }
                                    .buttonStyle(.plain).disabled(index == store.rotationOrder.count - 1).help("下移")
                            }
                            .padding(.vertical, 8)
                            if index < store.rotationOrder.count - 1 { Divider() }
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

                    HStack {
                        Button("保存顺序", action: store.saveRotation)
                        Button("从第一个重新开始", action: store.resetRotation)
                        Spacer()
                        Text("仅影响未指定 --account 的 cab run")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
        } label: {
            Label("自动轮换", systemImage: "arrow.triangle.2.circlepath")
        }
    }

    private var outputCard: some View {
        GroupBox("操作输出") {
            ScrollView {
                Text(store.output)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 90, maxHeight: 180)
        }
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct ReauthenticationRequest {
    let account: AccountStatus
    let method: ReauthenticationMethod
}

private enum ReauthenticationMethod {
    case defaultBrowser
    case selectedBrowser(BrowserChoice, privateWindow: Bool)
    case deviceCode
}

private struct ServerManagerView: View {
    @EnvironmentObject private var store: CABStore
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRemoval: RemoteServer?
    @State private var draftServers: [RemoteServer] = []
    @State private var importResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("远程服务器").font(.title2.bold())
                Text("连接信息只保存在这台 Mac 的 UserDefaults 中，不会写入项目或上传 Git。")
                    .foregroundStyle(.secondary)
                if let importResult {
                    Text(importResult).font(.callout).foregroundStyle(.green)
                }
            }

            if draftServers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "server.rack").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("尚未添加服务器").font(.headline)
                    Text("可以添加 SSH 配置别名、主机名、IP 或 user@host。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($draftServers) { $server in
                            HStack(spacing: 12) {
                                Image(systemName: "server.rack").foregroundStyle(.secondary)
                                TextField("显示名称", text: $server.name)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 150)
                                TextField("SSH 主机，例如 ubuntu@example.com", text: $server.host)
                                    .textFieldStyle(.roundedBorder)
                                Button(role: .destructive) { pendingRemoval = server } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("移除服务器")
                            }
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: 360)
            }

            HStack {
                Button {
                    draftServers.append(RemoteServer(name: "新服务器", host: ""))
                } label: { Label("添加服务器", systemImage: "plus") }
                Button {
                    do {
                        let aliases = try store.discoverSSHHosts()
                        let existing = Set(draftServers.map(\.host))
                        let additions = aliases.filter { !existing.contains($0) }
                        draftServers.append(contentsOf: additions.map { RemoteServer(name: $0, host: $0) })
                        importResult = additions.isEmpty ? "没有发现新的具体 Host 别名。" : "已从 ~/.ssh/config 导入 \(additions.count) 个 Host 别名。"
                    } catch {
                        store.errorMessage = error.localizedDescription
                    }
                } label: { Label("从 SSH 配置导入", systemImage: "square.and.arrow.down") }
                .help("只导入具体 Host 别名，不打开 IdentityFile 指向的私钥")
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("保存") {
                    if store.saveRemoteServers(draftServers) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 340)
        .onAppear { draftServers = store.remoteServers }
        .confirmationDialog("移除这台服务器？", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button("移除本地连接信息", role: .destructive) {
                if let id = pendingRemoval?.id { draftServers.removeAll { $0.id == id } }
                pendingRemoval = nil
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("只会删除 CAB Desktop 保存的名称和 SSH 主机，不会删除服务器上的账号或文件。")
        }
    }
}
