import Foundation

struct BridgeStatus: Codable, Equatable {
    var defaultAccount: String?
    var remoteAccount: String?
    var sharedSessions: Bool
    var rotation: RotationStatus
    var currentLogin: CurrentLoginStatus?
    var accounts: [AccountStatus]

    enum CodingKeys: String, CodingKey {
        case defaultAccount = "default_account"
        case remoteAccount = "remote_account"
        case sharedSessions = "shared_sessions"
        case rotation
        case currentLogin = "current_login"
        case accounts
    }
}

struct CurrentLoginStatus: Codable, Equatable {
    let home: String
    let login: String
    let registeredAs: String?

    enum CodingKeys: String, CodingKey {
        case home
        case login
        case registeredAs = "registered_as"
    }

    var isLoggedIn: Bool { login == "present" }
    var isRegistered: Bool { !(registeredAs ?? "").isEmpty }
}

struct RotationStatus: Codable, Equatable {
    var enabled: Bool
    var accounts: [String]?
    var nextIndex: Int?

    enum CodingKeys: String, CodingKey {
        case enabled
        case accounts
        case nextIndex = "next_index"
    }

    var orderedAccounts: [String] { accounts ?? [] }
    var nextAccount: String? {
        guard !orderedAccounts.isEmpty else { return nil }
        return orderedAccounts[(nextIndex ?? 0) % orderedAccounts.count]
    }
}

struct AccountStatus: Codable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    let home: String
    let login: String
    let `default`: Bool
    let remote: Bool

    var isLoggedIn: Bool { login == "present" }
    var isLoginUnknown: Bool { login == "unknown" }
}

struct AgentBindingReport: Codable, Equatable {
    let agents: [AgentBindingStatus]
}

struct AgentBindingStatus: Codable, Equatable, Identifiable {
    var id: String { service }
    let service: String
    let kind: String
    let active: Bool
    let account: String?
}

struct AgentBindingRequest: Identifiable {
    var id: String { service }
    let service: String
    let account: String?
    let active: Bool
}

struct AgentBulkBindingRequest: Identifiable {
    var id: String { account }
    let account: String
    let serviceCount: Int
    let activeServiceCount: Int
}

struct CodexProcessReport: Codable, Equatable {
    let processes: [CodexProcessStatus]
}

struct CodexProcessStatus: Codable, Equatable, Identifiable {
    var id: Int { pid }
    let pid: Int
    let parentPID: Int
    let elapsed: String
    let tty: String
    let state: String
    let executable: String

    enum CodingKeys: String, CodingKey {
        case pid, elapsed, tty, state, executable
        case parentPID = "parent_pid"
    }
}

struct RemoteSessionProcessRequest: Identifiable {
    var id: String { "\(enabled):\(processes.map(\.pid))" }
    let enabled: Bool
    let processes: [CodexProcessStatus]
}

struct UsageReport: Codable, Equatable {
    let fetchedAt: Date
    let accounts: [AccountUsageReport]

    enum CodingKeys: String, CodingKey {
        case fetchedAt = "fetched_at"
        case accounts
    }
}

struct AccountUsageReport: Codable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    let usage: CodexUsageSnapshot?
    let error: String?
}

struct CodexUsageSnapshot: Codable, Equatable {
    let planType: String?
    let rateLimits: UsageRateLimitSnapshot
    let rateLimitsByLimitID: [String: UsageRateLimitSnapshot]?
    let resetCredits: UsageResetCredits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimits = "rate_limits"
        case rateLimitsByLimitID = "rate_limits_by_limit_id"
        case resetCredits = "reset_credits"
    }
}

struct UsageRateLimitSnapshot: Codable, Equatable {
    let limitID: String?
    let limitName: String?
    let primary: UsageWindow?
    let secondary: UsageWindow?
    let credits: UsageCredits?
    let individualLimit: UsageSpendLimit?
    let spendControlReached: Bool?
    let planType: String?
    let rateLimitReachedType: String?

