import AppKit
import Foundation

struct DiagnosticCheck: Codable, Identifiable {
    let id: String
    let ok: Bool
    let detail: String
}
struct DiagnosticReport: Codable {
    let cabVersion: String
    let codexPath: String
    let codexVersion: String
    let entryPoint: String
    let defaultAccount: String
    let remoteAccount: String
    let capabilities: [String]
    let checks: [DiagnosticCheck]
    let processes: [DiagnosticProcess]
}
struct DiagnosticProcess: Codable, Identifiable {
    var id: Int { pid }
    let pid: Int
    let elapsed: String
    let executable: String
}
struct CABCapabilities: Codable {
    let protocolVersion: Int
    let cabVersion: String
    let capabilities: [String]
}
struct ManagedBackup: Codable, Identifiable {
    let id: String
    let account: String
    let path: String
    let target: String
    let bytes: Int64
    let createdAt: Date
    let kind: String
    let safe: Bool
    let problem: String?
}
struct BackupList: Codable { let backups: [ManagedBackup] }
struct BackupPreview: Codable, Identifiable {
    var id: String { backup.id + action }
    let backup: ManagedBackup
    let action: String
    let allowed: Bool
    let reason: String
}
struct BackupResult: Codable { let completed: Bool; let rollbackBackup: String }

struct ProjectLaunchProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var directory: String
    var account: String
    var remoteHost: String
    var target: BridgeTarget { remoteHost.isEmpty ? .local : .remote }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              directory.hasPrefix("/"), !directory.contains("\n"), !directory.contains("\0"),
              account.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$", options: .regularExpression) != nil else {
            throw BridgeError.commandFailed(cabLocalized("请填写名称、绝对项目路径并显式选择账号。"))
        }
    }
}

struct SwitchRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    let host: String
    let source: String
    let destination: String
    var outcome = "进行中"
    var stages: [String] = []
    var backups: [String] = []
}

@MainActor
final class ManagementToolsStore: ObservableObject {
    @Published var diagnostics: DiagnosticReport?
    @Published var backups: [ManagedBackup] = []
    @Published var capabilities: CABCapabilities?
    @Published var error: String?
    @Published var notice: String?
    @Published var busy = false
    @Published var preview: BackupPreview?
    @Published var records: [SwitchRecord]
    @Published var profiles: [ProjectLaunchProfile]
    private let defaults: UserDefaults
    private let service: CABService
    private var context = ""
    private var operationGeneration = 0
    private var operation: Task<Void, Never>?
    private var previewContext = ""
    @Published private(set) var mutating = false

    init(defaults: UserDefaults = .standard, service: CABService = CABService()) {
        self.defaults = defaults
        self.service = service
        records = defaults.data(forKey: "switchRecords.v1").flatMap { try? JSONDecoder().decode([SwitchRecord].self, from: $0) } ?? []
        profiles = defaults.data(forKey: "projectLaunchProfiles.v1").flatMap { try? JSONDecoder().decode([ProjectLaunchProfile].self, from: $0) } ?? []
        for index in records.indices where records[index].outcome == "进行中" { records[index].outcome = "结果待确认" }
        persistRecords()
    }

