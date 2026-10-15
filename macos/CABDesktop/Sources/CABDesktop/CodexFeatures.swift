import AppKit
import Foundation

struct ProcessAccountRoute: Codable, Identifiable {
    var id: Int { pid }
    let pid: Int
    let account: String?
    let home: String?
    let role: String
    let verified: Bool
    let matchesNextConnection: Bool
}

struct ModelEffort: Codable, Hashable { let reasoningEffort: String; let description: String }
struct ModelSpeed: Codable, Hashable, Identifiable { let id: String; let name: String; let description: String }
struct CodexModelOption: Codable, Identifiable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let isDefault: Bool
    let defaultReasoningEffort: String
    let supportedReasoningEfforts: [ModelEffort]
    let serviceTiers: [ModelSpeed]?
    let additionalSpeedTiers: [String]?
    let upgrade: String?

    var advertisedSpeeds: [String] {
        Array(Set((serviceTiers ?? []).map { $0.id == "priority" ? "fast" : $0.id } + (additionalSpeedTiers ?? [])))
            .filter { ["standard", "fast", "ultrafast"].contains($0) }.sorted()
    }
}
struct AccountModelCatalog: Codable { let models: [CodexModelOption]; let fetchedAt: Date; let scope: String }

struct LaunchPreset: Codable, Equatable {
    var model = ""
    var effort = ""
    var speed = ""
    var isDefault: Bool { model.isEmpty && effort.isEmpty && speed.isEmpty }
    var arguments: [String] {
        (model.isEmpty ? [] : ["--model", model]) + (effort.isEmpty ? [] : ["--effort", effort]) + (speed.isEmpty ? [] : ["--speed", speed])
    }
    var summary: String { isDefault ? cabLocalized("官方默认") : ([model.isEmpty ? cabLocalized("官方默认模型") : model, effort, speed].filter { !$0.isEmpty }.joined(separator: " · ")) }
    func validateSyntax() throws {
        for value in [model, effort, speed] {
            guard value.utf8.count <= 200, !value.contains(where: { $0.isWhitespace || $0 == "\0" }), !value.hasPrefix("-") else { throw BridgeError.commandFailed(cabLocalized("启动预设包含无效值。")) }
        }
        guard speed.isEmpty || ["standard", "fast", "ultrafast"].contains(speed) else { throw BridgeError.commandFailed(cabLocalized("请选择受支持的速度档位。")) }
    }
    func validate(catalog: AccountModelCatalog) throws {
        try validateSyntax()
        guard !isDefault else { return }
        guard !model.isEmpty else { throw BridgeError.commandFailed(cabLocalized("设置思考强度或速度前，请先明确选择模型。")) }
        guard let option = catalog.models.first(where: { $0.model == model }) else { throw BridgeError.commandFailed(cabLocalized("所选模型已不在此账号的目录中，请重新选择。")) }
        if !effort.isEmpty && !option.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == effort }) { throw BridgeError.commandFailed(cabLocalized("所选模型不支持此思考强度。")) }
        if !speed.isEmpty && !option.advertisedSpeeds.contains(speed) { throw BridgeError.commandFailed(cabLocalized("此模型未提供所选速度档位，请使用官方默认。")) }
    }
}

func speedCostNotice(_ speed: String) -> String? {
    switch speed {
    case "fast": return cabLocalized("Fast 消耗订阅额度为标准的 2.5 倍，购买 Credits 的计费为 2 倍。")
    case "ultrafast": return cabLocalized("Ultrafast 消耗订阅额度为标准的 8 倍，购买 Credits 的计费为 6 倍。资格由官方账号与工作区决定。")
    default: return nil
    }
}
func retirementNotice(_ model: String) -> String? {
    switch model {
    case "gpt-5.5": return cabLocalized("GPT-5.5 于 2026 年 10 月 14 日退出通过 ChatGPT 登录的 Codex，请选择此账号目录中的替代模型。历史 Token 仍可计价。")
    case "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex-spark", "gpt-5.2", "gpt-5.3-codex": return cabLocalized("此模型已退出或被弃用，请确认当前账号目录并选择替代模型。")
    default: return nil
    }
}

struct StoredCodexTask: Codable, Identifiable {
    let id: String
    let name: String?
    let cwd: String
    let updatedAt: Int64
    let isPinned: Bool?
    var title: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? id }
}
struct StoredTaskPage: Codable { let tasks: [StoredCodexTask]; let nextCursor: String?; let scope: String }
struct ManagedWorktree: Codable, Identifiable {
    let id: String
    let account: String
    let repository: String
    let path: String
    let ref: String
    let createdAt: Date
    let exists: Bool
}
struct ManagedWorktreeList: Codable { let worktrees: [ManagedWorktree] }
private struct CompletedFeatureAction: Codable { let completed: Bool }

@MainActor
final class CodexFeaturesStore: ObservableObject {
    @Published var catalog: AccountModelCatalog?
    @Published var tasks: [StoredCodexTask] = []
    @Published var worktrees: [ManagedWorktree] = []
    @Published var nextCursor: String?
    @Published var error: String?
    @Published var busy = false
    @Published private(set) var mutating = false
    private let service = CABService()
    private var operation: Task<Void, Never>?
    private var generation = 0
    private var context = ""

