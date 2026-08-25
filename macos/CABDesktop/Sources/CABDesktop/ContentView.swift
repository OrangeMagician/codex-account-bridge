import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: CABStore

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    targetHeader
                    if store.canImportCurrentLogin { existingLoginCard }
                    if let account = store.selectedAccountStatus {
                        accountCard(account)
                    } else {
                        emptyAccountCard
                    }
                    rotationCard
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
                Button(action: store.launchCodex) { Label("启动 Codex", systemImage: "terminal") }
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

            List(selection: $store.selectedAccount) {
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
                    HStack {
                        Button("默认浏览器登录") { store.loginInDefaultBrowser(account.name) }
                            .buttonStyle(.borderedProminent)
                        Menu {
                            ForEach(store.availableBrowsers) { browser in
                                Button(browser.title) { store.loginInBrowser(account.name, browser: browser) }
                            }
                        } label: {
                            Label("指定浏览器登录", systemImage: "globe")
                        }
                        .disabled(store.availableBrowsers.isEmpty)
                        .help("使用普通 ChatGPT OAuth，在所选浏览器的普通窗口登录")
                        Menu {
                            if store.availablePrivateBrowsers.isEmpty {
                                Text("未检测到 Chrome、Edge、Brave 或 Firefox")
                            } else {
                                ForEach(store.availablePrivateBrowsers) { browser in
                                    Button(browser.title) { store.loginPrivately(account.name, browser: browser) }
                                }
                            }
                        } label: {
                            Label("无痕浏览器登录", systemImage: "eye.slash")
                        }
                        .disabled(store.availablePrivateBrowsers.isEmpty)
                        .help("使用普通 ChatGPT OAuth，在所选浏览器的无痕窗口登录，不需要设备码授权")
                        Button("设备码登录") { store.loginWithDeviceCode(account.name) }
                            .help("仅用于远程或无浏览器环境，需要在 ChatGPT 安全设置中启用设备代码授权")
                        Spacer()
                    }
                    HStack {
                        Spacer()
                        Button("设为默认") { store.setDefault(account.name) }.disabled(account.default)
                        Button("设为远程") { store.setRemote(account.name) }.disabled(account.remote)
                        Button("移除登记", role: .destructive) { store.remove(account.name) }
                    }
                    Text("指定浏览器和无痕浏览器登录都使用普通 ChatGPT OAuth；设备码仅作为无浏览器环境的备用方式。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        } label: {
            Label("账号详情", systemImage: "person.crop.circle")
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
