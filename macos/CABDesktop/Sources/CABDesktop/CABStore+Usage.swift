import Foundation

extension CABStore {
    func reloadUsage(force: Bool, accountNames: [String]? = nil) async {
        let key = currentUsageCacheKey
        var requestedAccountNames: [String]?
        if let accountNames {
            let loggedInNames = Set(status.accounts.filter(\.isLoggedIn).map(\.name))
            requestedAccountNames = Array(Set(accountNames).intersection(loggedInNames)).sorted()
            if requestedAccountNames?.isEmpty == true { return }
            if let cached = usageCacheByKey[key] { applyUsageCache(cached) }
        } else if let cached = usageCacheByKey[key] {
            applyUsageCache(cached)
            if !force {
                requestedAccountNames = usageAccountNamesToRefresh(
                    accountNames: status.accounts.filter(\.isLoggedIn).map(\.name),
                    reports: cached.reports,
                    checkedAtByAccount: cached.checkedAtByAccount,
                    interval: usageRefreshInterval
                )
                if requestedAccountNames?.isEmpty == true { return }
            }
        } else if !force && usageRefreshInterval == .manual {
            applyUsageCache(nil)
            return
        }
        guard !usageRefreshingKeys.contains(key) else { return }
        usageRefreshingKeys.insert(key)
        isUsageRefreshing = true
        defer {
            usageRefreshingKeys.remove(key)
            isUsageRefreshing = usageRefreshingKeys.contains(currentUsageCacheKey)
        }
        let capturedTarget = target
        let capturedHost = remoteHost
        let capturedAccountNames = Set(status.accounts.map(\.name))
        let attemptedAccountNames = requestedAccountNames ?? Array(capturedAccountNames)
        let previousReports = usageCacheByKey[key]?.reports ?? [:]
        do {
            let report = try await service.loadUsage(
                target: capturedTarget,
                remoteHost: capturedHost,
                accountNames: requestedAccountNames ?? status.accounts.filter(\.isLoggedIn).map(\.name),
                force: force
            )
            let checkedAt = Date()
            var reports = usageCacheByKey[key]?.reports ?? [:]
            var checkedAtByAccount = usageCacheByKey[key]?.checkedAtByAccount ?? [:]
            for accountReport in report.accounts {
                reports[accountReport.name] = preservingUsage(accountReport, previous: reports[accountReport.name], fetchedAt: accountReport.fetchedAt ?? report.fetchedAt)
                checkedAtByAccount[accountReport.name] = checkedAt
            }
            reports = reports.filter { capturedAccountNames.contains($0.key) }
            checkedAtByAccount = checkedAtByAccount.filter { capturedAccountNames.contains($0.key) }
            let fetchedAt = report.accounts.contains(where: { $0.usage != nil })
                ? report.fetchedAt
                : usageCacheByKey[key]?.fetchedAt
            let entry = UsageCacheEntry(
                reports: reports,
                fetchedAt: fetchedAt,
                checkedAtByAccount: checkedAtByAccount,
                error: reports.values.contains(where: { $0.error != nil }) ? cabLocalized("部分账号刷新失败，正在显示上次成功获取的额度。") : nil
            )
            usageCacheByKey[key] = entry
            if key == currentUsageCacheKey { applyUsageCache(entry) }
            await evaluateUsageWakeRecovery(
                previousReports: previousReports,
                currentReports: reports,
                cacheKey: key,
                target: capturedTarget,
                remoteHost: capturedHost
            )
            await LowQuotaMonitor.shared.evaluate(UsageNotificationSource(key: capturedTarget == .local ? "local" : "ssh:" + capturedHost, title: capturedTarget == .local ? cabLocalized("这台 Mac") : capturedHost, reports: Array(reports.values)))
            await refreshUsageResetNotificationsIfNeeded(replacingCacheKeys: [key])
        } catch {
            let previous = usageCacheByKey[key]
            let checkedAt = Date()
            var checkedAtByAccount = previous?.checkedAtByAccount ?? [:]
            for accountName in attemptedAccountNames {
                checkedAtByAccount[accountName] = checkedAt
            }
            let entry = UsageCacheEntry(
                reports: previous?.reports ?? [:],
                fetchedAt: previous?.fetchedAt,
                checkedAtByAccount: checkedAtByAccount,
                error: error.localizedDescription
            )
            usageCacheByKey[key] = entry
            if key == currentUsageCacheKey { applyUsageCache(entry) }
        }
    }

