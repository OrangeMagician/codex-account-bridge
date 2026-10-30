import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class PublicResetMonitor: ObservableObject {
    static let shared = PublicResetMonitor()
    @Published private(set) var enabled: Bool
    @Published private(set) var updating = false
    @Published private(set) var checking = false
    @Published private(set) var snapshot: PublicResetSnapshot?
    @Published private(set) var checkedAt: Date?
    @Published private(set) var error: String?
    @Published private(set) var nextCheckAt: Date?
    private let defaults: UserDefaults
    private let fetch: () async throws -> PublicResetSnapshot
    private let authorize: () async throws -> Bool
    private let notify: (PublicResetRecord) async throws -> Void
    private var checkpoint: PublicResetCheckpoint
    private var task: Task<Void, Never>?
    private var generation = 0
    private var failures = 0
    private static let enabledKey = "publicResetEnabled.v1"
    private static let checkpointKey = "publicResetCheckpoint.v1"

    init(defaults: UserDefaults = .standard,
         fetch: @escaping () async throws -> PublicResetSnapshot = { try await PublicResetFeedClient().fetch() },
         authorize: @escaping () async throws -> Bool = {
             try await UsageResetNotificationService.shared.requestAuthorization()
         },
         notify: @escaping (PublicResetRecord) async throws -> Void = { record in
             try await UsageResetNotificationService.shared.sendPublicResetNotification(record)
         }) {
        self.defaults = defaults
        self.fetch = fetch
        self.authorize = authorize
        self.notify = notify
        enabled = defaults.bool(forKey: Self.enabledKey)
        checkpoint = defaults.data(forKey: Self.checkpointKey).flatMap {
            try? JSONDecoder().decode(PublicResetCheckpoint.self, from: $0)
        } ?? PublicResetCheckpoint()
    }

    func setEnabled(_ value: Bool) {
        guard !updating, value != enabled else { return }
        if !value {
            enabled = false
            defaults.set(false, forKey: Self.enabledKey)
            generation += 1
            task?.cancel()
            task = nil
            nextCheckAt = nil
            error = nil
            return
        }
        updating = true
        Task {
            defer { updating = false }
            do {
                guard try await authorize() else { throw UsageResetNotificationError.permissionDenied }
                enabled = true
                defaults.set(true, forKey: Self.enabledKey)
                error = nil
                startMonitoring()
            } catch { self.error = error.localizedDescription }
        }
    }

    func startMonitoring() {
        guard enabled, task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.enabled else { return }
                await self.check()
                guard !Task.isCancelled, self.enabled else { return }
                let delay = max(1, (self.nextCheckAt ?? Date().addingTimeInterval(300)).timeIntervalSinceNow)
                // Avoid UInt64 overflow on a malformed Retry-After; long waits are rechecked.
                do { try await Task.sleep(nanoseconds: UInt64(min(delay, 86400) * 1_000_000_000)) }
                catch { return }
            }
        }
    }

    func checkForDisplay(now: Date = Date()) async {
        await check(now: now, forDisplay: true)
    }

    func check(now: Date = Date(), forDisplay: Bool = false) async {
        guard (enabled || forDisplay), !checking, nextCheckAt == nil || now >= nextCheckAt! else { return }
        checking = true
        let capturedGeneration = generation
        defer { checking = false }
        // All entry points share this deadline, including reopening Settings.
        nextCheckAt = now.addingTimeInterval(300)
        do {
            let fetched = try await fetch()
            guard (enabled || forDisplay), capturedGeneration == generation, !Task.isCancelled else { return }
            snapshot = fetched
            checkedAt = now
            guard fetched.isFresh(at: now) else { throw PublicResetFeedError.stale }
            if !enabled {
                failures = 0
                error = nil
                return // Viewing the overview never authorizes notifications.
            }
            if checkpoint.initializedAt == nil {
                // Establish a baseline without replaying the source's historical announcements.
                checkpoint.markSeen(fetched.records, now: now)
                persistCheckpoint()
            } else {
                for record in checkpoint.alerts(in: fetched, now: now) {
                    guard enabled, capturedGeneration == generation, !Task.isCancelled else { return }
                    try await notify(record)
                    checkpoint.markSeen([record], now: now)
                    persistCheckpoint()
                    if !enabled || capturedGeneration != generation {
                        let center = UNUserNotificationCenter.current()
                        center.removePendingNotificationRequests(withIdentifiers: ["cab.public-reset." + record.id])
                        center.removeDeliveredNotifications(withIdentifiers: ["cab.public-reset." + record.id])
                        return
                    }
                }
            }
            failures = 0
            error = nil
        } catch {
            guard (enabled || forDisplay), capturedGeneration == generation, !Task.isCancelled else { return }
            failures = min(failures + 1, 4)
            var delay = min(3600, 300 * pow(2, Double(failures - 1)))
            if case let PublicResetFeedError.rateLimited(retry) = error { delay = max(delay, retry) }
            nextCheckAt = now.addingTimeInterval(delay)
            self.error = (error as? PublicResetFeedError)?.localizedDescription
                ?? cabLocalized("暂时无法更新重置信号，保留上次状态。")
        }
    }

    private func persistCheckpoint() {
        if let data = try? JSONEncoder().encode(checkpoint) { defaults.set(data, forKey: Self.checkpointKey) }
    }
}
