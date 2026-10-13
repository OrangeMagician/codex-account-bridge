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