    func reloadTokenUsage(force: Bool) async {
        let key = currentUsageCacheKey
        if let cached = tokenUsageByKey[key] {
            tokenUsage = cached
            tokenUsageLoadError = tokenUsageErrorByKey[key]
            if !force && Date().timeIntervalSince(cached.fetchedAt) < 300 { return }
        } else if !force {
            tokenUsage = nil
            tokenUsageLoadError = nil
        }
        guard !tokenUsageRefreshingKeys.contains(key) else { return }
        tokenUsageRefreshingKeys.insert(key)
        isTokenUsageRefreshing = true
        defer {
            tokenUsageRefreshingKeys.remove(key)
            isTokenUsageRefreshing = tokenUsageRefreshingKeys.contains(currentUsageCacheKey)
        }
        let capturedTarget = target
        let capturedHost = remoteHost
        do {
            let report = try await service.loadTokenUsage(target: capturedTarget, remoteHost: capturedHost)
            tokenUsageByKey[key] = report
            tokenUsageErrorByKey.removeValue(forKey: key)
            if key == currentUsageCacheKey {
                tokenUsage = report
                tokenUsageLoadError = nil
            }
        } catch {
            tokenUsageErrorByKey[key] = error.localizedDescription
            if key == currentUsageCacheKey {
                tokenUsageLoadError = error.localizedDescription
            }
        }
    }

    func reloadCodexUpdateStatus(force: Bool) async {
        let key = currentUsageCacheKey
        if let cached = codexUpdateStatusByKey[key] {
            codexUpdateStatus = cached
            codexUpdateError = codexUpdateErrorByKey[key]
            if !force { return }
        } else if !force {
            codexUpdateStatus = nil
            codexUpdateError = nil
        }
        guard !codexUpdateCheckingKeys.contains(key) else { return }
        codexUpdateCheckingKeys.insert(key)
        isCodexUpdateChecking = true
        defer {
            codexUpdateCheckingKeys.remove(key)
            isCodexUpdateChecking = !codexUpdateCheckingKeys.isEmpty
        }
        let capturedTarget = target
        let capturedHost = remoteHost
        do {
            let status = try await service.loadCodexUpdateStatus(target: capturedTarget, remoteHost: capturedHost)
            codexUpdateStatusByKey[key] = status
            codexUpdateErrorByKey.removeValue(forKey: key)
            if key == currentUsageCacheKey {
                codexUpdateStatus = status
                codexUpdateError = nil
            }
        } catch {
            codexUpdateErrorByKey[key] = error.localizedDescription
            if key == currentUsageCacheKey {
                codexUpdateError = error.localizedDescription
            }
        }
    }

