import Foundation
import Testing
@testable import CABDesktop

private let sharedFingerprint = String(repeating: "a", count: 64)
private let otherFingerprint = String(repeating: "b", count: 64)

private func sharedReport(_ name: String, fingerprint: String? = sharedFingerprint, used: Double = 10, age: TimeInterval = 0) throws -> UsageReport {
    var usage: [String: Any] = ["rate_limits": ["primary": ["used_percent": used, "window_duration_mins": 300]]]
    if let fingerprint { usage["account_fingerprint"] = fingerprint }
    let account = try JSONDecoder().decode(AccountUsageReport.self, from: JSONSerialization.data(withJSONObject: ["name": name, "usage": usage]))
    return UsageReport(fetchedAt: Date().addingTimeInterval(-age), accounts: [account])
}

private actor SharedReadCounter {
    var calls = 0
    func load(_ name: String, fingerprint: String? = sharedFingerprint, used: Double = 10, age: TimeInterval = 0) async throws -> UsageReport {
        calls += 1
        try await Task.sleep(nanoseconds: 30_000_000)
        return try sharedReport(name, fingerprint: fingerprint, used: used, age: age)
    }
}

struct SharedUsageTests {
    private let local = UsageRepository.Key(target: "local", account: "Work")
    private let remote = UsageRepository.Key(target: "ssh:fixture", account: "DifferentName")

    private func identify(_ repository: UsageRepository, counter: SharedReadCounter, remoteFingerprint: String? = sharedFingerprint) async throws {
        _ = try await repository.read(key: local, maximumAge: 0) { try await counter.load(local.account, age: 60) }
        _ = try await repository.read(key: remote, maximumAge: 0) { try await counter.load(remote.account, fingerprint: remoteFingerprint, age: 60) }
    }

    @Test func sameOfficialIdentityCoalescesAcrossHostsAndKeepsEachAliasName() async throws {
        let repository = UsageRepository(), counter = SharedReadCounter()
        try await identify(repository, counter: counter)
        #expect(await counter.calls == 2) // Discovery must verify both endpoints.
        async let first = repository.read(key: local, maximumAge: 0) { try await counter.load(local.account, used: 75) }
        async let second = repository.read(key: remote, maximumAge: 0) { try await counter.load(remote.account, used: 75) }
        let (a, b) = try await (first, second)
        #expect(await counter.calls == 3)
        #expect(a.accounts.first?.name == "Work" && b.accounts.first?.name == "DifferentName")
        #expect(a.accounts.first?.usage == b.accounts.first?.usage)
        #expect(a.fetchedAt == b.fetchedAt)
        _ = try await repository.read(key: remote, maximumAge: 30) { Issue.record("Shared quota was fetched twice"); return b }
        #expect(await counter.calls == 3)
    }

    @Test func absentDifferentAndInvalidFingerprintsNeverMergeByDisplayName() async throws {
        for fingerprint in [nil, otherFingerprint, "invalid", ""] {
            let repository = UsageRepository(), counter = SharedReadCounter()
            let sameNameRemote = UsageRepository.Key(target: "ssh:fixture", account: local.account)
            _ = try await repository.read(key: local, maximumAge: 0) { try await counter.load(local.account, age: 60) }
            _ = try await repository.read(key: sameNameRemote, maximumAge: 0) {
                try await counter.load(local.account, fingerprint: fingerprint, age: 60)
            }
            async let a = repository.read(key: local, maximumAge: 0) { try await counter.load(local.account) }
            async let b = repository.read(key: sameNameRemote, maximumAge: 0) { try await counter.load(local.account, fingerprint: fingerprint) }
            _ = try await (a, b)
            #expect(await counter.calls == 4)
        }
    }

    @Test func refreshPublishesUpdatesForBothVerifiedEndpoints() async throws {
        let repository = UsageRepository(), counter = SharedReadCounter()
        try await identify(repository, counter: counter)
        let stream = await repository.updates()
        var iterator = stream.makeAsyncIterator()
        _ = try await repository.read(key: local, maximumAge: 0) { try await counter.load(local.account, used: 60) }
        let update = try #require(await iterator.next())
        #expect(update.reports[local]?.accounts.first?.usage?.rateLimits.primary?.usedPercent == 60)
        #expect(update.reports[remote]?.accounts.first?.usage?.rateLimits.primary?.usedPercent == 60)
    }

