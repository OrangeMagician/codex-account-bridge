import Foundation

/// Retain uncertain redemptions across retries and app restarts. Never retry automatically.
struct UsageResetAttempts {
    struct Attempt: Codable {
        let id: UUID
        let creditID: String?
    }

    let defaults: UserDefaults

    private func key(scope: String, account: String) -> String {
        let components = [scope, account].map { Data($0.utf8).base64EncodedString() }
        return "usageResetAttempt.v1." + components.joined(separator: ".")
    }

    func begin(scope: String, account: String, creditID: String?) throws -> Attempt {
        let storageKey = key(scope: scope, account: account)
        if let data = defaults.data(forKey: storageKey) {
            // Fail closed if a saved attempt cannot be decoded.
            let attempt = try JSONDecoder().decode(Attempt.self, from: data)
            guard attempt.creditID == creditID else {
                throw BridgeError.commandFailed(cabLocalized("上次重置结果尚未确认，请重试原来的重置卡，暂勿选择其他卡。"))
            }
            return attempt
        }
        let attempt = Attempt(id: UUID(), creditID: creditID)
        defaults.set(try JSONEncoder().encode(attempt), forKey: storageKey)
        return attempt
    }

    func complete(scope: String, account: String) {
        defaults.removeObject(forKey: key(scope: scope, account: account))
    }
}