    enum CodingKeys: String, CodingKey {
        case limitID = "limit_id"
        case limitName = "limit_name"
        case primary, secondary, credits
        case individualLimit = "individual_limit"
        case spendControlReached = "spend_control_reached"
        case planType = "plan_type"
        case rateLimitReachedType = "rate_limit_reached_type"
    }
}

struct UsageWindow: Codable, Equatable {
    let usedPercent: Double
    let windowDurationMins: Int64?
    let resetsAt: Int64?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowDurationMins = "window_duration_mins"
        case resetsAt = "resets_at"
    }

    var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
    var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

struct UsageCredits: Codable, Equatable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited, balance
    }
}

struct UsageSpendLimit: Codable, Equatable {
    let limit: String
    let used: String
    let remainingPercent: Double
    let resetsAt: Int64

    enum CodingKeys: String, CodingKey {
        case limit, used
        case remainingPercent = "remaining_percent"
        case resetsAt = "resets_at"
    }

    var resetDate: Date { Date(timeIntervalSince1970: TimeInterval(resetsAt)) }
}

struct UsageResetCredits: Codable, Equatable {
    let availableCount: Int64
    let credits: [UsageResetCredit]?

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case credits
    }
}

struct UsageResetCredit: Codable, Equatable {
    let resetType: String?
    let status: String?
    let grantedAt: Int64
    let expiresAt: Int64?
    let title: String?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case resetType = "reset_type"
        case status
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
        case title, description
    }
}

struct RemoteServer: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var host: String

    init(id: UUID = UUID(), name: String, host: String) {
        self.id = id
        self.name = name
        self.host = host
    }
}

enum BridgeTarget: String, CaseIterable, Identifiable {
    case local
    case remote

    var id: String { rawValue }
    var title: String { self == .local ? "这台 Mac" : "远程服务器" }
    var icon: String { self == .local ? "laptopcomputer" : "server.rack" }
}

enum UsageRefreshInterval: Int, CaseIterable, Identifiable {
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    case manual = 0

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .fiveMinutes: return "5 分钟"
        case .fifteenMinutes: return "15 分钟"
        case .thirtyMinutes: return "30 分钟"
        case .oneHour: return "1 小时"
        case .manual: return "仅手动"
        }
    }

    var duration: TimeInterval? {
        self == .manual ? nil : TimeInterval(rawValue)
    }
}

enum BrowserChoice: String, CaseIterable, Identifiable {
    case safari
    case chrome
    case edge
    case brave
    case firefox

    var id: String { rawValue }
    var title: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave Browser"
        case .firefox: return "Firefox"
        }
    }

    var applicationNames: [String] {
        switch self {
        case .safari: return ["Safari.app"]
        case .chrome: return ["Google Chrome.app"]
        case .edge: return ["Microsoft Edge.app"]
        case .brave: return ["Brave Browser.app"]
        case .firefox: return ["Firefox.app"]
        }
    }

    var privateArgument: String? {
        switch self {
        case .safari: return nil
        case .edge: return "--inprivate"
        case .firefox: return "-private-window"
        case .chrome, .brave: return "--incognito"
        }
    }
}

struct CommandResult {
    let output: String
    let errorOutput: String
    let exitCode: Int32
}

struct CodexProcessConflict: Equatable, Identifiable {
    let pid: Int32
    let label: String

    var id: Int32 { pid }
}

enum BridgeError: LocalizedError {
    case executableMissing
    case invalidAccountName
    case commandFailed(String)
    case invalidStatus(String)
    case invalidUsage(String)

    var errorDescription: String? {
        switch self {
        case .executableMissing:
            return "找不到 cab。请先安装到 ~/.local/bin 或 /opt/homebrew/bin。"
        case .invalidAccountName:
            return "账号名称只能包含字母、数字、点、下划线和短横线，最长 64 个字符。"
        case .commandFailed(let message), .invalidStatus(let message), .invalidUsage(let message):
            return message
        }
    }
}
