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

enum PrivateBrowser: String, CaseIterable, Identifiable {
    case chrome
    case edge
    case brave
    case firefox

    var id: String { rawValue }
    var title: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave Browser"
        case .firefox: return "Firefox"
        }
    }

    var applicationNames: [String] {
        switch self {
        case .chrome: return ["Google Chrome.app"]
        case .edge: return ["Microsoft Edge.app"]
        case .brave: return ["Brave Browser.app"]
        case .firefox: return ["Firefox.app"]
        }
    }

    var privateArgument: String {
        switch self {
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

enum BridgeError: LocalizedError {
    case executableMissing
    case invalidAccountName
    case commandFailed(String)
    case invalidStatus(String)

    var errorDescription: String? {
        switch self {
        case .executableMissing:
            return "找不到 cab。请先安装到 ~/.local/bin 或 /opt/homebrew/bin。"
        case .invalidAccountName:
            return "账号名称只能包含字母、数字、点、下划线和短横线，最长 64 个字符。"
        case .commandFailed(let message), .invalidStatus(let message):
            return message
        }
    }
}