    @Test func invalidationForcesReidentificationInsteadOfReusingPreviousLogin() async throws {
        let repository = UsageRepository(), counter = SharedReadCounter()
        try await identify(repository, counter: counter)
        await repository.invalidate()
        async let a = repository.read(key: local, maximumAge: 0) { try await counter.load(local.account, fingerprint: otherFingerprint) }
        async let b = repository.read(key: remote, maximumAge: 0) { try await counter.load(remote.account) }
        let (first, second) = try await (a, b)
        #expect(first.accounts.first?.usage?.accountFingerprint == otherFingerprint)
        #expect(second.accounts.first?.usage?.accountFingerprint == sharedFingerprint)
        #expect(await counter.calls == 4)
    }

    @Test func sourceIdentityChangeDoesNotBroadcastNewAccountToOldAliases() async throws {
        let repository = UsageRepository(), counter = SharedReadCounter()
        try await identify(repository, counter: counter)
        let stream = await repository.updates()
        var iterator = stream.makeAsyncIterator()
        _ = try await repository.read(key: local, maximumAge: 0) { try await counter.load(local.account, fingerprint: otherFingerprint) }
        let update = try #require(await iterator.next())
        #expect(update.reports[local] != nil && update.reports[remote] == nil)
        let result = try await repository.read(key: remote, maximumAge: 0) { try await counter.load(remote.account) }
        #expect(result.accounts.first?.usage?.accountFingerprint == sharedFingerprint)
    }

    @Test func isolatedServiceNamespacesNeverShareFixtureOrDifferentBackendData() async throws {
        let repository = UsageRepository(), counter = SharedReadCounter()
        let isolated = UsageRepository.Key(target: remote.target, account: remote.account, namespace: "another-service")
        _ = try await repository.read(key: local, maximumAge: 0) { try await counter.load(local.account, age: 60) }
        _ = try await repository.read(key: isolated, maximumAge: 0) { try await counter.load(remote.account, age: 60) }
        async let a = repository.read(key: local, maximumAge: 0) { try await counter.load(local.account) }
        async let b = repository.read(key: isolated, maximumAge: 0) { try await counter.load(remote.account) }
        _ = try await (a, b)
        #expect(await counter.calls == 4)
    }

    @Test func scopedInvalidationDoesNotCancelOtherServices() async throws {
        let repository = UsageRepository(), counter = SharedReadCounter()
        try await identify(repository, counter: counter)
        await repository.invalidate(namespace: "unrelated-fixture")
        _ = try await repository.read(key: local, maximumAge: 0) { try await counter.load(local.account, used: 55) }
        let value = try await repository.read(key: remote, maximumAge: 0) {
            Issue.record("An unrelated service invalidated the shared account")
            return try sharedReport(remote.account)
        }
        #expect(value.accounts.first?.usage?.rateLimits.primary?.usedPercent == 55)
    }

    @Test func invalidationRejectsAnOldInFlightIdentity() async throws {
        let repository = UsageRepository()
        let started = AsyncStream<Void>.makeStream()
        let pending = AsyncStream<Void>.makeStream()
        let read = Task {
            try await repository.read(key: local, maximumAge: 0) {
                started.continuation.yield(())
                var iterator = pending.stream.makeAsyncIterator()
                _ = await iterator.next()
                return try sharedReport(local.account)
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        await repository.invalidate()
        pending.continuation.yield(())
        await #expect(throws: CancellationError.self) { try await read.value }
        let current = try await repository.read(key: local, maximumAge: 0) {
            try sharedReport(local.account, fingerprint: otherFingerprint)
        }
        #expect(current.accounts.first?.usage?.accountFingerprint == otherFingerprint)
    }

    @MainActor @Test func sharedUpdatesPopulateBothMainWindowCachesWithoutChangingSelection() throws {
        let store = CABStore(desktopHome: { .notRunning })
        let server = RemoteServer(name: "fixture", host: "fixture")
        store.remoteServers = [server]
        store.sidebarSelection = CABStore.appSettingsSelection
        let a = try sharedReport(local.account, used: 42), b = try sharedReport(remote.account, used: 42)
        store.receiveSharedUsage(.init(reports: [local: a, remote: b]))
        #expect(store.usageByAccount[local.account]?.usage?.rateLimits.primary?.usedPercent == 42)
        #expect(store.usageCacheByKey["remote:\(server.id.uuidString)"]?.reports[remote.account]?.usage?.rateLimits.primary?.usedPercent == 42)
        #expect(store.showingAppSettings && store.target == .local)
    }
}
