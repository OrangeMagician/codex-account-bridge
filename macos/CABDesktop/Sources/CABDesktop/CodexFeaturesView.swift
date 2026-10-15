import SwiftUI

struct CodexFeaturesView: View {
    @EnvironmentObject var store: CABStore
    @ObservedObject var model: CodexFeaturesStore
    let section: String
    var performsLiveChecks = true
    @State private var account = ""
    @State private var search = ""
    @State private var directory = ""
    @State private var archived = false
    @State private var pinnedOnly = false
    @State private var repository = ""
    @State private var ref = "HEAD"
    @State private var showsCreate = false
    @State private var removing: ManagedWorktree?
    @State private var appliedFilter = ""
    private var key: String { store.target.rawValue + ":" + store.remoteHost + ":" + account + ":" + section }
    private var filterKey: String { search + "\0" + directory + "\0" + String(archived) + String(pinnedOnly) }

    init(model: CodexFeaturesStore, section: String, performsLiveChecks: Bool = true, initialAccount: String = "") {
        self.model = model; self.section = section; self.performsLiveChecks = performsLiveChecks
        _account = State(initialValue: initialAccount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Picker("账号", selection: $account) {
                    Text("选择账号").tag("")
                    ForEach(store.status.accounts.filter(\.isLoggedIn)) { Text($0.name).tag($0.name) }
                }.frame(maxWidth: 320).disabled(model.mutating)
                Spacer()
                if model.busy {
                    ProgressView().controlSize(.small)
                    if !model.mutating { Button("取消检查") { model.cancel() } }
                } else { Button("刷新") { refresh() }.disabled(account.isEmpty) }
            }
            if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
            if account.isEmpty {
                Label("选择账号后查询当前主机，操作仅作用于所选账号。", systemImage: "person.crop.circle").foregroundStyle(.secondary)
            } else {
                switch section {
                case "cab.tasks": taskHistory
                case "cab.worktrees": worktrees
                default: modelCatalog
                }
            }
        }
        .task(id: key) {
            guard performsLiveChecks else { return }
            model.changeContext(key)
            if !account.isEmpty { refresh() }
        }
        .onChange(of: key) { _ in removing = nil }
        .onChange(of: store.target) { _ in account = "" }
        .onChange(of: store.remoteHost) { _ in account = "" }
        .onChange(of: store.status.accounts.map(\.name)) { names in if !names.contains(account) { account = "" } }
        .confirmationDialog("移除 CAB Worktree？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("确认移除", role: .destructive) {
                if let tree = removing { model.removeWorktree(tree, account: account, target: store.target, host: store.remoteHost) }; removing = nil
            }
            Button("取消", role: .cancel) { removing = nil }
        } message: {
            Text("仅移除所选 CAB Worktree。请先退出 Codex；存在未保存改动时会拒绝移除。")
        }
    }

    private func refresh(more: Bool = false) {
        guard !account.isEmpty else { return }
        if section == "cab.tasks" && !more { appliedFilter = filterKey }
        switch section {
        case "cab.tasks": model.loadTasks(account: account, target: store.target, host: store.remoteHost, search: search, directory: directory, archived: archived, pinned: pinnedOnly, more: more)
        case "cab.worktrees": model.loadWorktrees(account: account, target: store.target, host: store.remoteHost)
        default: model.loadModels(account: account, target: store.target, host: store.remoteHost)
        }
    }

    private var modelCatalog: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("目录由所选账号的官方 Codex 返回。模型和速度资格仍由官方服务在请求时确认。")
                    .font(.callout).foregroundStyle(.secondary)
                if let catalog = model.catalog {
                    if catalog.models.isEmpty { Text("此客户端没有返回可选择的模型。").foregroundStyle(.secondary) }
                    ForEach(catalog.models) { option in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(option.displayName).font(.headline)
                                if option.isDefault { Text("官方推荐").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(option.model).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(option.description).font(.callout).foregroundStyle(.secondary)
                            LabeledContent("思考强度", value: option.supportedReasoningEfforts.map(\.reasoningEffort).joined(separator: " · "))
                            if !option.advertisedSpeeds.isEmpty { LabeledContent("速度档位", value: option.advertisedSpeeds.joined(separator: " · ")) }
                            if let notice = retirementNotice(option.model) { Label(notice, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                            if let upgrade = option.upgrade { LabeledContent("官方建议替代", value: upgrade) }
                        }
                        if option.id != catalog.models.last?.id { Divider() }
                    }
                    Text(catalog.fetchedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                } else if !model.busy { Text("点击刷新以读取此账号的模型目录。").foregroundStyle(.secondary) }
                Divider()
                Text("可在项目启动配置中保存模型、思考强度与速度。未选择时沿用官方默认。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("插件接口状态") {
                    Text("官方 plugin/list、安装和卸载接口仍处于开发中，暂不用于正式管理。账号之间不复制插件授权。")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("官方接口文档", destination: URL(string: "https://learn.chatgpt.com/docs/app-server")!)
                }
            }.padding(8)
        } label: { Label("模型与速度", systemImage: "slider.horizontal.3") }
    }

    private var taskHistory: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("显示所选账号的本机历史，不代表其他连接中的实时运行状态。共享历史可能来自其他账号。")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("搜索任务标题", text: $search).textFieldStyle(.roundedBorder).onSubmit { refresh() }
                TextField("项目绝对路径（可选）", text: $directory).textFieldStyle(.roundedBorder).onSubmit { refresh() }
                HStack {
                    Toggle("已归档", isOn: $archived)
                    Toggle("仅置顶", isOn: $pinnedOnly)
                    Spacer()
                    Button("查询") { refresh() }
                }.disabled(model.busy)
                if model.tasks.isEmpty && !model.busy { Text("未找到任务，可调整筛选后重新查询。").foregroundStyle(.secondary) }
                ForEach(model.tasks) { task in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.title).font(.headline).textSelection(.enabled)
                                Text(Date(timeIntervalSince1970: Double(task.updatedAt)).formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if task.isPinned != nil {
                                Button { model.pin(task, account: account, target: store.target, host: store.remoteHost) } label: {
                                    Image(systemName: task.isPinned == true ? "pin.fill" : "pin")
                                }.help(cabLocalized(task.isPinned == true ? "取消置顶" : "置顶任务"))
                                    .accessibilityLabel(cabLocalized(task.isPinned == true ? "取消置顶" : "置顶任务"))
                            }
                            Button("在终端恢复") { model.resume(task, account: account, target: store.target, host: store.remoteHost) }.disabled(archived)
                        }.disabled(model.busy)
                        Text(task.cwd).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        if task.id != model.tasks.last?.id { Divider() }
                    }
                }
                if model.nextCursor != nil { Button("显示更多任务") { refresh(more: true) }.disabled(model.busy || appliedFilter != filterKey) }
            }.padding(8)
        } label: { Label("最近任务", systemImage: "text.bubble") }
    }

    private var worktrees: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("管理 CAB 创建的独立 Git 工作目录，Codex 桌面端的内部 Worktree 不在此列表。")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(cabLocalized(showsCreate ? "收起" : "创建 Worktree")) { showsCreate.toggle() }.disabled(model.busy)
                }
                if showsCreate {
                    TextField("Git 仓库绝对路径", text: $repository).textFieldStyle(.roundedBorder)
                    TextField("起始分支或提交", text: $ref).textFieldStyle(.roundedBorder)
                    HStack {
                        Text("从指定提交创建独立目录，不复制当前未提交改动，也不自动信任项目。")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("确认创建") { model.createWorktree(account: account, target: store.target, host: store.remoteHost, directory: repository, ref: ref) }
                            .buttonStyle(.borderedProminent).disabled(model.busy || !repository.hasPrefix("/"))
                    }
                    Divider()
                }
                if model.worktrees.isEmpty && !model.busy { Text("此账号暂无 CAB Worktree。").foregroundStyle(.secondary) }
                ForEach(model.worktrees) { tree in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(URL(fileURLWithPath: tree.repository).lastPathComponent + " · " + tree.ref, systemImage: "arrow.triangle.branch")
                            Spacer()
                            Button("启动") { model.launchWorktree(tree, target: store.target, host: store.remoteHost) }.disabled(!tree.exists || model.busy)
                            Menu { Button("移除 Worktree", role: .destructive) { removing = tree } } label: { Image(systemName: "ellipsis") }
                                .menuStyle(.borderlessButton).fixedSize().help("管理 Worktree").disabled(!tree.exists || model.busy)
                        }
                        Text(tree.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        if !tree.exists { Label("工作目录已缺失，请检查 Git 注册状态。", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    }
                    if tree.id != model.worktrees.last?.id { Divider() }
                }
            }.padding(8)
        } label: { Label("CAB Worktree", systemImage: "arrow.triangle.branch") }
    }
}

