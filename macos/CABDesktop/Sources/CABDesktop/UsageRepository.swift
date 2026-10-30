import Foundation

/// Coalesces reads for verified backend-account + principal fingerprints. Names
/// remain endpoint-local, and missing identity never establishes a shared cache.
actor UsageRepository {
    static let shared = UsageRepository()
    struct Key: Hashable {
        let target: String
        let account: String
        var namespace = "official"
    }
    struct Update { let reports: [Key: UsageReport] }
    private struct Identity: Hashable { let namespace: String; let fingerprint: String }
    private struct Binding { let identity: Identity; let verifiedAt: Date }
    private struct Shared { let source: Key; let report: UsageReport }
    private struct Flight { let id: UUID; let task: Task<UsageReport, Error> }
    private var cache: [Key: UsageReport] = [:]
    private var tasks: [Key: Flight] = [:]
    private var bindings: [Key: Binding] = [:]
    private var sharedCache: [Identity: Shared] = [:]
    private var sharedTasks: [Identity: Flight] = [:]
    private var observers: [UUID: AsyncStream<Update>.Continuation] = [:]
    private var epochs: [String: Int] = [:]
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let identityLifetime: TimeInterval = 3600
    private let crossEndpointRefreshWindow: TimeInterval = 30

    func updates() -> AsyncStream<Update> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            observers[id] = continuation
            continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    func read(key: Key, maximumAge: TimeInterval, load: @escaping () async throws -> UsageReport) async throws -> UsageReport {
        if let flight = tasks[key] { return try await flight.task.value }
        if let value = cache[key], isFresh(value, maximumAge: maximumAge) { return value }
        let capturedEpoch = epochs[key.namespace, default: 0]
        if let binding = validBinding(for: key) {
            if let flight = sharedTasks[binding.identity] {
                let result = try await flight.task.value
                guard epochs[key.namespace, default: 0] == capturedEpoch else { throw CancellationError() }
                // A new login on the source must not feed its quota to old aliases.
                if fingerprint(in: result) == binding.identity.fingerprint {
                    let renamed = renamed(result, account: key.account)
                    cache[key] = renamed
                    return renamed
                }
                bindings[key] = nil
            } else if let shared = sharedCache[binding.identity], shared.source != key {
                let age = maximumAge > 0 ? maximumAge : crossEndpointRefreshWindow
                if isFresh(shared.report, maximumAge: age) {
                    let value = renamed(shared.report, account: key.account)
                    cache[key] = value
                    return value
                }
            }
        }
        let identity = validBinding(for: key)?.identity
        let id = UUID()
        let task = Task {
            await self.acquire()
            defer { self.release() }
            try Task.checkCancellation()
            let value = try await load()
            try Task.checkCancellation()
            guard self.epochs[key.namespace, default: 0] == capturedEpoch else { throw CancellationError() }
            return self.accept(value, from: key)
        }
        let flight = Flight(id: id, task: task)
        tasks[key] = flight
        if let identity { sharedTasks[identity] = flight }
        do {
            let value = try await task.value
            if tasks[key]?.id == id { tasks[key] = nil }
            if let identity, sharedTasks[identity]?.id == id { sharedTasks[identity] = nil }
            return value
        } catch {
            if tasks[key]?.id == id { tasks[key] = nil }
            if let identity, sharedTasks[identity]?.id == id { sharedTasks[identity] = nil }
            // Failed or uncertain reads cannot establish or renew an identity.
            if epochs[key.namespace, default: 0] == capturedEpoch { bindings[key] = nil; cache[key] = nil }
            throw error
        }
    }

    private func validBinding(for key: Key) -> Binding? {
        guard let value = bindings[key], Date().timeIntervalSince(value.verifiedAt) < identityLifetime else { return nil }
        return value
    }

    private func isFresh(_ report: UsageReport, maximumAge: TimeInterval) -> Bool {
        let age = Date().timeIntervalSince(report.fetchedAt)
        return maximumAge > 0 && age >= 0 && age < maximumAge
    }

    private func fingerprint(in value: UsageReport) -> String? {
        guard value.accounts.count == 1, let report = value.accounts.first, report.error == nil,
              let fingerprint = report.usage?.accountFingerprint, fingerprint.count == 64,
              fingerprint.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return fingerprint
    }

    private func renamed(_ report: UsageReport, account: String) -> UsageReport {
        UsageReport(fetchedAt: report.fetchedAt, accounts: report.accounts.map {
            AccountUsageReport(name: account, usage: $0.usage, error: $0.error, fetchedAt: $0.fetchedAt ?? report.fetchedAt)
        })
    }

    private func accept(_ incoming: UsageReport, from key: Key) -> UsageReport {
        guard incoming.accounts.count == 1, incoming.accounts.first?.name == key.account,
              incoming.accounts.allSatisfy({ $0.usage != nil && $0.error == nil }) else {
            bindings[key] = nil
            cache[key] = nil
            return incoming
        }
        guard let fingerprint = fingerprint(in: incoming) else {
            bindings[key] = nil
            cache[key] = incoming
            publish([key: incoming])
            return incoming
        }
        let identity = Identity(namespace: key.namespace, fingerprint: fingerprint)
        bindings[key] = Binding(identity: identity, verifiedAt: Date())
        let selected: Shared
        if let existing = sharedCache[identity], existing.report.fetchedAt > incoming.fetchedAt { selected = existing }
        else { selected = Shared(source: key, report: incoming); sharedCache[identity] = selected }
        var updates: [Key: UsageReport] = [:]
        for (alias, binding) in bindings where binding.identity == identity && validBinding(for: alias) != nil {
            let value = renamed(selected.report, account: alias.account)
            cache[alias] = value
            updates[alias] = value
        }
        publish(updates)
        return renamed(selected.report, account: key.account)
    }

    private func publish(_ reports: [Key: UsageReport]) {
        for observer in observers.values { observer.yield(Update(reports: reports)) }
    }

    /// Used when login/account registration or quota-changing operations change.
    /// In-flight responses from the previous epoch cannot re-establish old links.
    func invalidate(namespace: String? = nil) {
        let affected = namespace.map { Set([$0]) } ?? Set(cache.keys.map(\.namespace))
            .union(tasks.keys.map(\.namespace)).union(bindings.keys.map(\.namespace))
            .union(sharedCache.keys.map(\.namespace)).union(epochs.keys)
        for namespace in affected { epochs[namespace, default: 0] += 1 }
        for (key, flight) in tasks where affected.contains(key.namespace) { flight.task.cancel() }
        cache = cache.filter { !affected.contains($0.key.namespace) }
        bindings = bindings.filter { !affected.contains($0.key.namespace) }
        sharedCache = sharedCache.filter { !affected.contains($0.key.namespace) }
        sharedTasks = sharedTasks.filter { !affected.contains($0.key.namespace) }
        tasks = tasks.filter { !affected.contains($0.key.namespace) }
    }
    func cancel() { for flight in tasks.values { flight.task.cancel() } }

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
