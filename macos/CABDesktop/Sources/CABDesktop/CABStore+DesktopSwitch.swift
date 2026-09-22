import CABContinuity
import Foundation

extension CABStore {
    func switchCodexDesktop(to account: AccountStatus) {
        refreshLocalDesktopAccount()
        guard !isCurrentDesktopAccount(account) else { return }
        guard target == .local, account.isLoggedIn else {
            errorMessage = "只能用这台 Mac 上已登录的账号启动 Codex 桌面客户端。"
            return
        }
        guard !isUsageRefreshing else {
            errorMessage = "正在读取额度，请等待当前官方 Codex 查询结束后再切换桌面账号。"
            return
        }
        guard !isBusy else { return }
        performDesktopSwitch(to: account, checkProcesses: true)
    }

    func closeProcessesAndContinueDesktopSwitch(_ request: DesktopSwitchProcessRequest) {
        guard !isBusy else { return }
        Task {
            isBusy = true
            errorMessage = nil
            pendingDesktopSwitchError = nil
            var stopError: Error?
            do {
                try await service.stopLocalCodexProcesses(request.processes.map(\.pid))
            } catch {
                stopError = error
            }
            do {
                let remaining = try await service.runningNonDesktopCodexProcesses(knownHomes: status.accounts.map(\.home))
                isBusy = false
                if remaining.isEmpty {
                    pendingDesktopSwitch = nil
                    pendingDesktopSwitchError = nil
                    performDesktopSwitch(to: request.account, checkProcesses: true)
                } else {
                    pendingDesktopSwitch = DesktopSwitchProcessRequest(account: request.account, processes: remaining)
                    pendingDesktopSwitchError = desktopSwitchStopFailureMessage(
                        stopError: stopError,
                        remaining: remaining
                    )
                }
            } catch {
                isBusy = false
                pendingDesktopSwitchError = "无法重新检查 Codex 进程：\(error.localizedDescription)"
            }
        }
    }

