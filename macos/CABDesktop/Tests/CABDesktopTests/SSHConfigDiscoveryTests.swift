import Foundation
import CABContinuity
import Testing
@testable import CABDesktop

@Suite("SSH config and login URL discovery")
struct SSHConfigDiscoveryTests {
    @MainActor
    @Test func globalSettingsAndAccountNavigationUseOneSelectionState() {
        let store = CABStore()
        store.sidebarSelection = "work"
        #expect(store.selectedAccount == "work")
        #expect(!store.showingGlobalSettings)

        store.sidebarSelection = CABStore.globalSettingsSelection
        #expect(store.selectedAccount == nil)
        #expect(store.showingGlobalSettings)
    }

    @Test func usageRefreshIntervalsExposeManualAndTimedModes() {
        #expect(UsageRefreshInterval.fifteenMinutes.duration == 900)
        #expect(UsageRefreshInterval.oneHour.duration == 3_600)
        #expect(UsageRefreshInterval.manual.duration == nil)
    }

    @Test func interfaceLanguageProvidesSystemEnglishAndChineseModes() {
        #expect(InterfaceLanguage.english.localeIdentifier == "en")
        #expect(InterfaceLanguage.simplifiedChinese.localeIdentifier == "zh-Hans")
        #expect(InterfaceLanguage.system.localeIdentifier == "en" || InterfaceLanguage.system.localeIdentifier == "zh-Hans")
    }

    @Test func classifiesEditorCodexProcessesAndExcludesDesktopChildren() {
        let vscode = "/Users/test/.vscode/extensions/openai.chatgpt/bin/codex"
        let desktop = "/Applications/ChatGPT.app/Contents/Resources/codex"
        #expect(codexProcessLabel(executablePath: vscode) == "VS Code 的 Codex 扩展")
        #expect(!isCodexDesktopProcess(executablePath: vscode, desktopApplicationPath: "/Applications/ChatGPT.app"))
        #expect(isCodexDesktopProcess(executablePath: desktop, desktopApplicationPath: "/Applications/ChatGPT.app"))
        #expect(codexProcessLabel(executablePath: "/opt/homebrew/bin/codex") == "Codex CLI 或 app-server")
    }

    @Test func explainsWhenVSCodeKeepsItsCodexExtensionAlive() {
        let remaining = [
            CodexProcessConflict(pid: 42, label: "VS Code 的 Codex 扩展", title: nil),
        ]

        let message = desktopSwitchStopFailureMessage(stopError: nil, remaining: remaining)

        #expect(message.contains("PID 42"))
        #expect(message.contains("VS Code"))
        #expect(message.contains("自动重新启动"))
    }

    @Test func remoteSwitchExcludesCodexOwnedByAgentServices() {
        let processes = [
            CodexProcessStatus(pid: 101, parentPID: 11, elapsed: "1:00", tty: "?", state: "Sl", executable: "codex"),
            CodexProcessStatus(pid: 102, parentPID: 22, elapsed: "2:00", tty: "pts/1", state: "Sl", executable: "codex"),
            CodexProcessStatus(pid: 103, parentPID: 1, elapsed: "3:00", tty: "?", state: "Sl", executable: "codex"),
        ]

        let filtered = remoteUserCodexProcesses(processes, excludingParentPIDs: [11, 22])

        #expect(filtered.map(\.pid) == [103])
    }

    @Test func parsesSystemdMainPIDsForAgentExclusion() {
        let output = """
        MainPID=3611804
        Names=hermes-gateway.service

        MainPID=922674
        Names=openclaw-gateway.service openclaw.service
        """

        let parsed = systemdMainPIDsByService(from: output)

        #expect(parsed["hermes-gateway.service"] == 3_611_804)
        #expect(parsed["openclaw-gateway.service"] == 922_674)
        #expect(parsed["openclaw.service"] == 922_674)
    }

    @Test func remoteSwitchChecksOnlyTheStoppedSnapshotAfterAutomaticReconnect() {
        let stoppedSnapshot = [
            CodexProcessStatus(pid: 101, parentPID: 1, elapsed: "1:00", tty: "?", state: "Sl", executable: "codex"),
            CodexProcessStatus(pid: 102, parentPID: 2, elapsed: "1:00", tty: "?", state: "Sl", executable: "codex"),
        ]
        let afterReconnect = [
            CodexProcessStatus(pid: 102, parentPID: 2, elapsed: "1:01", tty: "?", state: "Sl", executable: "codex"),
            CodexProcessStatus(pid: 201, parentPID: 3, elapsed: "0:01", tty: "?", state: "Sl", executable: "codex"),
        ]

        let remainingOriginals = codexProcesses(afterReconnect, matchingPIDsFrom: stoppedSnapshot)

        #expect(remainingOriginals.map(\.pid) == [102])
        #expect(!remainingOriginals.contains(where: { $0.pid == 201 }))
    }