    func beginRecord(host: String, source: String, destination: String) -> UUID {
        let record = SwitchRecord(host: host, source: source, destination: destination)
        records.insert(record, at: 0)
        records = Array(records.prefix(200))
        persistRecords()
        return record.id
    }
    func record(_ id: UUID, stage: String? = nil, outcome: String? = nil, backups: [String] = []) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if let stage { records[index].stages.append(stage) }
        if let outcome { records[index].outcome = outcome }
        records[index].backups += backups.filter { !records[index].backups.contains($0) }
        persistRecords()
    }
    private func persistRecords() {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: "switchRecords.v1") }
    }
    func saveProfile(_ profile: ProjectLaunchProfile) throws {
        try profile.validate()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        persistProfiles()
    }
    func removeProfile(_ id: UUID) { profiles.removeAll { $0.id == id }; persistProfiles() }
    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "projectLaunchProfiles.v1") }
    }

    func changeContext(target: BridgeTarget, host: String) {
        let next = target.rawValue + ":" + host
        guard next != context else { return }
        if !mutating {
            operation?.cancel(); service.cancelReadOperations()
            operationGeneration += 1; busy = false
        }
        context = next
        diagnostics = nil; capabilities = nil; backups = []; preview = nil; error = nil; notice = nil
    }

    func refresh(target: BridgeTarget, host: String) {
        guard !busy else { return }
        changeContext(target: target, host: host)
        let captured = context
        busy = true; error = nil; notice = nil
        let generation = operationGeneration
        operation = Task {
            defer { if generation == operationGeneration { busy = false } }
            do {
                let supported: CABCapabilities = try await service.managementJSON(["capabilities"], target: target, host: host)
                guard captured == context, !Task.isCancelled else { return }
                capabilities = supported
                guard supported.capabilities.contains("doctor-json-v1"), supported.capabilities.contains("backups-v1") else {
                    throw BridgeError.commandFailed(cabLocalized("服务器 CAB 不支持此功能，请先更新服务器 CAB。"))
                }
                async let report: DiagnosticReport = service.managementJSON(["doctor", "--json"], target: target, host: host)
                async let list: BackupList = service.managementJSON(["backups", "list", "--json"], target: target, host: host)
                let values = try await (report, list)
                guard captured == context, !Task.isCancelled else { return }
                diagnostics = values.0; backups = values.1.backups
            } catch is CancellationError { }
            catch { if captured == context { self.error = error.localizedDescription } }
        }
    }

    func cancel() { guard !mutating else { return }; operation?.cancel(); service.cancelReadOperations() }

    func prepare(_ backup: ManagedBackup, action: String, target: BridgeTarget, host: String) {
        guard !busy else { return }
        let captured = context
        busy = true; error = nil
        let generation = operationGeneration
        operation = Task {
            defer { if generation == operationGeneration { busy = false } }
            do {
                let result: BackupPreview = try await service.managementJSON(["backups", "preview", "--id", backup.id, "--action", action, "--json"], target: target, host: host)
                guard captured == context, !Task.isCancelled else { return }
                previewContext = captured; preview = result
            } catch { if captured == context { self.error = error.localizedDescription } }
        }
    }

    func applyPreview(target: BridgeTarget, host: String) {
        guard !busy, let plan = preview, plan.allowed, context == previewContext else { return }
        let captured = context
        preview = nil; busy = true; mutating = true; error = nil
        operation = Task {
            defer { busy = false; mutating = false }
            do {
                var arguments = ["backups", plan.action, "--id", plan.backup.id, "--confirm", "--json"]
                if plan.action == "restore" { arguments.append("--confirm-codex-stopped") }
                let result: BackupResult = try await service.managementJSON(arguments, target: target, host: host)
                if plan.action == "restore" {
                    let id = beginRecord(host: host, source: plan.backup.path, destination: plan.backup.target)
                    record(id, stage: "备份恢复完成", outcome: "已完成", backups: result.rollbackBackup.isEmpty ? [] : [result.rollbackBackup])
                }
                let list: BackupList = try await service.managementJSON(["backups", "list", "--json"], target: target, host: host)
                guard captured == context else { return }
                backups = list.backups
                notice = cabLocalized(plan.action == "restore" ? "恢复已完成。当前工作区的回退备份可在列表中查看。" : "所选备份已删除，当前工作区未改变。")
            } catch { if captured == context { self.error = error.localizedDescription } }
        }
    }

    func launch(_ profile: ProjectLaunchProfile) {
        guard !busy else { return }
        busy = true; error = nil
        let generation = operationGeneration
        operation = Task {
            defer { if generation == operationGeneration { busy = false } }
            do {
                try profile.validate()
                let status = try await service.loadStatus(target: profile.target, remoteHost: profile.remoteHost)
                guard status.accounts.contains(where: { $0.name == profile.account && $0.isLoggedIn }) else {
                    throw BridgeError.commandFailed(cabLocalized("此启动配置的账号已移除或尚未登录，请先编辑配置。"))
                }
                let supported: CABCapabilities = try await service.managementJSON(["capabilities"], target: profile.target, host: profile.remoteHost)
                guard supported.capabilities.contains("project-directory-v1") else {
                    throw BridgeError.commandFailed(cabLocalized("服务器 CAB 不支持此功能，请先更新服务器 CAB。"))
                }
                try Task.checkCancellation()
                try service.launchCodexInTerminal(target: profile.target, remoteHost: profile.remoteHost, accountName: profile.account, directory: profile.directory)
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

extension CABService {
    func managementJSON<Value: Decodable>(_ arguments: [String], target: BridgeTarget, host: String) async throws -> Value {
        let result = try await execute(arguments, target: target, remoteHost: host)
        guard result.exitCode == 0 else { throw BridgeError.commandFailed(result.errorOutput.isEmpty ? result.output : result.errorOutput) }
        let decoder = cabDateDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Value.self, from: Data(result.output.utf8))
    }
}

func diagnosticDetail(_ detail: String) -> String {
    let exact: [String: String] = [
        "official codex executable is reachable": "官方 Codex 可执行文件可用",
        "Official Codex executable is reachable": "官方 Codex 可执行文件可用",
        "at least one account is configured": "已登记账号",
        "config path resolved": "配置路径已解析",
        "session transaction journal is valid": "会话事务日志有效",
        "no interrupted session transaction requires recovery": "没有待恢复的会话事务",
        "Official Codex version query": "官方 Codex 版本查询",
        "Server CAB update required": "服务器 CAB 需要更新"
    ]
    if let key = exact[detail] { return cabLocalized(key) }
    let suffixes: [String: String] = [
        " home is a real directory": "账号目录有效",
        " home permissions exclude group/other": "账号目录权限仅限当前用户",
        " is logged in through the official Codex CLI": "官方登录状态有效",
        " auth.json is a regular file": "认证文件类型有效（未读取内容）",
        " auth.json permissions exclude group/other": "认证文件权限仅限当前用户（未读取内容）",
        " sessions link targets the shared store": "会话链接指向共享库",
        " archived_sessions link targets the shared store": "归档会话链接指向共享库"
    ]
    for (suffix, key) in suffixes where detail.hasSuffix(suffix) {
        return String(detail.dropLast(suffix.count)) + " · " + cabLocalized(key)
    }
    return detail
}
