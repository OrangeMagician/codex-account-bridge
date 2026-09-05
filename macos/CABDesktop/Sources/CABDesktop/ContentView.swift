import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: CABStore
    @State private var pendingDesktopSwitchConfirmation: AccountStatus?
    @State private var pendingSessionSharing: Bool?
    @State private var pendingReauthentication: ReauthenticationRequest?
    @State private var pendingAgentBinding: AgentBindingRequest?
    @State private var pendingBulkAgentBinding: AgentBulkBindingRequest?
    @State private var pendingLegacyImport = false
    @State private var pendingUsageReset: UsageResetConfirmation?

    var body: some View {
        withDialogs(baseView)
    }

    private var baseView: some View {
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
                            accountUsageCard(account)
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
        .environment(\.locale, Locale(identifier: store.interfaceLanguage.localeIdentifier))
        .toolbar {
            ToolbarItemGroup {
                Button(action: store.refresh) { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(store.isBusy)
                    .help("刷新当前目标的状态、账号和额度")
                Button(action: store.launchCodex) { Label("在终端启动", systemImage: "terminal") }
                    .help("在终端启动当前目标的 Codex")
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
        .alert(usageResetResultTitle, isPresented: Binding(get: { store.usageResetResult != nil }, set: { if !$0 { store.usageResetResult = nil } })) {
            Button("知道了", role: .cancel) { store.usageResetResult = nil }
        } message: {
            Text(usageResetResultMessage)
        }
        .sheet(isPresented: $store.showServerManager) {
            ServerManagerView()
                .environmentObject(store)
        }
        .task {
            store.startUsageRefreshScheduler()
            store.refresh()
        }
    }

    private func withDialogs<Content: View>(_ content: Content) -> some View {
        content
        .confirmationDialog("切换 Codex 桌面账号？", isPresented: Binding(get: { pendingDesktopSwitchConfirmation != nil }, set: { if !$0 { pendingDesktopSwitchConfirmation = nil } }), titleVisibility: .visible) {
            Button(store.preserveSessionsOnDesktopSwitch ? "保留项目与会话并切换" : "使用独立项目与会话并切换", role: .destructive) {
                if let account = pendingDesktopSwitchConfirmation { store.switchCodexDesktop(to: account) }
                pendingDesktopSwitchConfirmation = nil
            }
            Button("取消", role: .cancel) { pendingDesktopSwitchConfirmation = nil }
        } message: {
            Text(desktopSwitchWarning)
        }
        .sheet(item: $store.pendingDesktopSwitch) { request in
            DesktopSwitchProcessSheet(
                request: request,
                isBusy: store.isBusy,
                errorMessage: store.pendingDesktopSwitchError,
                onCancel: {
                    store.pendingDesktopSwitch = nil
                    store.pendingDesktopSwitchError = nil
                },
                onContinue: { store.closeProcessesAndContinueDesktopSwitch(request) }
            )
        }
        .confirmationDialog("检测到正在运行的远程 Codex", isPresented: Binding(get: { store.pendingRemoteCodexSwitch != nil }, set: { if !$0 { store.pendingRemoteCodexSwitch = nil } }), titleVisibility: .visible) {
            if let request = store.pendingRemoteCodexSwitch {
                Button("关闭这些进程并切换到 \(request.accountName)", role: .destructive) {
                    store.stopProcessesAndSwitchRemoteCodex(request)
                }
            }
            Button("取消", role: .cancel) { store.pendingRemoteCodexSwitch = nil }
        } message: {
            if let request = store.pendingRemoteCodexSwitch {
                Text(remoteCodexSwitchProcessMessage(request))
            }
        }
        .confirmationDialog(store.target == .local ? "更改项目与会话保留？" : "更改会话共享？", isPresented: Binding(get: { pendingSessionSharing != nil }, set: { if !$0 { pendingSessionSharing = nil } }), titleVisibility: .visible) {
            Button(store.target == .local ? (pendingSessionSharing == true ? "确认切换时保留" : "确认保持独立") : (pendingSessionSharing == true ? "确认共享会话" : "确认恢复独立")) {
                if let enabled = pendingSessionSharing {
                    if store.target == .local {
                        store.setPreserveSessionsOnDesktopSwitch(enabled)
                    } else {
                        store.prepareSessionSharingChange(enabled)
                    }
                }
                pendingSessionSharing = nil
            }
            Button("取消", role: .cancel) { pendingSessionSharing = nil }
        } message: {
            Text(sessionSharingWarning)
        }
        .confirmationDialog("检测到未关闭的 Codex", isPresented: Binding(get: { store.pendingRemoteSessionChange != nil }, set: { if !$0 { store.pendingRemoteSessionChange = nil } }), titleVisibility: .visible) {
            Button("关闭这些进程并继续", role: .destructive) {
                if let request = store.pendingRemoteSessionChange { store.stopProcessesAndApplySessionChange(request) }
                store.pendingRemoteSessionChange = nil
            }
            Button("取消", role: .cancel) { store.pendingRemoteSessionChange = nil }
        } message: {
            if let request = store.pendingRemoteSessionChange {
                Text(processResolutionMessage(request))
            }
        }
        .confirmationDialog("导入旧默认历史？", isPresented: $pendingLegacyImport, titleVisibility: .visible) {
            Button("导入并共享", role: .destructive) { store.prepareLegacyImport() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("旧 ~/.codex 中的会话会复制到共享库，所有已登记账号都能看到其中的上下文。源文件不会删除。")
        }
        .confirmationDialog("导入前需要关闭 Codex", isPresented: Binding(get: { store.pendingLegacyProcesses != nil }, set: { if !$0 { store.pendingLegacyProcesses = nil } }), titleVisibility: .visible) {
            Button("关闭并导入", role: .destructive) {
                if let processes = store.pendingLegacyProcesses { store.stopProcessesAndImportLegacy(processes) }
                store.pendingLegacyProcesses = nil
            }
            Button("取消", role: .cancel) { store.pendingLegacyProcesses = nil }
        } message: {
            if let processes = store.pendingLegacyProcesses {
                Text(legacyImportProcessMessage(processes))
            }
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
        .confirmationDialog("应用智能体账号绑定？", isPresented: Binding(get: { pendingAgentBinding != nil }, set: { if !$0 { pendingAgentBinding = nil } }), titleVisibility: .visible) {
            Button(pendingAgentBinding?.account == nil ? "解除绑定" : "应用绑定", role: .destructive) {
                if let request = pendingAgentBinding { store.applyAgentBinding(request) }
                pendingAgentBinding = nil
            }
            Button("取消", role: .cancel) { pendingAgentBinding = nil }
        } message: {
            if let request = pendingAgentBinding {
                Text(request.active ? "这会重启 \(request.service)，正在运行的智能体任务可能中断。CAB 只设置 CODEX_HOME，不会读取或复制令牌。" : "服务当前未运行；CAB 只设置 CODEX_HOME，不会启动服务或读取令牌。")
            }
        }
        .confirmationDialog("将全部智能体绑定到同一账号？", isPresented: Binding(get: { pendingBulkAgentBinding != nil }, set: { if !$0 { pendingBulkAgentBinding = nil } }), titleVisibility: .visible) {
            Button("绑定全部智能体", role: .destructive) {
                if let request = pendingBulkAgentBinding { store.applyAllAgentBindings(account: request.account) }
                pendingBulkAgentBinding = nil
            }
            Button("取消", role: .cancel) { pendingBulkAgentBinding = nil }
        } message: {
            if let request = pendingBulkAgentBinding {
                Text("将 \(request.serviceCount) 个智能体服务统一绑定到 \(request.account)。其中 \(request.activeServiceCount) 个正在运行的服务需要重启，当前任务可能中断。CAB 不会读取或复制令牌。")
            }
        }
        .sheet(item: $pendingUsageReset) { confirmation in
            UsageResetConfirmationSheet(
                confirmation: confirmation,
                onCancel: { pendingUsageReset = nil },
                onConfirm: {
                    pendingUsageReset = nil
                    store.consumeUsageReset(for: confirmation)
                }
            )
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("管理位置", selection: Binding(get: { store.target }, set: store.changeTarget)) {
                ForEach(BridgeTarget.allCases) { target in
                    Label(target.title, systemImage: target.icon).tag(target)
                }
            }
            .pickerStyle(.segmented)
            .disabled(store.isBusy)
            .padding()

            if store.target == .remote {
                HStack(spacing: 8) {
                    Picker("服务器", selection: Binding(get: { store.selectedRemoteID }, set: store.selectRemoteServer)) {
                        ForEach(store.remoteServers) { server in
                            Text(server.name).tag(Optional(server.id))
                        }
                    }
                    .labelsHidden()
                    .disabled(store.remoteServers.isEmpty || store.isBusy)
                    Button { store.showServerManager = true } label: { Image(systemName: "slider.horizontal.3") }
                        .help("管理服务器")
                }
                .padding(.horizontal)
            }

            List(selection: $store.sidebarSelection) {
                Section("管理") {
                    Label("管理概览", systemImage: "square.grid.2x2")
                        .tag(CABStore.globalSettingsSelection)
                }
                Section("账号") {
                    ForEach(store.status.accounts) { account in
                        HStack(spacing: 9) {
                            Group {
                                if store.isLoginInProgress(account.name) {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: account.isLoggedIn ? "checkmark.circle.fill" : (account.isLoginUnknown ? "questionmark.circle" : "exclamationmark.circle"))
                                        .foregroundStyle(account.isLoggedIn ? .green : (account.isLoginUnknown ? .secondary : .orange))
                                }
                            }
                            .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(account.name)
                                    if account.default {
                                        Image(systemName: "star.fill")
                                            .foregroundStyle(.orange)
                                            .help("默认 CLI 账号")
                                            .accessibilityLabel("默认 CLI 账号")
                                    }
                                    if store.target == .remote && account.remote {
                                        Image(systemName: "server.rack")
                                            .foregroundStyle(.secondary)
                                            .help("当前远程 Codex 账号")
                                            .accessibilityLabel("当前远程 Codex 账号")
                                    }
                                }
                                sidebarUsage(account)
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
                }
            }
            Spacer()
            statusBadge(cabLocalized(store.status.sharedSessions ? "会话共享已开启" : "会话独立"), color: store.status.sharedSessions ? .orange : .green)
        }
    }

    private var globalSettingsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            globalOverviewCard
            usageOverviewCard
            if store.target == .local { desktopSwitcherCard }
            sessionSharingCard
            if store.target == .remote { agentBindingsCard }
            rotationCard
        }
    }

    private var agentBindingsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let error = store.agentBindingError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                } else if store.agentBindings.isEmpty {
                    Label("未发现支持的 Hermes 或 OpenClaw 用户服务。", systemImage: "tray")
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 10) {
                        Label("全部使用", systemImage: "person.2.fill")
                            .fontWeight(.medium)
                        Spacer()
                        Picker("全部智能体账号", selection: $store.bulkAgentAccount) {
                            Text("选择账号").tag("")
                            ForEach(loggedInAccounts) { account in Text(account.name).tag(account.name) }
                        }
                        .labelsHidden().frame(width: 150)
                        Button("一键绑定全部") {
                            let changed = store.agentBindings.filter { $0.account != store.bulkAgentAccount }
                            pendingBulkAgentBinding = AgentBulkBindingRequest(
                                account: store.bulkAgentAccount,
                                serviceCount: changed.count,
                                activeServiceCount: changed.filter(\.active).count
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isBusy || store.bulkAgentAccount.isEmpty || store.agentBindings.allSatisfy { $0.account == store.bulkAgentAccount })
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    Divider()
                    ForEach(store.agentBindings) { agent in
                        HStack(spacing: 12) {
                            Image(systemName: agent.kind == "OpenClaw" ? "shippingbox" : "sparkles")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.kind).fontWeight(.medium)
                                Text(agent.service).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            statusBadge(cabLocalized(agent.active ? "运行中" : "未运行"), color: agent.active ? .green : .gray)
                            Picker("账号", selection: Binding(
                                get: { store.agentSelections[agent.service] ?? "" },
                                set: { store.setAgentSelection(service: agent.service, account: $0) }
                            )) {
                                Text("不绑定").tag("")
                                ForEach(loggedInAccounts) { account in Text(account.name).tag(account.name) }
                            }
                            .labelsHidden().frame(width: 150)
                            Button("应用") {
                                let selected = store.agentSelections[agent.service] ?? ""
                                pendingAgentBinding = AgentBindingRequest(service: agent.service, account: selected.isEmpty ? nil : selected, active: agent.active)
                            }
                            .disabled(store.isBusy || (store.agentSelections[agent.service] ?? "") == (agent.account ?? ""))
                        }
                        if agent.id != store.agentBindings.last?.id { Divider() }
                    }
                }
            }.padding(8)
        } label: {
            Label("智能体账号绑定", systemImage: "person.2.badge.gearshape")
                .help("为 Hermes 或 OpenClaw 服务选择明确的 Codex 账号。CAB 只设置 CODEX_HOME，不复制授权文件。")
        }
    }

    private var globalOverviewCard: some View {
        GroupBox {
            HStack(spacing: 28) {
                summaryValue("账号", value: "\(store.status.accounts.count)")
                summaryValue("CLI 默认", value: store.status.defaultAccount ?? "未设置")
                if store.target == .remote {
                    summaryValue("远程 Codex", value: store.status.remoteAccount ?? "未设置")
                }
                summaryValue("会话", value: cabLocalized(store.status.sharedSessions ? "共享" : "独立"))
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
                Text("切换 Codex 桌面端账号").font(.headline)
                if let name = store.defaultDesktopAccount {
                    Label("系统默认 ~/.codex 当前登记为 \(name)", systemImage: "house")
                        .font(.callout)
                }
                if let name = store.lastDesktopAccount {
                    Label("CAB 上次启动：\(name)", systemImage: "clock.arrow.circlepath")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Label("切换策略", systemImage: "rectangle.2.swap")
                    Spacer()
                    statusBadge(cabLocalized(store.preserveSessionsOnDesktopSwitch ? "保留项目与会话" : "项目与会话独立"), color: store.preserveSessionsOnDesktopSwitch ? .orange : .green)
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
                                Button("用此账号启动") { pendingDesktopSwitchConfirmation = account }
                                    .disabled(store.isUsageRefreshing || store.isBusy)
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
                .help("“设为默认”只影响 cab run 和终端；这里会用所选账号的 CODEX_HOME 重启官方桌面客户端。")
        }
    }

    private var usageOverviewCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let accountName = store.loginAccountName {
                    Label(
                        store.loginStatusConfirmed
                            ? "已检测到 \(accountName) 登录成功，正在更新账号状态与额度…"
                            : "正在等待 \(accountName) 完成官方登录，登录成功后将自动读取额度。",
                        systemImage: store.loginStatusConfirmed ? "checkmark.circle" : "person.badge.clock"
                    )
                    .font(.callout)
                    .foregroundStyle(store.loginStatusConfirmed ? .green : .secondary)
                } else if store.status.accounts.isEmpty {
                    Text("添加并登录账号后，这里会显示官方 Codex 额度。")
                        .font(.callout).foregroundStyle(.secondary)
                } else if store.usageByAccount.isEmpty && store.isUsageRefreshing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在通过官方 Codex 查询各账号额度…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 70)
                } else if store.usageByAccount.isEmpty {
                    if let error = store.usageLoadError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    } else {
                        HStack {
                            Label(store.usageRefreshInterval == .manual ? "尚未获取额度；当前设置为仅手动刷新。" : "尚无额度缓存。", systemImage: "gauge.with.dots.needle.0percent")
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button("立即获取", action: store.refreshUsage)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.status.accounts) { account in
                            usageOverviewRow(account)
                                .padding(.vertical, 9)
                            if account.id != store.status.accounts.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    if let error = store.usageLoadError {
                        Label("刷新失败，正在显示上次成功获取的额度。", systemImage: "clock.arrow.circlepath")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .help(error)
                    }
                }
                HStack {
                    if let fetchedAt = store.usageFetchedAt {
                        Text("更新于 \(fetchedAt, style: .relative)")
                            .font(.caption).foregroundStyle(.secondary)
                            .help(fetchedAt.formatted(date: .abbreviated, time: .standard))
                    }
                    Spacer()
                    Button(action: store.refreshUsage) {
                        if store.isUsageRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("刷新额度", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(store.isUsageRefreshing)
                }
            }
            .padding(8)
        } label: {
            Label("额度概览", systemImage: "gauge.with.dots.needle.50percent")
                .help("额度来自官方 Codex app-server；重置时间不是 ChatGPT 订阅续费或会员到期日。")
        }
    }

    @ViewBuilder
    private func usageOverviewRow(_ account: AccountStatus) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).fontWeight(.medium)
                if let plan = store.usage(for: account.name)?.usage?.planType {
                    Text(plan.uppercased()).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 110, alignment: .leading)

            if store.isLoginInProgress(account.name) {
                Label(
                    store.loginStatusConfirmed ? "登录成功，正在更新" : "等待官方登录",
                    systemImage: store.loginStatusConfirmed ? "checkmark.circle" : "person.badge.clock"
                )
                .font(.callout)
                .foregroundStyle(store.loginStatusConfirmed ? .green : .secondary)
            } else if let report = store.usage(for: account.name), let usage = report.usage {
                let periods = usagePeriodDisplays(for: usage)
                HStack(spacing: 12) {
                    usageOverviewPeriod("5 小时", value: periods.fiveHour)
                    usageOverviewPeriod("周", value: periods.weekly)
                }
            } else if let message = store.usage(for: account.name)?.error {
                Label(shortUsageError(message), systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange)
            } else if account.isLoginUnknown {
                Text("状态未知").font(.callout).foregroundStyle(.secondary)
            } else if !account.isLoggedIn {
                Text("未登录").font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
    }

    private var sessionSharingCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 16) {
                    Text(store.target == .local ? "跨账号项目与会话" : "跨账号会话历史").font(.headline)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        if store.target == .local && store.preserveSessionsOnDesktopSwitch != store.status.sharedSessions {
                            statusBadge(cabLocalized(store.preserveSessionsOnDesktopSwitch ? "下次切换时开启" : "下次切换时关闭"), color: .blue)
                        } else {
                            statusBadge(cabLocalized(store.status.sharedSessions ? "当前已共享" : "当前独立"), color: store.status.sharedSessions ? .orange : .green)
                        }
                        Toggle(store.target == .local ? "切换时保留" : "共享", isOn: Binding(
                            get: { store.target == .local ? store.preserveSessionsOnDesktopSwitch : store.status.sharedSessions },
                            set: { pendingSessionSharing = $0 }
                        ))
                        .toggleStyle(.switch)
                    }
                }
                if store.target == .remote, store.status.sharedSessions, let legacy = store.legacySessions, legacy.total > 0 {
                    Divider()
                    HStack {
                        Label("旧 ~/.codex 中发现 \(legacy.total) 个未导入会话", systemImage: "clock.arrow.circlepath")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("导入旧历史") { pendingLegacyImport = true }
                    }
                }
            }
            .padding(8)
        } label: {
            Label(store.target == .local ? "项目与会话" : "会话共享", systemImage: "rectangle.2.swap")
                .help(sessionSharingDescription)
        }
    }

    private var sessionSharingDescription: String {
        if store.target == .local {
            return store.preserveSessionsOnDesktopSwitch
                ? cabLocalized("切换桌面账号时同步项目、完整消息、记忆、目标、技能、附件、侧栏状态和未发送草稿。")
                : cabLocalized("切换桌面账号时保持各账号自己的项目列表和任务历史。")
        }
        return store.status.sharedSessions
            ? cabLocalized("服务器上的账号共用任务历史，其中可能包含其他账号的上下文。")
            : cabLocalized("服务器上的每个账号保持独立任务历史。")
    }

    private var sessionSharingWarning: String {
        if store.target == .local {
            return pendingSessionSharing == true
                ? cabLocalized("开启后，下次切换桌面账号前 CAB 会先检查 CLI 和编辑器扩展；确认没有任务写入后才关闭桌面端，再同步项目、完整消息、目标、记忆、个人技能、规则、附件、侧栏状态、提示历史和未发送草稿。其他账号可能看到这些内容，但登录凭据、插件授权、设备连接和安全权限始终独立。")
                : cabLocalized("关闭后，下次切换桌面账号时 CAB 会保持每个账号自己的项目列表，并恢复独立的任务历史副本。登录凭据不会改变。")
        }
        return cabLocalized("操作前必须退出服务器上的所有 Codex 进程。共享后不同账号可以看到同一份任务历史，其中可能包含另一个账号的上下文。")
    }

    private func processResolutionMessage(_ request: RemoteSessionProcessRequest) -> String {
        let details = request.processes.map { process in
            "PID \(process.pid)，运行 \(process.elapsed)，终端 \(process.tty)，\(process.executable)"
        }.joined(separator: "\n")
        return "以下 Codex 仍在运行：\n\(details)\n\n确认后只会请求这些进程正常退出；全部退出后才会\(request.enabled ? "开启" : "关闭")会话共享。未保存的任务可能中断。"
    }

    private func remoteCodexSwitchProcessMessage(_ request: RemoteCodexSwitchRequest) -> String {
        let details = request.processes.map { process in
            "PID \(process.pid)，运行 \(process.elapsed)，终端 \(process.tty)，\(process.executable)"
        }.joined(separator: "\n")
        return "以下远程 Codex CLI、SSH 远程项目或 app-server 仍在运行：\n\(details)\n\nHermes、OpenClaw 等智能体进程已排除。确认后会关闭以上进程、切换到 \(request.accountName)，并自动处理远程项目的即时重连；切换完成后的新连接不会被反复关闭。未保存的任务可能中断。"
    }

    private func legacyImportProcessMessage(_ processes: [CodexProcessStatus]) -> String {
        let details = processes.map { process in
            "PID \(process.pid)，运行 \(process.elapsed)，终端 \(process.tty)，\(process.executable)"
        }.joined(separator: "\n")
        return "以下 Codex 仍在运行：\n\(details)\n\n确认后只会请求这些进程正常退出；全部退出后才会导入旧历史。未保存的任务可能中断。"
    }

    private var desktopSwitchWarning: String {
        let sessionEffect = store.preserveSessionsOnDesktopSwitch
            ? cabLocalized("会先检查 CLI 和编辑器扩展，再安全同步项目、完整消息与目录、记忆、目标、个人技能、附件、侧栏状态和未发送草稿；预检不通过时不会关闭桌面端。")
            : cabLocalized("如果当前正在共享，会先恢复各账号独立的会话副本；项目列表也保持账号独立。")
        return String(
            format: cabLocalized("这会关闭正在运行的 Codex 桌面客户端和其中的活动任务，再以所选账号的独立 CODEX_HOME 重新启动。%@请先保存正在进行的工作。"),
            sessionEffect
        )
    }

    private func summaryValue(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(cabLocalized(title)).font(.caption).foregroundStyle(.secondary)
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
                    if store.isLoginInProgress(account.name) {
                        statusBadge(cabLocalized(store.loginStatusConfirmed ? "登录成功" : "登录中"), color: store.loginStatusConfirmed ? .green : .blue)
                    } else {
                        statusBadge(cabLocalized(account.isLoggedIn ? "已登录" : (account.isLoginUnknown ? "状态未知" : "未登录")), color: account.isLoggedIn ? .green : (account.isLoginUnknown ? .gray : .orange))
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    if store.isLoginInProgress(account.name) {
                        HStack(spacing: 10) {
                            if store.loginStatusConfirmed {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text("已检测到官方 Codex 登录成功，正在完成状态与额度更新。")
                            } else {
                                ProgressView().controlSize(.small)
                                Text("正在等待浏览器完成官方授权，成功后会自动更新。")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.canManuallyCheckLogin {
                                Button("立即检查状态", action: store.checkPendingLoginStatus)
                            }
                        }
                    } else if account.isLoggedIn {
                        HStack {
                            Spacer()
                            reauthenticationMenu(account)
                            if store.target == .local {
                                Button("切换 Codex 桌面端") { pendingDesktopSwitchConfirmation = account }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(store.isUsageRefreshing || store.isBusy)
                            } else if account.remote {
                                Label("当前远程 Codex 账号", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Button("切换远程 Codex") { store.switchRemoteCodex(to: account.name) }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(store.isUsageRefreshing || store.isBusy)
                                    .help("之后通过 SSH 或远程项目启动的 Codex 使用此账号；智能体账号仍独立管理。")
                            }
                        }
                    } else if account.isLoginUnknown {
                        HStack {
                            Label("暂时无法通过官方 Codex 确认登录状态，请刷新后再操作。", systemImage: "questionmark.circle")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("刷新状态", action: store.refresh)
                        }
                    } else {
                        loginActions(account)
                    }
                    HStack {
                        Spacer()
                        Button("设为 CLI 默认") { store.setDefault(account.name) }.disabled(account.default)
                        Button("移除登记", role: .destructive) { store.remove(account.name) }
                    }
                }
            }
            .padding(8)
        } label: {
            Label("账号详情", systemImage: "person.crop.circle")
        }
    }

    private func accountUsageCard(_ account: AccountStatus) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                if store.isLoginInProgress(account.name) {
                    HStack(spacing: 10) {
                        if store.loginStatusConfirmed {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("登录成功，正在读取官方 Codex 额度…")
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                            Text("完成官方登录后，这里会自动显示额度。")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                } else if let report = store.usage(for: account.name), let usage = report.usage {
                    if let error = store.usageLoadError {
                        Label("刷新失败，正在显示上次成功获取的额度。", systemImage: "clock.arrow.circlepath")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .help(error)
                    }
                    let limits = usageCodexRateLimits(for: usage)
                    let periods = usagePeriodDisplays(for: usage)
                    if let plan = usage.planType ?? limits.planType {
                        HStack {
                            Spacer()
                            statusBadge(plan.uppercased(), color: .blue)
                        }
                    }
                    usagePeriodRow("5 小时额度", value: periods.fiveHour)
                    usagePeriodRow("周额度", value: periods.weekly)
                    if let credits = limits.credits, credits.unlimited || credits.hasCredits {
                        Divider()
                        HStack {
                            Label("额外 Credits", systemImage: "creditcard")
                            Spacer()
                            Text(credits.unlimited ? "不限" : (credits.balance ?? "可用"))
                                .fontWeight(.medium)
                        }
                    }
                    if let individual = limits.individualLimit {
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("个人消费上限").fontWeight(.medium)
                                Text("\(cabLocalized("已用")) \(individual.used) / \(individual.limit)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(cabLocalized("剩余")) \(percentText(individual.remainingPercent))")
                                .foregroundStyle(usageColor(individual.remainingPercent))
                            resetDateLabel(individual.resetDate)
                        }
                    }
                    if let resetConfirmation = usageResetConfirmation(accountName: account.name, usage: usage),
                       let resetCredits = usage.resetCredits {
                        Divider()
                        HStack {
                            Label("可用额度重置次数", systemImage: "arrow.counterclockwise.circle")
                            Spacer()
                            Text("\(resetCredits.availableCount)").fontWeight(.semibold)
                            if let expiry = resetCredits.credits?.compactMap(\.expiresAt).min() {
                                Text(cabLocalized("最早到期"))
                                    .font(.caption).foregroundStyle(.secondary)
                                resetDateLabel(Date(timeIntervalSince1970: TimeInterval(expiry)))
                            }
                            Button {
                                pendingUsageReset = resetConfirmation
                            } label: {
                                if store.usageResettingAccount == account.name {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("重置额度", systemImage: "arrow.counterclockwise")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .disabled(store.usageResettingAccount != nil || store.isUsageRefreshing)
                        }
                    }
                    Divider()
                    HStack {
                        Spacer()
                        if let fetchedAt = store.usageFetchedAt {
                            Text(fetchedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("刷新额度", action: store.refreshUsage)
                            .disabled(store.isUsageRefreshing)
                    }
                } else if let message = store.usage(for: account.name)?.error {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("无法读取此账号额度", systemImage: "exclamationmark.triangle")
                            .font(.headline).foregroundStyle(.orange)
                        Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("重新读取", action: store.refreshUsage)
                            .disabled(store.isUsageRefreshing)
                    }
                } else if let message = store.usageLoadError {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("额度服务暂不可用", systemImage: "exclamationmark.triangle")
                            .font(.headline).foregroundStyle(.orange)
                        Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("重新读取", action: store.refreshUsage)
                            .disabled(store.isUsageRefreshing)
                    }
                } else if account.isLoginUnknown {
                    Label("登录状态暂时无法确认，请刷新状态。", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                } else if !account.isLoggedIn {
                    Label("账号登录后才能读取官方 Codex 额度。", systemImage: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                } else if store.isUsageRefreshing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取官方 Codex 额度…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 70)
                } else {
                    HStack {
                        Text("当前没有额度缓存。")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("立即获取", action: store.refreshUsage)
                    }
                }
            }
            .padding(8)
        } label: {
            Label("额度与周期", systemImage: "chart.bar.xaxis")
                .help("官方账号额度，与 API 的 RPM/TPM 限额不同。CAB 只读查询，不直接读取 auth.json、钥匙串令牌或浏览器 Cookie。")
        }
    }

    private func usageWindowRow(_ title: String, window: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cabLocalized(title)).fontWeight(.medium)
                    if let duration = window.windowDurationMins {
                        Text("\(durationText(duration)) \(cabLocalized("周期"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("\(cabLocalized("已用")) \(percentText(window.usedPercent))")
                    .font(.callout).foregroundStyle(.secondary)
                Text("\(cabLocalized("剩余")) \(percentText(window.remainingPercent))")
                    .font(.headline).foregroundStyle(usageColor(window.remainingPercent))
            }
            ProgressView(value: window.remainingPercent, total: 100)
                .tint(usageColor(window.remainingPercent))
            HStack {
                Spacer()
                resetSummary(window)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func usagePeriodRow(_ title: String, value: UsagePeriodDisplayValue) -> some View {
        switch value {
        case let .measured(window):
            usageWindowRow(title, window: window)
        case .unlimited:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cabLocalized(title)).fontWeight(.medium)
                        Text("没有5小时额度限制")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(cabLocalized("已用")) 0%")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("\(cabLocalized("剩余")) 100%")
                        .font(.headline)
                        .foregroundStyle(.green)
                }
                ProgressView(value: 100, total: 100)
                    .tint(.green)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        case .unavailable:
            HStack {
                Text(cabLocalized(title)).fontWeight(.medium)
                Spacer()
                Text("官方接口暂未返回")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func usageOverviewPeriod(_ title: String, value: UsagePeriodDisplayValue) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(cabLocalized(title))
                    .font(.caption.weight(.medium))
                Spacer()
                if let remaining = value.remainingPercent {
                    Text(percentText(remaining))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(usageColor(remaining))
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            ProgressView(value: value.remainingPercent ?? 0, total: 100)
                .tint(value.remainingPercent.map(usageColor) ?? .gray)
            switch value {
            case let .measured(window):
                resetSummary(window)
            case .unlimited:
                Text("无限制").font(.caption).foregroundStyle(.secondary)
            case .unavailable:
                Text("暂未返回").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func sidebarUsage(_ account: AccountStatus) -> some View {
        if let report = store.usage(for: account.name), let usage = report.usage {
            let periods = usagePeriodDisplays(for: usage)
            VStack(alignment: .leading, spacing: 3) {
                sidebarUsagePeriod("5h", value: periods.fiveHour)
                sidebarUsagePeriod("周", value: periods.weekly)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else if store.usage(for: account.name)?.error != nil {
            Text("额度不可用").font(.caption2).foregroundStyle(.orange)
        }
    }

    private func sidebarUsagePeriod(_ title: String, value: UsagePeriodDisplayValue) -> some View {
        HStack(spacing: 4) {
            Text(cabLocalized(title))
                .fontWeight(.medium)
                .frame(width: 20, alignment: .leading)
            ProgressView(value: value.remainingPercent ?? 0, total: 100)
                .tint(value.remainingPercent.map(usageColor) ?? .gray)
                .frame(width: 64)
            Text(value.remainingPercent.map(percentText) ?? "—")
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
    }

    private func resetSummary(_ window: UsageWindow) -> some View {
        Group {
            if let date = window.resetDate {
                HStack(spacing: 4) {
                    Text(cabLocalized("重置"))
                    Text(date, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(date.formatted(date: .complete, time: .standard))
            } else {
                Text(cabLocalized("重置时间未知")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func resetDateLabel(_ date: Date) -> some View {
        Text(date, style: .relative)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(date.formatted(date: .complete, time: .standard))
    }

    private func percentText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }

    private func durationText(_ minutes: Int64) -> String {
        if minutes % 10_080 == 0 { return "\(minutes / 10_080) \(cabLocalized("周"))" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440) \(cabLocalized("天"))" }
        if minutes % 60 == 0 { return "\(minutes / 60) \(cabLocalized("小时"))" }
        return "\(minutes) \(cabLocalized("分钟"))"
    }

    private func usageColor(_ remaining: Double) -> Color {
        if remaining <= 10 { return .red }
        if remaining <= 25 { return .orange }
        return .green
    }

    private func shortUsageError(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("not logged in") { return "未登录" }
        if message.localizedCaseInsensitiveContains("unsupported") || message.localizedCaseInsensitiveContains("unknown command") { return "需要更新 cab" }
        return "读取失败"
    }

    private var usageResetResultTitle: String {
        switch store.usageResetResult?.outcome {
        case .reset, .alreadyRedeemed: return cabLocalized("额度已重置")
        case .nothingToReset: return cabLocalized("当前无需重置")
        case .noCredit: return cabLocalized("没有可用重置次数")
        case nil: return cabLocalized("额度重置结果")
        }
    }

    private var usageResetResultMessage: String {
        switch store.usageResetResult?.outcome {
        case .reset:
            return cabLocalized("5 小时额度和周额度已同步刷新；周额度将从现在起重新计算 7 天。")
        case .alreadyRedeemed:
            return cabLocalized("这次请求此前已经成功完成，没有重复消耗重置次数。最新额度已刷新。")
        case .nothingToReset:
            return cabLocalized("当前没有符合条件的额度周期，本次没有消耗重置次数。")
        case .noCredit:
            return cabLocalized("此账号目前没有可用的额度重置次数，额度信息已重新读取。")
        case nil:
            return ""
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
                .help("用于无浏览器环境")
            Spacer()
        }
    }

    private func reauthenticationMenu(_ account: AccountStatus) -> some View {
        Menu {
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
        } label: {
            Label("已登录，账号有效", systemImage: "checkmark.shield")
        }
        .help("展开可重新登录")
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
                        .help("直接登记默认 ~/.codex，无需再次登录；CAB 不读取或复制凭据。")
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
                    Text("新启动轮换").font(.headline)
                    Spacer()
                    Toggle("", isOn: Binding(get: { store.status.rotation.enabled }, set: store.setRotationEnabled))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel("启用新启动轮换")
                        .help("仅影响未指定 --account 的 cab run；限额、认证失败和异常不会触发切换。")
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
                    }
                }
            }
            .padding(8)
        } label: {
            Label("自动轮换", systemImage: "arrow.triangle.2.circlepath")
                .help("每次执行未指定账号的 cab run 前选择下一个账号。")
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

private struct UsageResetConfirmationSheet: View {
    let confirmation: UsageResetConfirmation
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(.orange, in: RoundedRectangle(cornerRadius: 18))

            VStack(spacing: 6) {
                Text("重置 Codex 额度？")
                    .font(.title2.bold())
                Text(String(format: cabLocalized("即将为 %@ 使用 1 次额度重置机会"), confirmation.accountName))
                    .font(.headline)
                Text(String(format: cabLocalized("可用次数：%lld"), confirmation.availableCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if confirmation.hasRemainingUsage {
                VStack(alignment: .leading, spacing: 10) {
                    Label("当前额度仍有剩余", systemImage: "exclamationmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    ForEach(Array(confirmation.remainingPeriods.enumerated()), id: \.offset) { _, period in
                        HStack {
                            Text(cabLocalized(period.title))
                            Spacer()
                            Text("\(cabLocalized("剩余")) \(percentText(period.percent))")
                                .fontWeight(.semibold)
                        }
                    }
                    Text("继续后，上述剩余额度会被新周期覆盖，且无法恢复。")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                .padding(14)
                .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.orange.opacity(0.65), lineWidth: 1)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                warningRow("5 小时额度和周额度会同时刷新", systemImage: "arrow.triangle.2.circlepath")
                warningRow("周额度将从确认时重新计算 7 天", systemImage: "calendar.badge.clock")
                warningRow("重置成功后无法撤销", systemImage: "lock.fill")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("使用 1 次重置", role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .padding(28)
        .frame(width: 520)
    }

    private func warningRow(_ title: String, systemImage: String) -> some View {
        Label(cabLocalized(title), systemImage: systemImage)
            .foregroundStyle(.secondary)
    }

    private func percentText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }
}

struct SystemSettingsView: View {
    @EnvironmentObject private var store: CABStore
    @State private var pendingUsageWakeEnable = false
    @State private var usageWakeExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("系统设置", systemImage: "gearshape")
                    .font(.title2.bold())

                GroupBox {
                    HStack {
                        Label("界面语言", systemImage: "globe")
                        Spacer()
                        Picker("界面语言", selection: Binding(
                            get: { store.interfaceLanguage },
                            set: store.setInterfaceLanguage
                        )) {
                            ForEach(InterfaceLanguage.allCases) { language in
                                Text(language.title).tag(language)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    .padding(8)
                } label: {
                    Text("通用")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("自动刷新额度", systemImage: "arrow.clockwise")
                            Spacer()
                            Picker("刷新间隔", selection: Binding(
                                get: { store.usageRefreshInterval },
                                set: store.setUsageRefreshInterval
                            )) {
                                ForEach(UsageRefreshInterval.allCases) { interval in
                                    Text(interval.title).tag(interval)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }

                        Divider()

                        HStack(spacing: 10) {
                            Label("额度重置通知", systemImage: "bell.badge")
                            if let error = store.usageResetNotificationError {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help(error)
                                    .accessibilityLabel(error)
                            } else if store.usageResetNotificationsEnabled && store.scheduledUsageResetNotificationCount > 0 {
                                Text("\(store.scheduledUsageResetNotificationCount) \(cabLocalized("个已安排"))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.isUsageResetNotificationUpdating {
                                ProgressView().controlSize(.small)
                            }
                            Toggle("额度重置通知", isOn: Binding(
                                get: { store.usageResetNotificationsEnabled },
                                set: store.setUsageResetNotificationsEnabled
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(store.isUsageResetNotificationUpdating)
                            .help("在官方额度周期到达重置时间时发送 macOS 通知")
                        }

                        Divider()

                        UsageWakeControlsView(
                            pendingEnable: $pendingUsageWakeEnable,
                            isExpanded: $usageWakeExpanded
                        )
                    }
                    .padding(8)
                } label: {
                    Text("额度与通知")
                }
            }
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 500)
    }
}

private struct UsageWakeControlsView: View {
    @EnvironmentObject private var store: CABStore
    @Binding var pendingEnable: Bool
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .frame(width: 12)
                        Label("额度周期唤醒", systemImage: "bolt.horizontal.circle")
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if store.usageWakeSettings.enabled {
                    Text(cabLocalized("已开启"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.green.opacity(0.12), in: Capsule())
                }
                Toggle("额度周期唤醒", isOn: Binding(
                    get: { store.usageWakeSettings.enabled },
                    set: { enabled in
                        if enabled {
                            pendingEnable = true
                        } else {
                            store.setUsageWakeEnabled(false)
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            if isExpanded {
                details
            }
        }
        .confirmationDialog("启用额度周期唤醒？", isPresented: $pendingEnable, titleVisibility: .visible) {
            Button("确认启用") {
                store.setUsageWakeEnabled(true)
                pendingEnable = false
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("启用后，CAB 会在额度恢复或你设置的时间先查询额度。只有五小时或周周期尚未开始倒计时时，才向官方 Codex 发送一次极小的真实请求。")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("只发送最低消耗的官方 Codex 请求；普通额度查询不会消耗 Token。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("额度恢复后启动周期", isOn: Binding(
                get: { store.usageWakeSettings.wakeOnRecovery },
                set: store.setUsageWakeRecoveryEnabled
            ))

            HStack {
                Text("周期启动时间").fontWeight(.medium)
                Spacer()
                Button {
                    store.addUsageWakeProbeTime()
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(store.usageWakeSettings.weeklyProbeTimes.count >= usageWakeMaximumEntries)
            }
            ForEach(Array(store.usageWakeSettings.weeklyProbeTimes.enumerated()), id: \.offset) { index, time in
                HStack {
                    DatePicker(
                        "时间 \(index + 1)",
                        selection: probeDateBinding(index: index),
                        displayedComponents: .hourAndMinute
                    )
                    Spacer()
                    Button(role: .destructive) {
                        store.removeUsageWakeProbeTime(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("删除时间 \(time.id)")
                }
            }

            HStack {
                Text("暂停自动刷新时段").fontWeight(.medium)
                Spacer()
                Button {
                    store.addUsageWakeQuietPeriod()
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(store.usageWakeSettings.quietPeriods.count >= usageWakeMaximumEntries)
            }
            ForEach(Array(store.usageWakeSettings.quietPeriods.enumerated()), id: \.offset) { index, period in
                HStack(spacing: 8) {
                    DatePicker(
                        "开始",
                        selection: quietStartDateBinding(index: index),
                        displayedComponents: .hourAndMinute
                    )
                    Text("至").foregroundStyle(.secondary)
                    DatePicker(
                        "结束",
                        selection: quietEndDateBinding(index: index),
                        displayedComponents: .hourAndMinute
                    )
                    Spacer()
                    Button(role: .destructive) {
                        store.removeUsageWakeQuietPeriod(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("删除暂停时段 \(period.id)")
                }
            }

            Text("设定时间会优先执行；到点仅在五小时或周周期没有倒计时时发送一次。其他自动刷新在暂停时段内不运行。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    private func probeDateBinding(index: Int) -> Binding<Date> {
        Binding(
            get: {
                guard store.usageWakeSettings.weeklyProbeTimes.indices.contains(index) else { return Date() }
                return store.usageWakeDate(for: store.usageWakeSettings.weeklyProbeTimes[index])
            },
            set: { store.setUsageWakeProbeTime(at: index, date: $0) }
        )
    }

    private func quietStartDateBinding(index: Int) -> Binding<Date> {
        Binding(
            get: {
                guard store.usageWakeSettings.quietPeriods.indices.contains(index) else { return Date() }
                return store.usageWakeDate(for: store.usageWakeSettings.quietPeriods[index].start)
            },
            set: { store.setUsageWakeQuietStart(at: index, date: $0) }
        )
    }

    private func quietEndDateBinding(index: Int) -> Binding<Date> {
        Binding(
            get: {
                guard store.usageWakeSettings.quietPeriods.indices.contains(index) else { return Date() }
                return store.usageWakeDate(for: store.usageWakeSettings.quietPeriods[index].end)
            },
            set: { store.setUsageWakeQuietEnd(at: index, date: $0) }
        )
    }
}

private struct DesktopSwitchProcessSheet: View {
    let request: DesktopSwitchProcessRequest
    let isBusy: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 5) {
                    Text("还有 Codex 会话正在运行")
                        .font(.title2.bold())
                    Text("关闭下列会话后，才能安全切换到 \(request.account.name)。")
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(request.processes) { process in
                        HStack(spacing: 12) {
                            Image(systemName: process.title == nil ? "terminal" : "text.bubble")
                                .frame(width: 22)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(process.title ?? process.label)
                                    .fontWeight(.medium)
                                    .lineLimit(2)
                                Text("\(process.label) · PID \(process.pid)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            .frame(maxHeight: 260)

            VStack(alignment: .leading, spacing: 6) {
                Text("CAB 会先请求正常退出；超时后只会强制结束身份未变化的上述 Codex 进程。请先保存任务内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .disabled(isBusy)
                Button(role: .destructive, action: onContinue) {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("关闭这些会话并切换")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isBusy)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 340)
        .interactiveDismissDisabled(isBusy)
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
                Text("远程服务器")
                    .font(.title2.bold())
                    .help("连接信息只保存在这台 Mac，不会写入项目或上传 Git。")
                if let importResult {
                    Text(importResult).font(.callout).foregroundStyle(.green)
                }
            }

            if draftServers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "server.rack").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("尚未添加服务器").font(.headline)
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
