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