    func performDesktopSwitch(to account: AccountStatus, checkProcesses: Bool) {
        refreshLocalDesktopAccount()
        guard !isBusy, !isCurrentDesktopAccount(account) else { return }
        Task {
            isBusy = true
            errorMessage = nil
            desktopSwitchPartialResult = nil
            defer { refreshLocalDesktopAccount() }
            var switchRecordID: UUID?
            var desktopWasStopped = false
            var workspaceSync: CodexWorkspaceSyncResult?
            var continuitySync: CodexContinuitySyncResult?
            var threadCatalogSync: CodexThreadCatalogSyncResult?
            var threadIndexBackup: URL?
            var syncWarnings: [DesktopSwitchWarning] = []
            var sessionModeChanged = false
            var originalSharedSessions = status.sharedSessions
            var fallbackHome = previousDesktopHome(fallback: account.home)
            let sessionMode = preserveSessionsOnDesktopSwitch ? "保留项目与共享会话" : "保持项目与会话独立"
            output = "正在检查切换条件，准备应用“\(sessionMode)”设置…\n"
            do {
                let liveStatus = try await service.loadStatus(target: .local, remoteHost: "")
                status = liveStatus
                refreshLocalDesktopAccount()
                if isCurrentDesktopAccount(account) {
                    isBusy = false
                    return
                }
                originalSharedSessions = liveStatus.sharedSessions
                fallbackHome = previousDesktopHome(fallback: account.home)
                if checkProcesses && (preserveSessionsOnDesktopSwitch || preserveSessionsOnDesktopSwitch != liveStatus.sharedSessions) {
                    let conflicts = try await service.runningNonDesktopCodexProcesses(knownHomes: liveStatus.accounts.map(\.home))
                    if !conflicts.isEmpty {
                        pendingDesktopSwitchError = nil
                        pendingDesktopSwitch = DesktopSwitchProcessRequest(account: account, processes: conflicts)
                        isBusy = false
                        return
                    }
                }
                switchRecordID = tools.beginRecord(host: "", source: status.accounts.first(where: { $0.home == fallbackHome })?.name ?? fallbackHome, destination: account.name)
                if let id = switchRecordID { tools.record(id, stage: "预检通过") }
                appendOutput("预检通过，正在关闭 Codex 桌面客户端并切换账号…\n")
                try await service.stopCodexDesktop()
                desktopWasStopped = true
                if let id = switchRecordID { tools.record(id, stage: "桌面客户端已退出") }
                sessionModeChanged = try await applyDesktopSessionPreferenceIfNeeded(currentSharedSessions: originalSharedSessions)
                if preserveSessionsOnDesktopSwitch {
                    do {
                        workspaceSync = try service.synchronizeCodexWorkspaceState(
                            sourceHome: fallbackHome,
                            targetHome: account.home,
                            knownHomes: status.accounts.map(\.home)
                        )
                        if let workspaceSync {
                            let backupMessage = workspaceSync.backupURL.map { "，原状态已备份为 \($0.lastPathComponent)" } ?? ""
                            appendOutput("已同步 \(workspaceSync.projectCount) 个桌面项目、会话归属及未发送草稿\(backupMessage)。\n")
                        }
                    } catch {
                        syncWarnings.append(desktopSwitchWarning(
                            stage: "桌面项目与草稿",
                            sourcePath: fallbackHome,
                            targetPath: account.home,
                            error: error
                        ))
                    }
                    do {
                        continuitySync = try service.synchronizeCodexContinuityState(
                            sourceHome: fallbackHome,
                            targetHome: account.home,
                            knownHomes: status.accounts.map(\.home)
                        )
                        if let continuitySync {
                            appendOutput("已同步完整消息投影、目标、记忆及 \(continuitySync.fileCount) 个工作区文件（\(continuitySync.databaseCount) 个本地索引已安全合并）。\n")
                        }
                    } catch {
                        syncWarnings.append(desktopSwitchWarning(
                            stage: "消息、记忆与工作区文件",
                            sourcePath: fallbackHome,
                            targetPath: account.home,
                            error: error
                        ))
                    }
                    do {
                        threadCatalogSync = try service.synchronizeCodexThreadCatalogState(
                            sourceHome: fallbackHome,
                            targetHome: account.home,
                            knownHomes: status.accounts.map(\.home)
                        )
                        if let threadCatalogSync {
                            appendOutput("已合并 \(threadCatalogSync.rowCount) 条桌面会话目录记录，原目录已备份为 \(threadCatalogSync.backupURL.lastPathComponent)。\n")
                        }
                    } catch {
                        syncWarnings.append(desktopSwitchWarning(
                            stage: "桌面会话目录",
                            sourcePath: fallbackHome,
                            targetPath: account.home,
                            error: error
                        ))
                    }
                }
                if preserveSessionsOnDesktopSwitch || sessionModeChanged {
                    do {
                        if let backup = try await service.prepareCodexThreadIndexRebuild(codexHome: account.home) {
                            threadIndexBackup = backup
                            appendOutput("已备份线程索引到 \(backup.lastPathComponent)，官方 Codex 将从会话文件重建可见对话列表。\n")
                        }
                    } catch {
                        syncWarnings.append(desktopSwitchWarning(
                            stage: "会话列表重建准备",
                            sourcePath: account.home,
                            targetPath: account.home,
                            error: error
                        ))
                    }
                }
                if let id = switchRecordID {
                    let paths = [workspaceSync?.backupURL?.path, threadCatalogSync?.backupURL.path, threadIndexBackup?.path].compactMap { $0 } + (continuitySync?.backups.compactMap { $0.backupURL?.path } ?? [])
                    tools.record(id, stage: "同步与备份阶段结束", backups: paths)
                    for warning in syncWarnings { tools.record(id, stage: cabLocalized("未同步") + " · " + cabLocalized(warning.stage)) }
                }
                try await service.startCodexDesktop(codexHome: account.home)
                desktopWasStopped = false
                lastDesktopAccount = account.name
                defaults.set(account.name, forKey: lastDesktopAccountKey)
                scheduleUsageRefreshAfterDesktopSwitch(accountName: account.name)
                appendOutput("已使用账号 \(account.name) 启动 Codex 桌面客户端；\(preserveSessionsOnDesktopSwitch ? "项目和会话历史已保留" : "项目和会话保持独立")。\n")
                if let id = switchRecordID { tools.record(id, stage: "目标账号已启动", outcome: syncWarnings.isEmpty ? "已完成" : "部分完成") }
                if !syncWarnings.isEmpty {
                    appendOutput("账号切换已完成，但有 \(syncWarnings.count) 项内容未同步；详情已显示在提示中。\n")
                    desktopSwitchPartialResult = DesktopSwitchPartialResult(
                        accountName: account.name,
                        warnings: syncWarnings
                    )
                }
            } catch {
                var message = error.localizedDescription
                if let id = switchRecordID { tools.record(id, stage: "切换失败，尝试恢复原状态", outcome: "结果待确认") }
                if desktopWasStopped {
                    if let threadIndexBackup {
                        do {
                            try service.restoreCodexThreadIndex(backupURL: threadIndexBackup, codexHome: account.home)
                            appendOutput("切换未完成，已恢复目标账号原有的线程索引。\n")
                        } catch {
                            message += "\n同时无法自动恢复目标账号的线程索引：\(error.localizedDescription)"
                        }
                    }
                    if let threadCatalogSync {
                        do {
                            try service.restoreCodexThreadCatalogState(threadCatalogSync)
                            appendOutput("切换未完成，已恢复目标账号原有的桌面会话目录。\n")
                        } catch {
                            message += "\n同时无法自动恢复目标账号的桌面会话目录：\(error.localizedDescription)"
                        }
                    }
                    if let continuitySync {
                        do {
                            try service.restoreCodexContinuityState(continuitySync)
                            appendOutput("切换未完成，已恢复目标账号原有的消息、记忆、目标和工作区文件。\n")
                        } catch {
                            message += "\n同时无法自动恢复目标账号的完整工作区状态：\(error.localizedDescription)"
                        }
                    }
                    if let workspaceSync {
                        do {
                            try service.restoreCodexWorkspaceState(workspaceSync)
                            appendOutput("切换未完成，已恢复目标账号原有的项目状态。\n")
                        } catch {
                            message += "\n同时无法自动恢复目标账号的项目状态：\(error.localizedDescription)"
                        }
                    }
                    if sessionModeChanged {
                        let arguments = originalSharedSessions
                            ? ["sessions", "enable", "--acknowledge-cross-account-context", "--confirm-codex-stopped"]
                            : ["sessions", "disable", "--confirm-codex-stopped"]
                        do {
                            let result = try await service.execute(arguments, target: .local, remoteHost: "")
                            if result.exitCode != 0 {
                                let loaded = try? await service.loadStatus(target: .local, remoteHost: "")
                                guard loaded?.sharedSessions == originalSharedSessions else {
                                    throw BridgeError.commandFailed(result.errorOutput.isEmpty ? result.output : result.errorOutput)
                                }
                            }
                            if let loaded = try? await service.loadStatus(target: .local, remoteHost: "") { status = loaded }
                            appendOutput("切换未完成，已恢复原有的项目与会话保留设置。\n")
                        } catch {
                            message += "\n同时无法自动恢复会话保留设置：\(error.localizedDescription)"
                        }
                    }
                    do {
                        try await service.startCodexDesktop(codexHome: fallbackHome)
                        appendOutput("切换未完成，已重新启动原 Codex 桌面账号。\n")
                        if let id = switchRecordID { tools.record(id, stage: "原账号已重新启动", outcome: "未完成") }
                    } catch {
                        message += "\n同时无法自动恢复 Codex 桌面客户端：\(error.localizedDescription)"
                    }
                }
                errorMessage = message
            }
            isBusy = false
        }
    }

}