    @Test func finderLaunchEnvironmentCanResolveHomebrewCodex() {
        let environment = localCABEnvironment(
            baseEnvironment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            executableCheck: { $0 == "/opt/homebrew/bin/codex" }
        )

        #expect(environment["CAB_REAL_CODEX"] == "/opt/homebrew/bin/codex")
        #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/Users/test/.local/bin:/usr/bin:/bin")
    }

    @Test func explicitCodexPathIsNeverOverridden() {
        let environment = localCABEnvironment(
            baseEnvironment: ["PATH": "/usr/bin", "CAB_REAL_CODEX": "/custom/codex"],
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            executableCheck: { _ in true }
        )

        #expect(environment["CAB_REAL_CODEX"] == "/custom/codex")
    }

    @Test func desktopBundledCodexTakesPriorityOverOlderCommandLineInstall() {
        let environment = localCABEnvironment(
            baseEnvironment: ["PATH": "/opt/homebrew/bin:/usr/bin"],
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            executableCheck: {
                $0 == "/Applications/ChatGPT.app/Contents/Resources/codex" ||
                    $0 == "/opt/homebrew/bin/codex"
            }
        )

        #expect(environment["CAB_REAL_CODEX"] == "/Applications/ChatGPT.app/Contents/Resources/codex")
    }

    @Test func preparesOfficialThreadCatalogRebuildWithBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("state_5.sqlite")
        try runSQLiteForTest(database, sql: "CREATE TABLE backfill_state (id INTEGER PRIMARY KEY, status TEXT NOT NULL); INSERT INTO backfill_state VALUES (1, 'complete');")

        let service = CABService()
        let backup = try await service.prepareCodexThreadIndexRebuild(codexHome: root.path)