    func scheduleUsageRefreshAfterDesktopSwitch(accountName: String) {
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return
            }
            guard let self, self.target == .local else { return }
            await self.reloadUsage(force: true, accountNames: [accountName])
        }
    }

    func runUsageRefreshSchedulerTick() async {
        let now = Date()
        if usageWakeSettings.enabled, let previous = usageWakeState.lastSchedulerTickAt,
           now.timeIntervalSince(previous) > 90 {
            try? logUsageWake(target: "scheduler", phase: "resumed",
                              reason: "tick_gap_seconds:\(Int(now.timeIntervalSince(previous)))")
        }
        usageWakeState.lastSchedulerTickAt = now
        persistUsageWakeState()
        if usageWakeSettings.enabled {
            for endpoint in usageWakeEndpoints(servers: remoteServers) {
                let waits = (usageWakeState.scheduledWaitsByAccount ?? [:]).filter { $0.key.hasPrefix(endpoint.key + "|") }
                for (key, pending) in waits where now > pending.deadline {
                    try? logUsageWake(target: endpoint.key, account: String(key.dropFirst(endpoint.key.count + 1)),
                                      slot: usageScheduledProbeSlotIdentifier(at: pending.scheduledAt, time: pending.slot),
                                      phase: "missed", reason: "nearby_reset_wait_expired")
                    usageWakeState.scheduledWaitsByAccount?[key] = nil
                    persistUsageWakeState()
                }
                let due = waits.values.filter { now >= $0.resetAt && now <= $0.deadline }
                if let pending = due.min(by: { $0.scheduledAt < $1.scheduledAt }) {
                    await runScheduledUsageWake(slot: pending.slot, scheduledAt: pending.scheduledAt, endpoint: endpoint)
                }
            }
        }
        switch usageWakeTickMode(at: now, settings: usageWakeSettings) {
        case let .scheduled(slot):
            // Scheduled execution must not depend on the page currently open.
            for endpoint in usageWakeEndpoints(servers: remoteServers) {
                await runScheduledUsageWake(slot: slot, scheduledAt: now, endpoint: endpoint)
            }
        case .paused: return
        case .automatic:
            guard !isBusy, !usageRefreshingKeys.contains(currentUsageCacheKey) else { return }
            await reloadUsage(force: false)
        }
    }

    func logUsageWake(
        target: String, account: String? = nil, slot: String? = nil,
        phase: String, reason: String, before: AccountUsageReport? = nil, after: AccountUsageReport? = nil
    ) throws {
        try usageWakeJournal.append(UsageWakeEvent(
            target: target, account: account, slot: slot, phase: phase, reason: reason,
            before: before.map(UsageWakeSnapshot.init), after: after.map(UsageWakeSnapshot.init)
        ))
    }

    func runScheduledUsageWake(slot: UsageTimeOfDay, scheduledAt: Date, endpoint: UsageWakeEndpoint, allowProbe: Bool = true) async {
        let slotID = usageScheduledProbeSlotIdentifier(at: scheduledAt, time: slot)
        let tickKey = endpoint.key + "|" + slotID
        guard usageWakeSettings.enabled, usageWakeTickInFlight.insert(tickKey).inserted else { return }
        defer { usageWakeTickInFlight.remove(tickKey) }
        var stage = "journal"
        do {
            // Keep a durable scheduler heartbeat even when UI work postpones it.
            if usageWakeTickLogged.insert(tickKey).inserted {
                try logUsageWake(target: endpoint.key, slot: slotID, phase: "scheduler", reason: "due")
                usageWakeTickLogged = usageWakeTickLogged.filter { $0.contains(slotID.prefix(10)) }
                usageWakeDeferredLogged = usageWakeDeferredLogged.filter { $0.contains(slotID.prefix(10)) }
            }
            guard !isBusy else {
                if usageWakeDeferredLogged.insert(tickKey).inserted {
                    try logUsageWake(target: endpoint.key, slot: slotID, phase: "deferred", reason: "application_busy")
                }
                return
            }
            stage = "status_query"
            let loaded = try await service.loadStatus(target: endpoint.target, remoteHost: endpoint.host)
            let pending = loaded.accounts.filter {
                usageWakeState.lastScheduledSlotByAccount[usageWakeStateKey(cacheKey: endpoint.key, accountName: $0.name)] != slotID
            }
            guard !pending.isEmpty else { return }
            stage = "usage_query"
            let result = try await service.loadUsage(
                target: endpoint.target, remoteHost: endpoint.host,
                accountNames: pending.filter(\.isLoggedIn).map(\.name), force: true
            )
            let reports = Dictionary(result.accounts.map { ($0.name, $0) }, uniquingKeysWith: { _, new in new })
            for account in pending {
                guard usageWakeSettings.enabled else { return }
                let key = usageWakeStateKey(cacheKey: endpoint.key, accountName: account.name)
                let report = reports[account.name]
                let decision = usageWakeDecision(report: report)
                let reason = account.isLoggedIn ? decision.rawValue : "account_not_logged_in"
                stage = "journal"
                // Persist the input and the exact branch before consuming a slot.
                try logUsageWake(target: endpoint.key, account: account.name, slot: slotID,
                                 phase: "decision", reason: reason, before: report)
                if decision == .queryFailed && account.isLoggedIn { continue } // retry queries, never stale quota
                if account.isLoggedIn, (decision == .fiveHourActive || decision == .fiveHourExhausted),
                   let reset = usageWakeNearbyReset(report: report, scheduledAt: scheduledAt, now: Date()) {
                    let pending = UsageWakePendingSchedule(slot: slot, scheduledAt: scheduledAt, resetAt: reset)
                    if usageWakeState.scheduledWaitsByAccount?[key] != pending {
                        try logUsageWake(target: endpoint.key, account: account.name, slot: slotID,
                                         phase: "waiting", reason: "five_hour_resets_within_five_minutes", before: report)
                        if usageWakeState.scheduledWaitsByAccount == nil { usageWakeState.scheduledWaitsByAccount = [:] }
                        usageWakeState.scheduledWaitsByAccount?[key] = pending
                        recordUsageWakeResult("上一轮五小时即将结束，已安排到期后复查", for: key)
                    }
                    continue
                }
                usageWakeState.scheduledWaitsByAccount?[key] = nil
                usageWakeState.lastScheduledSlotByAccount[key] = slotID
                usageWakeState.pendingRecoveryFingerprintByAccount[key] = nil
                persistUsageWakeState()
                guard account.isLoggedIn else {
                    recordUsageWakeResult("账号未登录，已跳过", for: key)
                    continue
                }
                guard decision == .probe else {
                    recordUsageWakeResult(decision.message, for: key)
                    continue
                }
                guard allowProbe else {
                    try logUsageWake(target: endpoint.key, account: account.name, slot: slotID,
                                     phase: "skipped", reason: "diagnostic_read_only", before: report)
                    continue
                }
                guard canAttemptUsageWake(stateKey: key) else {
                    try logUsageWake(target: endpoint.key, account: account.name, slot: slotID,
                                     phase: "skipped", reason: "probe_cooldown", before: report)
                    recordUsageWakeResult("距上次请求不足三十分钟，已跳过", for: key)
                    continue
                }
                await performUsageWake(accountName: account.name, stateKey: key, cacheKey: endpoint.key,
                                       target: endpoint.target, remoteHost: endpoint.host,
                                       reason: "scheduled-period-start", before: report, slotID: slotID)
            }
        } catch {
            do { try logUsageWake(target: endpoint.key, slot: slotID, phase: "failed", reason: stage + ":" + usageWakeProbeFailureReason(error)) }
            catch { errorMessage = "定时任务诊断日志无法保存，已停止发送请求：\(usageWakeJournal.url.path)" }
        }
    }

    func evaluateUsageWakeRecovery(
        previousReports: [String: AccountUsageReport],
        currentReports: [String: AccountUsageReport],
        cacheKey: String,
        target: BridgeTarget,
        remoteHost: String
    ) async {
        guard usageWakeSettings.enabled, usageWakeSettings.wakeOnRecovery else { return }
        for accountName in currentReports.keys.sorted() {
            let current = currentReports[accountName]
            let stateKey = usageWakeStateKey(cacheKey: cacheKey, accountName: accountName)
            let fingerprint = usageWakeRecoveryFingerprint(previousReports[accountName])
            let isPendingRecovery = usageWakeState.pendingRecoveryFingerprintByAccount[stateKey] == fingerprint
            let needsProbe = usageWakeNeedsScheduledProbe(report: current)
            guard usageWakeNeedsProbeAfterRecovery(
                previous: previousReports[accountName],
                current: current
            ) || (isPendingRecovery && needsProbe) else { continue }
            if usageWakeState.lastRecoveryFingerprintByAccount[stateKey] == fingerprint && !isPendingRecovery { continue }
            if usageIsWithinQuietPeriod(Date(), periods: usageWakeSettings.quietPeriods) {
                usageWakeState.pendingRecoveryFingerprintByAccount[stateKey] = fingerprint
                persistUsageWakeState()
                continue
            }
            guard canAttemptUsageWake(stateKey: stateKey) else { continue }
            usageWakeState.lastRecoveryFingerprintByAccount[stateKey] = fingerprint
            usageWakeState.pendingRecoveryFingerprintByAccount[stateKey] = nil
            persistUsageWakeState()
            await performUsageWake(
                accountName: accountName,
                stateKey: stateKey,
                cacheKey: cacheKey,
                target: target,
                remoteHost: remoteHost,
                reason: "recovery", before: current
            )
        }
    }

    func performUsageWake(
        accountName: String,
        stateKey: String,
        cacheKey: String,
        target: BridgeTarget,
        remoteHost: String,
        reason: String,
        before: AccountUsageReport? = nil,
        slotID: String? = nil
    ) async {
        guard !usageWakeInFlightKeys.contains(stateKey) else { return }
        usageWakeInFlightKeys.insert(stateKey)
        defer { usageWakeInFlightKeys.remove(stateKey) }
        let now = Date()
        do {
            try logUsageWake(target: cacheKey, account: accountName, slot: slotID,
                             phase: "request", reason: reason, before: before)
        } catch {
            recordUsageWakeResult("诊断日志无法保存，未发送请求", for: stateKey)
            errorMessage = "定时任务诊断日志无法保存，已停止发送请求。"
            return
        }
        usageWakeState.lastProbeAtByAccount[stateKey] = now
        persistUsageWakeState()
        do {
            try await service.probeUsage(target: target, remoteHost: remoteHost, accountName: accountName)
        } catch {
            try? logUsageWake(target: cacheKey, account: accountName, slot: slotID,
                              phase: "request_failed", reason: usageWakeProbeFailureReason(error), before: before)
            recordUsageWakeResult("唤醒请求失败，未自动重试；见诊断日志", for: stateKey)
            return
        }
        do {
            try logUsageWake(target: cacheKey, account: accountName, slot: slotID,
                             phase: "request_completed", reason: "awaiting_five_hour_verification", before: before)
            let confirmed = try await verifyUsageWake(requestedAt: now, read: {
                let response = try await self.service.loadUsage(target: target, remoteHost: remoteHost,
                                                                accountNames: [accountName], force: true)
                return response.accounts.first { $0.name == accountName }
            }, wait: {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }, observe: { report in
                try self.logUsageWake(target: cacheKey, account: accountName, slot: slotID,
                                      phase: "verification", reason: usageWakeDecision(report: report).rawValue,
                                      before: before, after: report)
            })
            try logUsageWake(target: cacheKey, account: accountName, slot: slotID,
                             phase: "result", reason: confirmed ? "five_hour_confirmed" : "five_hour_not_started")
            recordUsageWakeResult(confirmed ? "已确认五小时倒计时启动；重置时间见诊断日志"
                                           : "请求已完成，但未确认五小时倒计时启动；未重发请求", for: stateKey)
        } catch {
            try? logUsageWake(target: cacheKey, account: accountName, slot: slotID,
                              phase: "verification_failed", reason: "query_or_journal_failed")
            recordUsageWakeResult("请求已完成，但额度复查失败；未重发请求", for: stateKey)
        }
    }

    func canAttemptUsageWake(stateKey: String, now: Date = Date()) -> Bool {
        guard let previous = usageWakeState.lastProbeAtByAccount[stateKey] else { return true }
        return now.timeIntervalSince(previous) >= usageWakeProbeCooldown
    }

    func recordUsageWakeResult(_ result: String, for stateKey: String) {
        usageWakeState.lastResultByAccount[stateKey] = result
        usageWakeState.lastResultAtByAccount[stateKey] = Date()
        persistUsageWakeState()
    }

    func usageWakeStateKey(cacheKey: String, accountName: String) -> String {
        "\(cacheKey)|\(accountName)"
    }

    func usageWakeRecoveryFingerprint(_ report: AccountUsageReport?) -> String {
        guard let report, let usage = report.usage else { return "unknown" }
        let limits = usageCodexRateLimits(for: usage)
        let windows = [limits.primary, limits.secondary].compactMap { $0 }.map {
            "\($0.windowDurationMins ?? 0):\($0.resetsAt ?? 0):\(Int($0.usedPercent * 10))"
        }.sorted().joined(separator: ",")
        return "\(limits.rateLimitReachedType ?? "")|\(windows)"
    }

    func persistUsageWakeSettings() {
        guard let data = try? JSONEncoder().encode(usageWakeSettings) else { return }
        defaults.set(data, forKey: usageWakeSettingsKey)
    }

    func persistUsageWakeState() {
        guard let data = try? JSONEncoder().encode(usageWakeState) else { return }
        defaults.set(data, forKey: usageWakeStateKey)
    }

    var currentUsageCacheKey: String {
        switch target {
        case .local:
            return "local"
        case .remote:
            return "remote:\(selectedRemoteID?.uuidString ?? remoteHost)"
        }
    }

    func restoreUsageForCurrentTarget() {
        applyUsageCache(usageCacheByKey[currentUsageCacheKey])
    }

    func restoreTokenUsageForCurrentTarget() {
        let key = currentUsageCacheKey
        tokenUsage = tokenUsageByKey[key]
        tokenUsageLoadError = tokenUsageErrorByKey[key]
        isTokenUsageRefreshing = tokenUsageRefreshingKeys.contains(key)
    }

    func restoreCodexUpdateStatusForCurrentTarget() {
        let key = currentUsageCacheKey
        codexUpdateStatus = codexUpdateStatusByKey[key]
        codexUpdateError = codexUpdateErrorByKey[key]
    }

    func applyUsageCache(_ entry: UsageCacheEntry?) {
        usageByAccount = entry?.reports ?? [:]
        usageFetchedAt = entry?.fetchedAt
        usageLoadError = entry?.error
    }

    func refreshUsageResetNotificationsIfNeeded(replacingCacheKeys: Set<String>? = nil) async {
        guard usageResetNotificationsEnabled else { return }
        do {
            scheduledUsageResetNotificationCount = try await scheduleUsageResetNotifications(
                replacingCacheKeys: replacingCacheKeys
            )
            usageResetNotificationError = nil
        } catch {
            scheduledUsageResetNotificationCount = 0
            usageResetNotificationError = error.localizedDescription
        }
    }

    func scheduleUsageResetNotifications(replacingCacheKeys: Set<String>? = nil) async throws -> Int {
        let sources = usageCacheByKey.compactMap { key, entry -> UsageNotificationSource? in
            if let replacingCacheKeys, !replacingCacheKeys.contains(key) { return nil }
            let title: String
            if key == "local" {
                title = "这台 Mac"
            } else if key.hasPrefix("remote:"),
                      let value = key.split(separator: ":", maxSplits: 1).last,
                      let id = UUID(uuidString: String(value)),
                      let server = remoteServers.first(where: { $0.id == id }) {
                title = server.name
            } else {
                return nil
            }
            return UsageNotificationSource(
                key: key,
                title: title,
                reports: Array(entry.reports.values)
            )
        }
        let plans = usageResetNotificationPlans(sources: sources)
        return try await usageResetNotificationService.replaceScheduledNotifications(
            with: plans,
            replacingSourceKeys: replacingCacheKeys
        )
    }

}