    func changeContext(_ key: String) {
        guard context != key else { return }
        generation += 1
        if !mutating { operation?.cancel(); service.cancelReadOperations(); busy = false }
        context = key; catalog = nil; tasks = []; worktrees = []; nextCursor = nil; error = nil
    }
    func cancel() { guard !mutating else { return }; operation?.cancel(); service.cancelReadOperations() }
    private func perform(target: BridgeTarget, host: String, capability: String, mutation: Bool = false, action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; mutating = mutation; error = nil
        let current = generation
        operation = Task {
            defer { if mutation || current == generation { busy = false; mutating = false } }
            do {
                let supported: CABCapabilities = try await service.managementJSON(["capabilities"], target: target, host: host)
                guard supported.capabilities.contains(capability) else { throw BridgeError.commandFailed(cabLocalized("服务器 CAB 不支持此功能，请先更新服务器 CAB。")) }
                try Task.checkCancellation()
                try await action()
            } catch is CancellationError { }
            catch { if current == generation { self.error = error.localizedDescription } }
        }
    }
    func loadModels(account: String, target: BridgeTarget, host: String) {
        perform(target: target, host: host, capability: "models-v1") {
            let value: AccountModelCatalog = try await self.service.managementJSON(["models", "--account", account, "--json"], target: target, host: host)
            try Task.checkCancellation(); self.catalog = value
        }
    }
    func loadTasks(account: String, target: BridgeTarget, host: String, search: String, directory: String, archived: Bool, pinned: Bool, more: Bool = false) {
        let cursor = more ? nextCursor : nil
        perform(target: target, host: host, capability: "tasks-v1") {
            var args = ["tasks", "list", "--account", account, "--json"]
            if !search.isEmpty { args += ["--search", search] }; if !directory.isEmpty { args += ["--directory", directory] }
            if archived { args.append("--archived") }; if pinned { args.append("--pinned") }; if let cursor { args += ["--cursor", cursor] }
            let value: StoredTaskPage = try await self.service.managementJSON(args, target: target, host: host)
            try Task.checkCancellation()
            let old = more ? self.tasks : []
            var seen = Set<String>(); self.tasks = (old + value.tasks).filter { seen.insert($0.id).inserted }
            self.nextCursor = value.nextCursor
        }
    }
    func pin(_ task: StoredCodexTask, account: String, target: BridgeTarget, host: String) {
        let origin = context
        perform(target: target, host: host, capability: "tasks-v1", mutation: true) {
            let _: CompletedFeatureAction = try await self.service.managementJSON(["tasks", "pin", "--account", account, "--id", task.id, "--value", task.isPinned == true ? "false" : "true", "--json"], target: target, host: host)
            if self.context == origin, let index = self.tasks.firstIndex(where: { $0.id == task.id }) { self.tasks[index] = StoredCodexTask(id: task.id, name: task.name, cwd: task.cwd, updatedAt: task.updatedAt, isPinned: task.isPinned != true) }
        }
    }
    func resume(_ task: StoredCodexTask, account: String, target: BridgeTarget, host: String) {
        do { try service.launchCodexInTerminal(target: target, remoteHost: host, accountName: account, resume: task.id) }
        catch { self.error = error.localizedDescription }
    }
    func loadWorktrees(account: String, target: BridgeTarget, host: String) {
        perform(target: target, host: host, capability: "worktrees-v1") {
            let value: ManagedWorktreeList = try await self.service.managementJSON(["worktrees", "list", "--account", account, "--json"], target: target, host: host)
            try Task.checkCancellation(); self.worktrees = value.worktrees
        }
    }
    func createWorktree(account: String, target: BridgeTarget, host: String, directory: String, ref: String) {
        let origin = context
        perform(target: target, host: host, capability: "worktrees-v1", mutation: true) {
            let value: ManagedWorktree = try await self.service.managementJSON(["worktrees", "create", "--account", account, "--directory", directory, "--ref", ref.isEmpty ? "HEAD" : ref, "--json"], target: target, host: host)
            if self.context == origin { self.worktrees.append(value) }
        }
    }
    func removeWorktree(_ tree: ManagedWorktree, account: String, target: BridgeTarget, host: String) {
        let origin = context
        perform(target: target, host: host, capability: "worktrees-v1", mutation: true) {
            let _: CompletedFeatureAction = try await self.service.managementJSON(["worktrees", "remove", "--account", account, "--id", tree.id, "--confirm", "--confirm-codex-stopped", "--json"], target: target, host: host)
            if self.context == origin { self.worktrees.removeAll { $0.id == tree.id } }
        }
    }
    func launchWorktree(_ tree: ManagedWorktree, target: BridgeTarget, host: String) {
        do { try service.launchCodexInTerminal(target: target, remoteHost: host, accountName: tree.account, directory: tree.path) }
        catch { self.error = error.localizedDescription }
    }
}
