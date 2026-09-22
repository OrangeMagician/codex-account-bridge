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
        let cacheKey = currentUsageCacheKey
        let capturedTarget = target
        let capturedHost = remoteHost
        guard !isBusy, !usageRefreshingKeys.contains(cacheKey) else { return }
        let now = Date()
        switch usageWakeTickMode(at: now, settings: usageWakeSettings) {
        case let .scheduled(slot):
            await reloadUsage(force: true)
            guard cacheKey == currentUsageCacheKey else { return }
            await evaluateScheduledUsageWake(
                slot: slot,
                cacheKey: cacheKey,
                target: capturedTarget,
                remoteHost: capturedHost
            )
        case .paused:
            return
        case .automatic:
            await reloadUsage(force: false)
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
            let needsProbe = UsagePeriodKind.allCases.contains {
                usageWakeNeedsProbe(report: current, period: $0)
            }
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
                reason: "recovery"
            )
        }
    }

    func evaluateScheduledUsageWake(
        slot: UsageTimeOfDay?,
        cacheKey: String,
        target: BridgeTarget,
        remoteHost: String
    ) async {
        guard usageWakeSettings.enabled, let slot else { return }
        let now = Date()
        let slotID = usageScheduledProbeSlotIdentifier(at: now, time: slot)
        for account in status.accounts where account.isLoggedIn {
            let stateKey = usageWakeStateKey(cacheKey: cacheKey, accountName: account.name)
            guard usageWakeState.lastScheduledSlotByAccount[stateKey] != slotID else { continue }
            guard let report = usageByAccount[account.name], report.error == nil, report.usage != nil else { continue }
            usageWakeState.lastScheduledSlotByAccount[stateKey] = slotID
            persistUsageWakeState()
            guard usageWakeNeedsScheduledProbe(report: report, now: now) else {
                usageWakeState.pendingRecoveryFingerprintByAccount[stateKey] = nil
                persistUsageWakeState()
                recordUsageWakeResult("额度周期均在计时，无需请求", for: stateKey)
                continue
            }
            guard canAttemptUsageWake(stateKey: stateKey) else { continue }
            usageWakeState.pendingRecoveryFingerprintByAccount[stateKey] = nil
            persistUsageWakeState()
            await performUsageWake(
                accountName: account.name,
                stateKey: stateKey,
                cacheKey: cacheKey,
                target: target,
                remoteHost: remoteHost,
                reason: "scheduled-period-start"
            )
        }
    }

    func performUsageWake(
        accountName: String,
        stateKey: String,
        cacheKey: String,
        target: BridgeTarget,
        remoteHost: String,
        reason: String
    ) async {
        guard !usageWakeInFlightKeys.contains(stateKey) else { return }
        usageWakeInFlightKeys.insert(stateKey)
        defer { usageWakeInFlightKeys.remove(stateKey) }
        let now = Date()
        usageWakeState.lastProbeAtByAccount[stateKey] = now
        persistUsageWakeState()
        do {
            try await service.probeUsage(
                target: target,
                remoteHost: remoteHost,
                accountName: accountName
            )
            recordUsageWakeResult("已发送最低消耗请求（\(reason)）", for: stateKey)
            if cacheKey == currentUsageCacheKey {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard let self else { return }
                    await self.reloadUsage(force: true)
                }
            }
        } catch {
            recordUsageWakeResult("唤醒请求失败，未自动重试", for: stateKey)
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
