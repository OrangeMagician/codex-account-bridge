import Foundation
import Testing
@testable import CABDesktop

struct UsageResetAttemptsTests {
    @Test func uncertainAttemptSurvivesRestartAndCannotSelectAnotherCredit() throws {
        let suite = "UsageResetAttemptsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageResetAttempts(defaults: defaults)
        let first = try store.begin(scope: "local", account: "work", creditID: "card1")
        let restarted = UsageResetAttempts(defaults: UserDefaults(suiteName: suite)!)
        #expect(try restarted.begin(scope: "local", account: "work", creditID: "card1").id == first.id)
        #expect(throws: (any Error).self) {
            try restarted.begin(scope: "local", account: "work", creditID: "card2")
        }
        #expect(try store.begin(scope: "remote", account: "work", creditID: "card1").id != first.id)
        #expect(try store.begin(scope: "local", account: "other", creditID: nil).id != first.id)
        store.complete(scope: "local", account: "work")
        #expect(try store.begin(scope: "local", account: "work", creditID: nil).id != first.id)
    }

    @Test func resetDeadlineAllowsBackendAndSSHToFinish() {
        #expect(commandTimeout(["usage", "reset"]) == 180)
        #expect(commandTimeout(["usage", "--json"]) == 120)
    }
}