struct LaunchPresetFields: View {
    @Binding var preset: LaunchPreset
    let catalog: AccountModelCatalog?
    private var option: CodexModelOption? { catalog?.models.first(where: { !preset.model.isEmpty && $0.model == preset.model }) }

    var body: some View {
        Picker("模型", selection: $preset.model) {
            Text("官方默认").tag("")
            if let catalog { ForEach(catalog.models) { Text($0.displayName).tag($0.model) } }
            if !preset.model.isEmpty && catalog?.models.contains(where: { $0.model == preset.model }) != true { Text(preset.model + " · " + cabLocalized("待验证")).tag(preset.model) }
        }.onChange(of: preset.model) { _ in preset.effort = ""; preset.speed = "" }
        Picker("思考强度", selection: $preset.effort) {
            Text("官方默认").tag("")
            ForEach(option?.supportedReasoningEfforts ?? [], id: \.reasoningEffort) { Text($0.reasoningEffort).tag($0.reasoningEffort) }
            if !preset.effort.isEmpty && option?.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == preset.effort }) != true { Text(preset.effort + " · " + cabLocalized("待验证")).tag(preset.effort) }
        }
        Picker("速度档位", selection: $preset.speed) {
            Text("官方默认").tag("")
            ForEach(option?.advertisedSpeeds ?? [], id: \.self) { Text($0.capitalized).tag($0) }
            if !preset.speed.isEmpty && option?.advertisedSpeeds.contains(preset.speed) != true { Text(preset.speed + " · " + cabLocalized("待验证")).tag(preset.speed) }
        }
        if let notice = speedCostNotice(preset.speed) { Text(notice).font(.caption).foregroundStyle(.secondary) }
        if let notice = retirementNotice(preset.model) { Label(notice, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
    }
}
