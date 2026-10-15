import Foundation
import Testing
@testable import CABDesktop

struct RemoteAccountValidationTests {
    private func status(login: String = "present", routed: Bool? = true, selected: String = "work") -> BridgeStatus {
        BridgeStatus(remoteAccount: selected, sharedSessions: false, rotation: RotationStatus(enabled: false), currentLogin: nil, remoteRoutingReady: routed, accounts: [
            AccountStatus(name: "work", home: "/isolated", login: login, default: false, remote: true)
        ])
    }

    @Test func switchRequiresVerifiedRoutingAndLogin() throws {
        try validateRemoteAccountSelection(status(), accountName: "work")
        for invalid in [status(login: "missing"), status(login: "unknown"), status(routed: false), status(routed: nil), status(selected: "other")] {
            #expect(throws: BridgeError.self) { try validateRemoteAccountSelection(invalid, accountName: "work") }
        }
    }

    @Test func decodesRoutingHealthFromServerStatus() throws {
        let decoded = try JSONDecoder().decode(BridgeStatus.self, from: Data("""
        {"remote_account":"work","shared_sessions":false,"rotation":{"enabled":false},"remote_routing_ready":false,"accounts":[]}
        """.utf8))
        #expect(decoded.remoteRoutingReady == false)
    }
}

struct RemoteConnectionVerificationTests {
    private func result(account: String = "work", home: String = "/isolated", verified: Bool = true,
                        old: Int = 0, unknown: Int = 0, checked: Bool = true) -> RemoteConnectionVerification {
        RemoteConnectionVerification(account: account, home: home, freshConnectionVerified: verified,
                                     otherAccountProcesses: old, unknownProcesses: unknown, processesChecked: checked)
    }

    @Test func savedSelectionAloneCannotCountAsFreshConnectionSuccess() throws {
        try result().validate(accountName: "work", home: "/isolated")
        for invalid in [result(account: "other"), result(home: "/old"), result(verified: false)] {
            #expect(throws: BridgeError.self) { try invalid.validate(accountName: "work", home: "/isolated") }
        }
    }

    @Test func existingOrUnknownConnectionsNeverReportSwitchCompleted() {
        #expect(result().outcome == "新连接已验证")
        for incomplete in [result(old: 1), result(unknown: 1), result(checked: false)] {
            #expect(incomplete.outcome == "已有连接待重连")
        }
    }
}

@MainActor
struct RemoteConnectionLiveTests {
    @Test func verifiesInstalledServerEntryThroughDesktopService() async throws {
        guard ProcessInfo.processInfo.environment["CAB_REMOTE_VERIFY_SMOKE"] == "1" else { return }
        let service = CABService()
        let status = try await service.loadStatus(target: .remote, remoteHost: "oraclearm")
        try validateRemoteAccountSelection(status, accountName: "CKF")
        let selected = try #require(status.accounts.first { $0.name == "CKF" })
        let result = try await service.verifyRemoteConnection(accountName: "CKF", remoteHost: "oraclearm")
        try result.validate(accountName: "CKF", home: selected.home)
        #expect(result.freshConnectionVerified)
        #expect(result.outcome != "已完成")
    }
}