        #expect(backup != nil)
        #expect(FileManager.default.fileExists(atPath: backup?.path ?? ""))
        #expect(try sqliteScalarForTest(database, sql: "SELECT count(*) FROM backfill_state;") == "0")
        #expect(try sqliteScalarForTest(database, sql: "PRAGMA integrity_check;") == "ok")
        if let backup {
            try service.restoreCodexThreadIndex(backupURL: backup, codexHome: root.path)
            #expect(try sqliteScalarForTest(database, sql: "SELECT count(*) FROM backfill_state;") == "1")
        }
    }

    @Test func synchronizesPortableWorkspaceStateWithoutAccountOrSecurityState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try #"{"local-projects":{"project-a":{"id":"project-a"}},"project-order":["project-a"],"thread-project-assignments":{"thread-a":{"projectId":"remote-a"}},"selected-project":{"projectId":"remote-a","type":"remote"},"codex-managed-remote-connections":[{"hostId":"host-a","alias":"oraclearm","identity":null}],"remote-projects":[{"id":"remote-a","hostId":"host-a","remotePath":"/srv/app","label":"app"}],"remote-connection-auto-connect-by-host-id":{"host-a":true},"remote-connection-analytics-id-by-host-id":{"host-a":"analytics-a"},"selected-remote-host-id":"host-a","remote-project-connection-backfill-completed":true,"account-token":"must-not-copy","electron-persisted-atom-state":{"prompt-history":["source-prompt"],"composer-prompt-drafts-v2":{"thread-a":"source-draft"},"client-thread-bindings-v1":{"client-a":"thread-a"},"thread-descriptions-v1":{"thread-a":"Source title"},"thread-client-id-v1:thread-a":"client-a","permission-selection-by-host-id:host-a":"danger-full-access","plugin-oauth-state":{"secret":"must-not-copy"}}}"#.write(
            to: source.appendingPathComponent(".codex-global-state.json"), atomically: true, encoding: .utf8
        )
        try #"{"local-projects":{"project-b":{"id":"project-b"}},"project-order":["project-b"],"account-token":"target-only","window-preference":42,"electron-persisted-atom-state":{"prompt-history":["target-prompt"],"composer-prompt-drafts-v2":{"thread-b":"target-draft"},"permission-selection-by-host-id:host-b":"workspace-write","plugin-oauth-state":{"secret":"target-only"}}}"#.write(
            to: target.appendingPathComponent(".codex-global-state.json"), atomically: true, encoding: .utf8
        )

        let result = try CodexWorkspaceState.synchronize(
            sourceHome: source.path,
            targetHome: target.path,
            knownHomes: [source.path, target.path]
        )
        let data = try Data(contentsOf: target.appendingPathComponent(".codex-global-state.json"))
        let state = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let projects = try #require(state["local-projects"] as? [String: Any])

        #expect(result.projectCount == 3)
        #expect(result.backupURL != nil)
        #expect(Set(projects.keys) == ["project-a", "project-b"])
        #expect(state["project-order"] as? [String] == ["project-a", "project-b"])
        #expect(state["account-token"] as? String == "target-only")
        #expect(state["window-preference"] as? Int == 42)
        let atoms = try #require(state["electron-persisted-atom-state"] as? [String: Any])
        #expect(atoms["prompt-history"] as? [String] == ["source-prompt", "target-prompt"])
        let drafts = try #require(atoms["composer-prompt-drafts-v2"] as? [String: String])
        #expect(drafts == ["thread-a": "source-draft", "thread-b": "target-draft"])
        #expect(atoms["thread-client-id-v1:thread-a"] as? String == "client-a")
        #expect(atoms["permission-selection-by-host-id:host-a"] == nil)
        #expect(atoms["permission-selection-by-host-id:host-b"] as? String == "workspace-write")
        #expect((atoms["plugin-oauth-state"] as? [String: String])?["secret"] == "target-only")
        let connections = try #require(state["codex-managed-remote-connections"] as? [[String: Any]])
        let remoteProjects = try #require(state["remote-projects"] as? [[String: Any]])
        #expect(connections.count == 1)
        #expect(connections[0]["alias"] as? String == "oraclearm")
        #expect(connections[0]["identity"] == nil)
        #expect(remoteProjects.count == 1)
        #expect(remoteProjects[0]["remotePath"] as? String == "/srv/app")
        #expect((state["remote-connection-auto-connect-by-host-id"] as? [String: Bool])?["host-a"] == true)
        #expect(state["selected-remote-host-id"] as? String == "host-a")
    }

    @Test func mergesAndRestoresDesktopThreadCatalogWithoutReplacingUnrelatedState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        let sourceSQLite = source.appendingPathComponent("sqlite")
        let targetSQLite = target.appendingPathComponent("sqlite")
        try FileManager.default.createDirectory(at: sourceSQLite, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetSQLite, withIntermediateDirectories: true)
        let sourceDatabase = sourceSQLite.appendingPathComponent("codex-dev.db")
        let targetDatabase = targetSQLite.appendingPathComponent("codex-dev.db")
        try createThreadCatalogForTest(sourceDatabase)
        try createThreadCatalogForTest(targetDatabase)
        try runSQLiteForTest(sourceDatabase, sql: "INSERT INTO local_thread_catalog_hosts VALUES ('host-a','local'); INSERT INTO local_thread_catalog (host_id,thread_id,display_title) VALUES ('host-a','shared','Source title'),('host-a','source-only','Source only');")
        try runSQLiteForTest(targetDatabase, sql: "INSERT INTO local_thread_catalog_hosts VALUES ('host-a','local'); INSERT INTO local_thread_catalog (host_id,thread_id,display_title) VALUES ('host-a','shared','Target title'),('host-a','target-only','Target only'); INSERT INTO unrelated_state VALUES (1,'keep-me');")

        let synchronized = try CodexThreadCatalogState.synchronize(
            sourceHome: source.path,
            targetHome: target.path,
            knownHomes: [source.path, target.path]
        )
        let result = try #require(synchronized)

        #expect(result.rowCount == 3)
        #expect(try sqliteScalarForTest(targetDatabase, sql: "SELECT display_title FROM local_thread_catalog WHERE thread_id='shared';") == "Source title")
        #expect(try sqliteScalarForTest(targetDatabase, sql: "SELECT value FROM unrelated_state WHERE id=1;") == "keep-me")
        try CodexThreadCatalogState.restore(result)
        #expect(try sqliteScalarForTest(targetDatabase, sql: "SELECT count(*) FROM local_thread_catalog;") == "2")
        #expect(try sqliteScalarForTest(targetDatabase, sql: "SELECT display_title FROM local_thread_catalog WHERE thread_id='shared';") == "Target title")
    }

    @Test func synchronizesAndRestoresCompletePortableContinuityState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("skills/source-skill"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("skills/target-skill"), withIntermediateDirectories: true)
        try "source".write(to: source.appendingPathComponent("skills/source-skill/SKILL.md"), atomically: true, encoding: .utf8)
        try "target".write(to: target.appendingPathComponent("skills/target-skill/SKILL.md"), atomically: true, encoding: .utf8)
        try #"{"display":"source"}"#.write(to: source.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8)
        try #"{"display":"target"}"#.write(to: target.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8)
        try "source-config".write(to: source.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try "target-config".write(to: target.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let sourceGoals = source.appendingPathComponent("goals_1.sqlite")
        let targetGoals = target.appendingPathComponent("goals_1.sqlite")
        try createGoalsDatabaseForTest(sourceGoals)
        try createGoalsDatabaseForTest(targetGoals)
        try runSQLiteForTest(sourceGoals, sql: "INSERT INTO thread_goals VALUES ('source-thread','source-goal','Source objective','active',NULL,1,2,3,4);")
        try runSQLiteForTest(targetGoals, sql: "INSERT INTO thread_goals VALUES ('target-thread','target-goal','Target objective','complete',NULL,5,6,7,8);")

        let result = try CodexContinuityState.synchronize(
            sourceHome: source.path,
            targetHome: target.path,
            knownHomes: [source.path, target.path]
        )

        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("skills/source-skill/SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("skills/target-skill/SKILL.md").path))
        #expect(try sqliteScalarForTest(targetGoals, sql: "SELECT count(*) FROM thread_goals;") == "2")
        let mergedHistory = try String(contentsOf: target.appendingPathComponent("history.jsonl"), encoding: .utf8)
        #expect(mergedHistory.contains("source"))
        #expect(mergedHistory.contains("target"))
        #expect(try String(contentsOf: target.appendingPathComponent("config.toml"), encoding: .utf8) == "target-config")

        try CodexContinuityState.restore(result)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("skills/source-skill/SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("skills/target-skill/SKILL.md").path))
        #expect(try sqliteScalarForTest(targetGoals, sql: "SELECT count(*) FROM thread_goals;") == "1")
        #expect(try String(contentsOf: target.appendingPathComponent("history.jsonl"), encoding: .utf8) == #"{"display":"target"}"#)
    }

    @Test func restoresWorkspaceCatalogAfterFailedDesktopSwitch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let targetState = target.appendingPathComponent(".codex-global-state.json")
        try #"{"local-projects":{"before":{"id":"before"}}}"#.write(to: targetState, atomically: true, encoding: .utf8)
        try #"{"local-projects":{"after":{"id":"after"}}}"#.write(
            to: source.appendingPathComponent(".codex-global-state.json"), atomically: true, encoding: .utf8
        )

        let result = try CodexWorkspaceState.synchronize(sourceHome: source.path, targetHome: target.path, knownHomes: [])
        try CodexWorkspaceState.restore(result)

        let restored = try String(contentsOf: targetState, encoding: .utf8)
        #expect(restored == #"{"local-projects":{"before":{"id":"before"}}}"#)
    }

    @Test func decodesStableUsageReportWithoutAccountIdentityData() throws {
        let json = #"{"fetched_at":"2026-08-25T08:11:44Z","accounts":[{"name":"work","usage":{"plan_type":"plus","rate_limits":{"limit_id":"codex","primary":{"used_percent":42.5,"window_duration_mins":10080,"resets_at":1788139274},"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"plan_type":"plus"},"reset_credits":{"available_count":1,"credits":[{"reset_type":"codexRateLimits","status":"available","granted_at":1788000000,"expires_at":1789000000}]}}}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(UsageReport.self, from: Data(json.utf8))
        #expect(report.accounts.count == 1)
        #expect(report.accounts[0].usage?.rateLimits.primary?.remainingPercent == 57.5)
        #expect(report.accounts[0].usage?.resetCredits?.availableCount == 1)
    }

    @Test func plansOnlyFutureUsageResetNotificationsInTimeOrder() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let limits = UsageRateLimitSnapshot(
            limitID: "codex",
            limitName: nil,
            primary: UsageWindow(usedPercent: 90, windowDurationMins: 300, resetsAt: 2_000_000_600),
            secondary: UsageWindow(usedPercent: 30, windowDurationMins: 10_080, resetsAt: 1_999_999_999),
            credits: nil,
            individualLimit: nil,
            spendControlReached: nil,
            planType: "plus",
            rateLimitReachedType: nil
        )
        let report = AccountUsageReport(
            name: "work",
            usage: CodexUsageSnapshot(planType: "plus", rateLimits: limits, rateLimitsByLimitID: nil, resetCredits: nil),
            error: nil
        )

        let plans = usageResetNotificationPlans(
            sources: [UsageNotificationSource(key: "local", title: "这台 Mac", reports: [report])],
            now: now
        )

        #expect(plans.count == 1)
        #expect(plans[0].date == Date(timeIntervalSince1970: 2_000_000_600))
        #expect(plans[0].body.contains("work"))
        #expect(plans[0].body.contains("主要周期"))
    }

    @Test func capsUsageResetNotificationsToSystemSafeCount() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let reports = (0..<70).map { index -> AccountUsageReport in
            let limits = UsageRateLimitSnapshot(
                limitID: nil,
                limitName: nil,
                primary: UsageWindow(usedPercent: 50, windowDurationMins: 300, resetsAt: Int64(2_000_000_100 + index)),
                secondary: nil,
                credits: nil,
                individualLimit: nil,
                spendControlReached: nil,
                planType: nil,
                rateLimitReachedType: nil
            )
            return AccountUsageReport(
                name: "account-\(index)",
                usage: CodexUsageSnapshot(planType: nil, rateLimits: limits, rateLimitsByLimitID: nil, resetCredits: nil),
                error: nil
            )
        }

        let plans = usageResetNotificationPlans(
            sources: [UsageNotificationSource(key: "local", title: "这台 Mac", reports: reports)],
            now: now
        )

        #expect(plans.count == 60)
        #expect(plans.first?.date == Date(timeIntervalSince1970: 2_000_000_100))
        #expect(plans.last?.date == Date(timeIntervalSince1970: 2_000_000_159))
    }

    @Test func replacesOnlyUsageNotificationsForRefreshedSource() {
        let identifiers = [
            "cab.usage-reset.local.work.primary.1",
            "cab.usage-reset.remote:server-a.work.primary.2",
            "cab.usage-reset.remote:server-b.work.primary.3",
            "unrelated.notification",
        ]

        let local = usageResetNotificationIdentifiersToReplace(identifiers, sourceKeys: ["local"])
        let serverA = usageResetNotificationIdentifiersToReplace(
            identifiers,
            sourceKeys: ["remote:server-a"]
        )
        let all = usageResetNotificationIdentifiersToReplace(identifiers, sourceKeys: nil)

        #expect(local == ["cab.usage-reset.local.work.primary.1"])
        #expect(serverA == ["cab.usage-reset.remote:server-a.work.primary.2"])
        #expect(all.count == 3)
        #expect(!all.contains("unrelated.notification"))
    }

    @Test func keepsRefreshingEachExhaustedAccountAtItsConfiguredInterval() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let work = usageReportForRefreshPolicy(
            name: "work",
            primaryRemaining: 0,
            primaryReset: 2_000_000_600,
            secondaryRemaining: 0,
            secondaryReset: 2_000_000_900
        )
        let personal = usageReportForRefreshPolicy(
            name: "personal",
            primaryRemaining: 0,
            primaryReset: 2_000_000_700
        )

        let workDecision = usageAutomaticRefreshDecision(
            report: work,
            cacheCheckedAt: now.addingTimeInterval(-901),
            interval: .fifteenMinutes,
            now: now
        )
        let personalDecision = usageAutomaticRefreshDecision(
            report: personal,
            cacheCheckedAt: now.addingTimeInterval(-901),
            interval: .fifteenMinutes,
            now: now
        )

        #expect(workDecision == .refresh)
        #expect(personalDecision == .refresh)
    }

    @Test func refreshesAllAccountsWhenTheirCacheIntervalHasElapsed() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let reports = [
            "work": usageReportForRefreshPolicy(
                name: "work",
                primaryRemaining: 0,
                primaryReset: 2_000_000_600
            ),
            "personal": usageReportForRefreshPolicy(
                name: "personal",
                primaryRemaining: 25,
                primaryReset: 2_000_000_700
            ),
        ]

        let accountNames = usageAccountNamesToRefresh(
            accountNames: ["work", "personal"],
            reports: reports,
            checkedAtByAccount: [
                "work": now.addingTimeInterval(-901),
                "personal": now.addingTimeInterval(-901),
            ],
            interval: .fifteenMinutes,
            now: now
        )

        #expect(accountNames == ["personal", "work"])
    }

    @Test func doesNotBypassConfiguredIntervalAfterExhaustedUsageResets() {
        let resetDate = Date(timeIntervalSince1970: 2_000_000_000)
        let report = usageReportForRefreshPolicy(
            name: "work",
            primaryRemaining: 0,
            primaryReset: Int64(resetDate.timeIntervalSince1970)
        )

        let decision = usageAutomaticRefreshDecision(
            report: report,
            cacheCheckedAt: resetDate.addingTimeInterval(-300),
            interval: .oneHour,
            now: resetDate.addingTimeInterval(1)
        )

        #expect(decision == .useCache)
    }

    @Test func usageWakeSettingsAreCappedAtThreeEntries() {
        var settings = UsageWakeSettings(
            enabled: true,
            wakeOnRecovery: true,
            weeklyProbeTimes: [
                UsageTimeOfDay(hour: 9, minute: 0)!,
                UsageTimeOfDay(hour: 7, minute: 30)!,
                UsageTimeOfDay(hour: 9, minute: 0)!,
                UsageTimeOfDay(hour: 12, minute: 0)!,
                UsageTimeOfDay(hour: 18, minute: 0)!,
            ],
            quietPeriods: [
                UsageQuietPeriod(start: UsageTimeOfDay(hour: 22, minute: 0)!, end: UsageTimeOfDay(hour: 7, minute: 0)!),
                UsageQuietPeriod(start: UsageTimeOfDay(hour: 22, minute: 0)!, end: UsageTimeOfDay(hour: 7, minute: 0)!),
                UsageQuietPeriod(start: UsageTimeOfDay(hour: 12, minute: 0)!, end: UsageTimeOfDay(hour: 13, minute: 0)!),
                UsageQuietPeriod(start: UsageTimeOfDay(hour: 18, minute: 0)!, end: UsageTimeOfDay(hour: 19, minute: 0)!),
            ]
        )

        settings.normalize()

        #expect(settings.weeklyProbeTimes.map(\.id) == ["07:30", "09:00", "12:00"])
        #expect(settings.quietPeriods.count == 3)
        #expect(settings.quietPeriods.map(\.id).contains("22:00-07:00"))
    }

    @Test func usageWakeClassifiesPeriodsByReturnedWindowDuration() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fiveHourReset = Int64(now.timeIntervalSince1970) + 600
        let weeklyReset = Int64(now.timeIntervalSince1970) + 3_600
        let report = usageReportWithLimits(
            primary: UsageWindow(usedPercent: 90, windowDurationMins: 300, resetsAt: fiveHourReset),
            secondary: UsageWindow(usedPercent: 40, windowDurationMins: 10_080, resetsAt: weeklyReset)
        )

        #expect(usagePeriodState(report: report, period: .fiveHour, now: now) == .active(resetDate: Date(timeIntervalSince1970: TimeInterval(fiveHourReset))))
        #expect(usagePeriodState(report: report, period: .weekly, now: now) == .active(resetDate: Date(timeIntervalSince1970: TimeInterval(weeklyReset))))
    }

    @Test func usagePolicyPrefersTheOfficialCodexLimitGroupWhenPresent() {
        let fallback = UsageRateLimitSnapshot(
            limitID: "fallback",
            limitName: nil,
            primary: UsageWindow(usedPercent: 99, windowDurationMins: 300, resetsAt: nil),
            secondary: nil,
            credits: nil,
            individualLimit: nil,
            spendControlReached: nil,
            planType: nil,
            rateLimitReachedType: nil
        )
        let codex = UsageRateLimitSnapshot(
            limitID: "codex",
            limitName: nil,
            primary: UsageWindow(usedPercent: 25, windowDurationMins: 300, resetsAt: nil),
            secondary: nil,
            credits: nil,
            individualLimit: nil,
            spendControlReached: nil,
            planType: nil,
            rateLimitReachedType: nil
        )
        let snapshot = CodexUsageSnapshot(
            planType: nil,
            rateLimits: fallback,
            rateLimitsByLimitID: ["codex": codex],
            resetCredits: nil
        )

        #expect(usageCodexRateLimits(for: snapshot) == codex)
    }

    @Test func usageWakeProbesOnlyWhenWeeklyWindowHasNotStarted() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let notStarted = usageReportWithLimits(
            primary: UsageWindow(usedPercent: 60, windowDurationMins: 300, resetsAt: Int64(now.timeIntervalSince1970) + 600),
            secondary: nil
        )
        let active = usageReportWithLimits(
            primary: UsageWindow(usedPercent: 60, windowDurationMins: 300, resetsAt: Int64(now.timeIntervalSince1970) + 600),
            secondary: UsageWindow(usedPercent: 0, windowDurationMins: 10_080, resetsAt: Int64(now.timeIntervalSince1970) + 3_600)
        )

        #expect(usageWakeNeedsProbe(report: notStarted, period: .weekly, now: now))
        #expect(!usageWakeNeedsProbe(report: active, period: .weekly, now: now))
    }

    @Test func usageWakeDoesNotProbeWhenWindowDurationIsUnknown() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let report = usageReportWithLimits(
            primary: UsageWindow(usedPercent: 60, windowDurationMins: nil, resetsAt: Int64(now.timeIntervalSince1970) + 600),
            secondary: nil
        )

        #expect(usagePeriodState(report: report, period: .weekly, now: now) == .unknown)
        #expect(!usageWakeNeedsProbe(report: report, period: .weekly, now: now))
    }

    @Test func usageWakeRecoveryRequiresExhaustedPreviousAndAvailableCurrent() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let previous = usageReportWithLimits(
            primary: UsageWindow(usedPercent: 100, windowDurationMins: 300, resetsAt: Int64(now.timeIntervalSince1970) + 600),
            secondary: UsageWindow(usedPercent: 100, windowDurationMins: 10_080, resetsAt: Int64(now.timeIntervalSince1970) + 3_600)
        )
        let current = usageReportWithLimits(
            primary: UsageWindow(usedPercent: 10, windowDurationMins: 300, resetsAt: Int64(now.timeIntervalSince1970) + 600),
            secondary: nil
        )

        #expect(usageWakeNeedsProbeAfterRecovery(previous: previous, current: current, now: now))
    }

    @Test func usageWakeQuietPeriodsSupportCrossMidnightWindows() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 23, minute: 30))!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 12, minute: 0))!
        let quiet = UsageQuietPeriod(start: UsageTimeOfDay(hour: 22, minute: 0)!, end: UsageTimeOfDay(hour: 7, minute: 0)!)

        #expect(usageIsWithinQuietPeriod(day, periods: [quiet], calendar: calendar))
        #expect(!usageIsWithinQuietPeriod(noon, periods: [quiet], calendar: calendar))
    }

    private func usageReportForRefreshPolicy(
        name: String,
        primaryRemaining: Double,
        primaryReset: Int64,
        secondaryRemaining: Double? = nil,
        secondaryReset: Int64? = nil
    ) -> AccountUsageReport {
        let limits = UsageRateLimitSnapshot(
            limitID: nil,
            limitName: nil,
            primary: UsageWindow(
                usedPercent: 100 - primaryRemaining,
                windowDurationMins: 300,
                resetsAt: primaryReset
            ),
            secondary: secondaryRemaining.map { remaining in
                UsageWindow(
                    usedPercent: 100 - remaining,
                    windowDurationMins: 10_080,
                    resetsAt: secondaryReset
                )
            },
            credits: nil,
            individualLimit: nil,
            spendControlReached: nil,
            planType: nil,
            rateLimitReachedType: nil
        )
        return AccountUsageReport(
            name: name,
            usage: CodexUsageSnapshot(
                planType: nil,
                rateLimits: limits,
                rateLimitsByLimitID: nil,
                resetCredits: nil
            ),
            error: nil
        )
    }

    private func usageReportWithLimits(primary: UsageWindow?, secondary: UsageWindow?) -> AccountUsageReport {
        AccountUsageReport(
            name: "wake",
            usage: CodexUsageSnapshot(
                planType: nil,
                rateLimits: UsageRateLimitSnapshot(
                    limitID: "codex",
                    limitName: nil,
                    primary: primary,
                    secondary: secondary,
                    credits: nil,
                    individualLimit: nil,
                    spendControlReached: nil,
                    planType: nil,
                    rateLimitReachedType: nil
                ),
                rateLimitsByLimitID: nil,
                resetCredits: nil
            ),
            error: nil
        )
    }

    @Test func discoversConcreteAliasesAndIncludesWithoutReadingIdentityFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ssh = root.appendingPathComponent(".ssh")
        let includes = ssh.appendingPathComponent("conf.d")
        try FileManager.default.createDirectory(at: includes, withIntermediateDirectories: true)
        try """
        Host *
          IdentityFile ~/.ssh/private_key
        Host primary prod-1 *.wild !excluded
        Include conf.d/*.conf
        """.write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try """
        Host nested
          HostName example.invalid
        """.write(to: includes.appendingPathComponent("servers.conf"), atomically: true, encoding: .utf8)

        let aliases = try SSHConfigDiscovery(homeDirectory: root).discover()

        #expect(aliases == ["nested", "primary", "prod-1"])
        #expect(!aliases.contains("private_key"))
    }

    @Test func officialLoginURLAcceptsOnlyOpenAIDomains() {
        let service = CABService()
        #expect(service.officialLoginURL(in: "Open https://example.com/device") == nil)
        #expect(service.officialLoginURL(in: "Open https://auth.openai.com/codex/device and enter the code")?.absoluteString == "https://auth.openai.com/codex/device")
        #expect(service.officialLoginURL(in: "Open \u{001B}[94mhttps://auth.openai.com/codex/device\u{001B}[0m now")?.absoluteString == "https://auth.openai.com/codex/device")
        #expect(service.officialLoginURL(in: "plugin warning https://chatgpt.com/backend-api/plugins/featured") == nil)
        let oauth = "https://auth.openai.com/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"
        #expect(service.officialLoginURL(in: "Open \(oauth)")?.absoluteString == oauth)
        #expect(service.officialLoginURL(in: "https://auth.openai.com/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A9999%2Fauth%2Fcallback") == nil)
        #expect(service.officialLoginURL(in: "https://auth.openai.com/oauth/authorize?redirect_uri=https%3A%2F%2Fevil.example%2Fcallback") == nil)
    }

    @Test func commandOutputBufferCapsRetainedOutput() {
        let buffer = CommandOutputBuffer()
        let oversized = String(repeating: "x", count: 2_100_000)
        _ = buffer.append(Data(oversized.utf8), toStandardOutput: true)
        let result = buffer.result(exitCode: 0)
        #expect(result.output.count < 2_001_000)
        #expect(result.output.contains("CAB 已截断"))
    }

    @Test func safariIsAvailableOnlyForRegularBrowserLogin() {
        #expect(BrowserChoice.safari.privateArgument == nil)
        #expect(BrowserChoice.chrome.privateArgument == "--incognito")
        #expect(BrowserChoice.edge.privateArgument == "--inprivate")
    }
}

