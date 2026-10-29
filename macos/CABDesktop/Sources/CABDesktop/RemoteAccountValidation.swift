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

struct RemoteDesktopConnection: Codable, Equatable {
    let pid: Int
    let home: String
}

struct RemoteConnectionVerification: Codable {
    let account: String
    let home: String
    let freshConnectionVerified: Bool
    let otherAccountProcesses: Int
    let unknownProcesses: Int
    let processesChecked: Bool
    var desktopConnections: [RemoteDesktopConnection]? = nil
    var desktopConnectionsChecked: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case account, home
        case desktopConnections = "desktop_connections"
        case desktopConnectionsChecked = "desktop_connections_checked"
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

    var outcome: String {
        if needsReconnect { return "已有连接待重连" }
        return desktopConnections?.isEmpty == false ? "桌面连接已验证" : "新连接已验证"
    }
    var needsReconnect: Bool {
        if desktopConnectionsChecked == true, let desktopConnections {
            return desktopConnections.contains { $0.home != home }
        }
        return otherAccountProcesses > 0 || unknownProcesses > 0 || !processesChecked
    }

    func checkedDesktops(accountName: String, expectedHome: String) throws -> [RemoteDesktopConnection] {
        guard account == accountName, home == expectedHome, processesChecked,
              desktopConnectionsChecked == true, let desktopConnections else {
            throw BridgeError.commandFailed(cabLocalized("无法核验现有桌面连接，请更新服务器 CAB 后重试。"))
        }
        return desktopConnections
    }
}

// Selection and a successful fresh official handshake must precede this call.
// Only the confirmed snapshot is stopped. New instances are never stopped in a
// loop; they must reconnect on the selected account before completion is shown.
@MainActor
func reconnectRemoteDesktops(
    accountName: String,
    home: String,
    initial: RemoteConnectionVerification,
    approvedPIDs: Set<Int>,
    stop: ([Int]) async throws -> Void,
    inspect: () async throws -> RemoteConnectionVerification,
    pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 1_000_000_000) },
    pollLimit: Int = 20
) async throws -> RemoteConnectionVerification {
    try initial.validate(accountName: accountName, home: home)
    let desktops = try initial.checkedDesktops(accountName: accountName, expectedHome: home)
    let stale = desktops.filter { $0.home != home }
    guard stale.allSatisfy({ approvedPIDs.contains($0.pid) }) else {
        throw BridgeError.commandFailed(cabLocalized("检测到未确认的旧账号桌面连接，请重新发起切换并确认。"))
    }
    if stale.isEmpty { return initial }
    // Preserve already-correct connections and independently bound agent services.
    var stopError: Error?
    do { try await stop(stale.map(\.pid)) }
    catch is CancellationError { throw CancellationError() }
    catch { stopError = error }
    let previousPIDs = Set(desktops.map(\.pid))
    for attempt in 0...pollLimit {
        try Task.checkCancellation()
        let result = try await inspect()
        guard result.account == accountName, result.home == home else {
            throw BridgeError.commandFailed(cabLocalized("远程账号选择已改变，请刷新后重新切换。"))
        }
        if result.desktopConnectionsChecked == true, let current = result.desktopConnections {
            let replacementCount = current.filter { !previousPIDs.contains($0.pid) && $0.home == home }.count
            if current.allSatisfy({ $0.home == home }) && replacementCount >= stale.count && current.count >= desktops.count {
                return result
            }
        }
        if attempt < pollLimit { try await pause() }
    }
    if let stopError { throw stopError }
    throw BridgeError.commandFailed(cabLocalized("账号已保存，但现有桌面连接尚未全部使用目标账号。请检查远程重连状态后重试。"))
}
