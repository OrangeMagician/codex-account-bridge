import Foundation

/// Shared by the window and menu bar. Requests are coalesced by target and
/// account; a slow account cannot serialize the rest of the refresh.
actor UsageRepository {
    static let shared = UsageRepository()
    struct Key: Hashable { let target: String; let account: String }
    private var cache: [Key: UsageReport] = [:]
    private var tasks: [Key: Task<UsageReport, Error>] = [:]
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func read(key: Key, maximumAge: TimeInterval, load: @escaping () async throws -> UsageReport) async throws -> UsageReport {
        if let task = tasks[key] { return try await task.value }
        if let value = cache[key], Date().timeIntervalSince(value.fetchedAt) < maximumAge { return value }
        let task = Task {
            await self.acquire()
            defer { self.release() }
            return try await load()
        }
        tasks[key] = task
        do {
            let value = try await task.value
            tasks[key] = nil
            if value.accounts.allSatisfy({ $0.usage != nil && $0.error == nil }) { cache[key] = value }
            return value
        } catch { tasks[key] = nil; throw error }
    }

    func invalidate() { cache.removeAll() }
    func cancel() { for task in tasks.values { task.cancel() } }

    private func acquire() async {
        if active < 4 { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
    }
}

func preservingUsage(_ incoming: AccountUsageReport, previous: AccountUsageReport?, fetchedAt: Date) -> AccountUsageReport {
    if incoming.usage != nil {
        return AccountUsageReport(name: incoming.name, usage: incoming.usage, error: incoming.error, fetchedAt: fetchedAt)
    }
    return AccountUsageReport(name: incoming.name, usage: previous?.usage,
                              error: incoming.error, fetchedAt: previous?.fetchedAt)
}