private func runSQLiteForTest(_ database: URL, sql: String) throws {
    let process = Process()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [database.path, sql]
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "sqlite3 failed"
        throw NSError(domain: "CABDesktopTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private func createThreadCatalogForTest(_ database: URL) throws {
    try runSQLiteForTest(database, sql: """
    CREATE TABLE local_thread_catalog_hosts (host_id TEXT PRIMARY KEY, host_kind TEXT NOT NULL);
    CREATE TABLE local_thread_catalog_metadata (id INTEGER PRIMARY KEY, catalog_revision INTEGER NOT NULL);
    INSERT INTO local_thread_catalog_metadata VALUES (1, 1);
    CREATE TABLE local_thread_catalog (
      host_id TEXT NOT NULL, thread_id TEXT NOT NULL, display_title TEXT,
      source_created_at INTEGER, source_updated_at INTEGER, cwd TEXT,
      source_kind TEXT, source_detail TEXT, model_provider TEXT, git_branch TEXT,
      observation_sequence INTEGER, missing_candidate INTEGER, thread_source TEXT,
      source_recency_at INTEGER, pending_observed_title TEXT, project_id TEXT,
      conversation_origin TEXT, PRIMARY KEY (host_id, thread_id)
    );
    CREATE TABLE unrelated_state (id INTEGER PRIMARY KEY, value TEXT NOT NULL);
    """)
}

private func createGoalsDatabaseForTest(_ database: URL) throws {
    try runSQLiteForTest(database, sql: """
    CREATE TABLE thread_goals (
      thread_id TEXT PRIMARY KEY NOT NULL, goal_id TEXT NOT NULL, objective TEXT NOT NULL,
      status TEXT NOT NULL, token_budget INTEGER, tokens_used INTEGER NOT NULL DEFAULT 0,
      time_used_seconds INTEGER NOT NULL DEFAULT 0, created_at_ms INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL
    );
    CREATE TABLE thread_goal_continuation_deferrals (
      thread_id TEXT PRIMARY KEY NOT NULL REFERENCES thread_goals(thread_id) ON DELETE CASCADE
    );
    """)
}

private func sqliteScalarForTest(_ database: URL, sql: String) throws -> String {
    let process = Process()
    let stdout = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [database.path, sql]
    process.standardOutput = stdout
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "CABDesktopTests", code: Int(process.terminationStatus))
    }
    return (String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
