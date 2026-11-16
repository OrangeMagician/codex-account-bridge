import AppKit
import SwiftUI
import Testing
@testable import CABDesktop

@MainActor
struct UsageResetHistoryTests {
    private func fixture(_ body: (UsageResetHistory, UserDefaults) async throws -> Void) async throws {
        let suite = "UsageResetHistoryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(UsageResetHistory(defaults: defaults), defaults)
    }

    @Test func manualAndAutomaticUsesSurviveRestart() async throws {
        try await fixture { history, defaults in
            for trigger in UsageResetTrigger.allCases {
                _ = try await history.perform(id: UUID(), account: "fixture", target: .remote, host: "test-server",
                                              trigger: trigger) {
                    #expect(UsageResetHistory(defaults: defaults).entries.first?.outcome == nil)
                    return UsageResetResult(account: "fixture", outcome: .reset)
                }
            }
            let restored = UsageResetHistory(defaults: defaults)
            #expect(restored.entries.count == 2)
            #expect(Set(restored.entries.map(\.trigger.rawValue)) == ["manual", "automatic"])
            #expect(restored.entries.allSatisfy { $0.outcome == .reset && $0.completedAt != nil && $0.host == "test-server" })
        }
    }

    @Test func uncertainRetryUpdatesOneRecordAndKeepsOriginalTrigger() async throws {
        try await fixture { history, defaults in
            let id = UUID()
            do {
                _ = try await history.perform(id: id, account: "fixture", target: .local, host: "ignored", trigger: .automatic) {
                    throw URLError(.networkConnectionLost)
                }
                Issue.record("Expected simulated network error")
            } catch {}
            let restored = UsageResetHistory(defaults: defaults)
            #expect(restored.entries.first?.uncertain == true)
            #expect(restored.entries.first?.outcome == nil)
            _ = try await restored.perform(id: id, account: "fixture", target: .local, host: "", trigger: .manual) {
                UsageResetResult(account: "fixture", outcome: .alreadyRedeemed)
            }
            #expect(restored.entries.count == 1)
            #expect(restored.entries.first?.trigger == .automatic)
            #expect(restored.entries.first?.outcome == .alreadyRedeemed)
            #expect(restored.entries.first?.host == "")
            #expect(restored.entries.first?.uncertain == false)
        }
    }

    @Test(arguments: [UsageResetOutcome.nothingToReset, .noCredit, .alreadyRedeemed])
    func nonUsageOutcomesAreNotReportedAsSuccess(outcome: UsageResetOutcome) async throws {
        try await fixture { history, _ in
            _ = try await history.perform(id: UUID(), account: "fixture", target: .local, host: "", trigger: .manual) {
                UsageResetResult(account: "fixture", outcome: outcome)
            }
            #expect(history.entries.first?.outcome == outcome)
            #expect(history.entries.first?.outcome != .reset)
        }
    }

    @Test func mismatchedAccountCannotBecomeSuccessfulHistory() async throws {
        try await fixture { history, _ in
            do {
                _ = try await history.perform(id: UUID(), account: "fixture", target: .local, host: "", trigger: .manual) {
                    UsageResetResult(account: "other", outcome: .reset)
                }
                Issue.record("Expected account validation failure")
            } catch {}
            #expect(history.entries.first?.uncertain == true)
            #expect(history.entries.first?.outcome == nil)
        }
    }

    @Test func retriesPreserveConfirmedSuccess() async throws {
        try await fixture { history, _ in
            let id = UUID()
            for outcome in [UsageResetOutcome.reset, .alreadyRedeemed] {
                _ = try await history.perform(id: id, account: "fixture", target: .local, host: "", trigger: .manual) {
                    UsageResetResult(account: "fixture", outcome: outcome)
                }
            }
            #expect(history.entries.count == 1)
            #expect(history.entries.first?.outcome == .reset)
        }
    }

    @Test func serviceRecordsBothTriggersUsingOnlyFakeExecutable() async throws {
        try await fixture { history, _ in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executable = directory.appendingPathComponent("cab-fixture")
            try "#!/usr/bin/python3\nprint('{\"account\":\"fixture\",\"outcome\":\"reset\"}')\n"
                .write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let service = CABService(executable: executable, resetHistory: history)
            _ = try await service.resetUsage(target: .local, remoteHost: "", accountName: "fixture",
                                            creditID: "mock-card-1", idempotencyKey: UUID())
            _ = try await service.resetUsage(target: .local, remoteHost: "", accountName: "fixture",
                                            creditID: "mock-card-2", idempotencyKey: UUID(), trigger: .automatic)
            #expect(history.entries.count == 2)
            #expect(history.entries.map(\.trigger) == [.automatic, .manual])
            #expect(history.entries.allSatisfy { $0.outcome == .reset })
        }
    }

    @Test func rendersHistoryUsingOnlyFixtureData() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CAB_RESET_HISTORY_RENDER_DIR"] else { return }
        try await fixture { history, _ in
            for (index, outcome) in [UsageResetOutcome.reset, .noCredit, .nothingToReset, .alreadyRedeemed].enumerated() {
                _ = try await history.perform(id: UUID(), account: index == 0 ? "CKF" : "Fixture account", target: index == 0 ? .local : .remote,
                                              host: "oraclearm", trigger: index % 2 == 0 ? .automatic : .manual) {
                    UsageResetResult(account: index == 0 ? "CKF" : "Fixture account", outcome: outcome)
                }
            }
            _ = NSApplication.shared
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for width in [600, 900] {
                for dark in [false, true] {
                    let view = UsageResetHistoryView(history: history).padding(20)
                        .frame(width: CGFloat(width), height: 600, alignment: .topLeading)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, dark ? .dark : .light).cabPreservingActiveColors()
                    let host = NSHostingView(rootView: view)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    host.frame = window.contentLayoutRect
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("history-\(width)-dark-\(dark).png"))
                }
            }
        }
    }
}
