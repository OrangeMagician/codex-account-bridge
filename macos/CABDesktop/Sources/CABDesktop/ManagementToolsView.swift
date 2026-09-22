import SwiftUI
import AppKit

struct ManagementToolsView: View {
    @EnvironmentObject var store: CABStore
    @ObservedObject var model: ManagementToolsStore
    let section: String
    var performsLiveChecks = true
    @State private var backupFilter = ""
    @State private var backupLimit = 50
    @State private var editingProfile: ProjectLaunchProfile?
    private var context: String { store.target.rawValue + ":" + store.remoteHost }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
            }
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle").foregroundStyle(.secondary).textSelection(.enabled)
            }
            switch section {
            case "cab.history": history
            case "cab.projects": projects
            default: diagnostics; backups
            }
        }
        .task(id: context + section) {
            guard performsLiveChecks else { return }
            model.changeContext(target: store.target, host: store.remoteHost)
            if section == "cab.tools" { model.refresh(target: store.target, host: store.remoteHost) }
        }
        .sheet(item: $editingProfile) { profile in
            ProjectProfileEditor(profile: profile, accounts: store.status.accounts.filter(\.isLoggedIn)) { updated in
                try model.saveProfile(updated)
            }
        }
        .sheet(item: $model.preview) { plan in
            VStack(alignment: .leading, spacing: 16) {
                Label(plan.action == "restore" ? "恢复备份" : "删除备份", systemImage: plan.action == "restore" ? "arrow.uturn.backward" : "trash")
                    .font(.title2)
                Text(plan.backup.path).font(.callout.monospaced()).textSelection(.enabled)
                LabeledContent("目标", value: plan.backup.target)
                LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: plan.backup.bytes, countStyle: .file))
                Text(plan.action == "restore" ? "恢复会覆盖此账号的对应内容；CAB 会先备份当前版本。请先退出所有 Codex 进程。" : "这会永久删除所选备份，当前工作区不会改变。")
                    .foregroundStyle(.secondary)
                if !plan.allowed { Label(plan.reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                HStack {
                    Spacer()
                    Button("取消", role: .cancel) { model.preview = nil }
                    Button(plan.action == "restore" ? "确认恢复" : "确认删除", role: .destructive) {
                        model.applyPreview(target: store.target, host: store.remoteHost)
                    }.disabled(!plan.allowed)
                }
            }
            .padding(24).frame(width: 600)
        }
    }

    private var diagnostics: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("检查执行路径、账号路由、运行进程与功能兼容性。")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.busy {
                        ProgressView().controlSize(.small)
                        if !model.mutating { Button("取消检查") { model.cancel() } }
                    } else {
                        Button("重新诊断") { model.refresh(target: store.target, host: store.remoteHost) }
                    }
                }
                if let report = model.diagnostics {
                    LabeledContent("CAB 版本", value: report.cabVersion)
                    LabeledContent("Codex 版本", value: report.codexVersion.trimmingCharacters(in: .whitespacesAndNewlines))
                    LabeledContent("实际执行路径", value: report.codexPath)
                    LabeledContent("PATH 入口", value: report.entryPoint)
                    LabeledContent("新 CLI 账号", value: report.defaultAccount.isEmpty ? cabLocalized("未设置") : report.defaultAccount)
                    if store.target == .local {
                        LabeledContent("当前桌面账号", value: currentDesktopAccount)
                    } else {
                        LabeledContent("新连接账号", value: report.remoteAccount.isEmpty ? cabLocalized("未设置") : report.remoteAccount)
                        Text("已有连接继续使用原账号；选择新账号仅影响后续连接。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    ForEach(report.checks) { check in
                        Label(diagnosticDetail(check.detail), systemImage: check.ok ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(check.ok ? Color.secondary : Color.orange)
                            .font(.callout).textSelection(.enabled)
                    }
                    DisclosureGroup("支持的功能") {
                        Text(report.capabilities.joined(separator: " · ")).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    DisclosureGroup("运行中的 Codex 进程") {
                        if report.processes.isEmpty { Text("未发现运行中的 Codex 进程").foregroundStyle(.secondary) }
                        ForEach(report.processes) { process in
                            HStack { Text("PID \(process.pid)").monospacedDigit(); Text(process.elapsed); Spacer(); Text(process.executable).lineLimit(2) }
                                .font(.caption).textSelection(.enabled)
                        }
                    }
                } else if !model.busy { Text("点击重新诊断以检查当前目标。").foregroundStyle(.secondary) }
            }.padding(8)
        } label: { Label("诊断中心", systemImage: "stethoscope") }
    }

    private var currentDesktopAccount: String {
        switch currentLocalDesktopHome() {
        case .running(let home): return store.status.accounts.first(where: { $0.home == home })?.name ?? home
        case .notRunning: return cabLocalized("桌面客户端未运行")
        case .unknown: return cabLocalized("无法确认")
        }
    }

    private var backups: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("仅列出 CAB 创建且可识别归属的备份。恢复会保留当前版本；清理前逐项预览。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("筛选账号或文件名", text: $backupFilter)
                        .textFieldStyle(.roundedBorder)
                    Text(ByteCountFormatter.string(fromByteCount: model.backups.reduce(0) { $0 + $1.bytes }, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                let filtered = model.backups.filter { backupFilter.isEmpty || $0.account.localizedCaseInsensitiveContains(backupFilter) || $0.path.localizedCaseInsensitiveContains(backupFilter) }
                if filtered.isEmpty { Text("未发现备份").foregroundStyle(.secondary) }
                ForEach(Array(filtered.prefix(backupLimit))) { backup in
                    DisclosureGroup {
                        Text(backup.path).font(.caption.monospaced()).textSelection(.enabled)
                        Text(backup.target).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        if let problem = backup.problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                        HStack {
                            Spacer()
                            Button("预览恢复") { model.prepare(backup, action: "restore", target: store.target, host: store.remoteHost) }
                            Button("预览删除", role: .destructive) { model.prepare(backup, action: "delete", target: store.target, host: store.remoteHost) }
                        }.disabled(model.busy || !backup.safe)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(backup.account + " · " + URL(fileURLWithPath: backup.target).lastPathComponent)
                                Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: backup.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if filtered.count > backupLimit {
                    Button("显示更多备份") { backupLimit += 50 }
                }
            }.padding(8)
        } label: { Label("备份管理", systemImage: "externaldrive.badge.timemachine") }
    }

    private var history: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("保留最近 200 次操作的阶段与备份位置，不保存任务正文和登录凭据。")
                    .font(.callout).foregroundStyle(.secondary)
                if model.records.isEmpty { Text("暂无切换记录").foregroundStyle(.secondary) }
                ForEach(model.records) { record in
                    DisclosureGroup {
                        Text(record.host.isEmpty ? cabLocalized("这台 Mac") : record.host).font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(record.stages.enumerated()), id: \.offset) { _, stage in Text(cabLocalized(stage)).font(.callout) }
                        ForEach(record.backups, id: \.self) { path in Text(path).font(.caption.monospaced()).textSelection(.enabled) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.source + " → " + record.destination).lineLimit(2)
                                Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(cabLocalized(record.outcome)).font(.caption)
                                .foregroundStyle(record.outcome == "已完成" ? Color.secondary : Color.orange)
                        }
                    }
                }
            }.padding(8)
        } label: { Label("切换记录", systemImage: "clock.arrow.circlepath") }
    }

    private var projects: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("为项目保存明确的账号与运行位置。启动时仍使用 Codex 原有审批与沙箱设置。")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("添加启动配置") {
                        editingProfile = ProjectLaunchProfile(name: "", directory: "", account: "", remoteHost: store.target == .remote ? store.remoteHost : "")
                    }.disabled(store.status.accounts.filter(\.isLoggedIn).isEmpty || (store.target == .remote && store.remoteHost.isEmpty))
                }
                let profiles = model.profiles.filter { $0.remoteHost == (store.target == .remote ? store.remoteHost : "") }
                if profiles.isEmpty { Text("当前目标暂无启动配置").foregroundStyle(.secondary) }
                ForEach(profiles) { profile in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(profile.name, systemImage: "folder")
                            Spacer()
                            Text(profile.account).font(.caption).foregroundStyle(.secondary)
                            Button { model.launch(profile) } label: { Label("启动", systemImage: "play.fill") }.buttonStyle(.bordered).disabled(model.busy)
                            Menu {
                                Button("编辑") { editingProfile = profile }
                                Button("移除配置", role: .destructive) { model.removeProfile(profile.id) }
                            } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).fixedSize().help("管理启动配置")
                        }
                        Text(profile.directory).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if profile.id != profiles.last?.id { Divider() }
                }
            }.padding(8)
        } label: { Label("项目启动", systemImage: "folder.badge.gearshape") }
    }
}

struct ProjectProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: ProjectLaunchProfile
    let accounts: [AccountStatus]
    let save: (ProjectLaunchProfile) throws -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("项目启动配置").font(.title2)
            Form {
                TextField("名称", text: $profile.name)
                TextField("项目绝对路径", text: $profile.directory)
                Picker("账号", selection: $profile.account) {
                    Text("选择账号").tag("")
                    ForEach(accounts) { account in Text(account.name).tag(account.name) }
                }
                LabeledContent("运行位置", value: profile.remoteHost.isEmpty ? cabLocalized("这台 Mac") : profile.remoteHost)
            }
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("保存") {
                    do { try save(profile); dismiss() } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(profile.account.isEmpty)
            }
        }.padding(24).frame(width: 520)
    }
}
