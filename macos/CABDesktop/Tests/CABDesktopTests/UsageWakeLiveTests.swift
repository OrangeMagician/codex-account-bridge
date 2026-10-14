import Foundation
import Testing
@testable import CABDesktop

// Explicitly enabled only for read-only delivery verification on this machine.
// The controller is called with allowProbe=false, so even an exhausted or
// newly expired window cannot spend tokens or alter a countdown.
@MainActor
struct UsageWakeLiveTests {
    @Test func scheduledChecksReachLocalAndRemoteWithoutChangingVisibleTarget() async throws {
        guard ProcessInfo.processInfo.environment["CAB_WAKE_READ_ONLY_SMOKE"] == "1" else { return }
        let store = CABStore()
        let service = CABService()
        guard let host = ProcessInfo.processInfo.environment["CAB_WAKE_SMOKE_HOST"],
              let id = ProcessInfo.processInfo.environment["CAB_WAKE_SMOKE_SERVER_ID"].flatMap(UUID.init(uuidString:)) else {
            throw BridgeError.commandFailed("Smoke test requires an explicitly selected SSH host and server ID")
        }
        // Test executables have their own preferences domain, so explicitly
        // supply the authorized delivery host rather than relying on app prefs.
        store.remoteServers = [RemoteServer(id: id, name: host, host: host)]
        let endpoints = usageWakeEndpoints(servers: store.remoteServers)
        #expect(endpoints.contains { $0.target == .remote })
        for endpoint in endpoints {
            let status = try await service.loadStatus(target: endpoint.target, remoteHost: endpoint.host)
            let usage = try await service.loadUsage(target: endpoint.target, remoteHost: endpoint.host,
                                                    accountNames: status.accounts.filter(\.isLoggedIn).map(\.name), force: true)
            for report in usage.accounts {
                let decision = usageWakeDecision(report: report)
                guard decision != .queryFailed else {
                    throw BridgeError.commandFailed("Read-only smoke requires successful live quota queries")
                }
            }
        }
        store.usageWakeSettings.enabled = true
        let date = Date()
        let slot = UsageTimeOfDay(date: date)
        for endpoint in endpoints {
            await store.runScheduledUsageWake(slot: slot, scheduledAt: date, endpoint: endpoint, allowProbe: false)
            let slotID = usageScheduledProbeSlotIdentifier(at: date, time: slot)
            let handled = store.usageWakeState.lastScheduledSlotByAccount.contains { $0.key.hasPrefix(endpoint.key + "|") && $0.value == slotID }
            let deferred = (store.usageWakeState.scheduledWaitsByAccount ?? [:]).contains { $0.key.hasPrefix(endpoint.key + "|") && $0.value.completionSlotID == slotID }
            #expect(handled || deferred)
        }
        #expect(store.target == .local)
    }
}
