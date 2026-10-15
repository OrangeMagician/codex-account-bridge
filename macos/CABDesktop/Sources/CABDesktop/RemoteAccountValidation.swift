import Foundation

func validateRemoteAccountSelection(_ status: BridgeStatus, accountName: String) throws {
    guard status.remoteAccount == accountName,
          status.accounts.first(where: { $0.name == accountName })?.isLoggedIn == true else {
        throw BridgeError.commandFailed("远程账号未登录或切换结果未确认，请刷新状态并重新登录。")
    }
    guard status.remoteRoutingReady == true else {
        throw BridgeError.commandFailed("服务器 Codex 入口未经过 CAB，账号选择已保存但切换尚未生效。请修复远程入口后重新连接。")
    }
}

struct RemoteConnectionVerification: Codable {
    let account: String
    let home: String
    let freshConnectionVerified: Bool
    let otherAccountProcesses: Int
    let unknownProcesses: Int
    let processesChecked: Bool

    enum CodingKeys: String, CodingKey {
        case account, home
        case freshConnectionVerified = "fresh_connection_verified"
        case otherAccountProcesses = "other_account_processes"
        case unknownProcesses = "unknown_processes"
        case processesChecked = "processes_checked"
    }

    func validate(accountName: String, home expectedHome: String) throws {
        guard account == accountName, home == expectedHome, freshConnectionVerified else {
            throw BridgeError.commandFailed("新建的远程连接未确认使用目标账号，不能确认切换成功。")
        }
    }

    var outcome: String { needsReconnect ? "已有连接待重连" : "新连接已验证" }
    var needsReconnect: Bool { otherAccountProcesses > 0 || unknownProcesses > 0 || !processesChecked }
}
