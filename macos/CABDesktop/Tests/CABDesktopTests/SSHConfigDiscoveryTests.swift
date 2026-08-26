import Foundation
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

    @Test func classifiesEditorCodexProcessesAndExcludesDesktopChildren() {
        let vscode = "/Users/test/.vscode/extensions/openai.chatgpt/bin/codex"
        let desktop = "/Applications/ChatGPT.app/Contents/Resources/codex"
        #expect(codexProcessLabel(executablePath: vscode) == "VS Code 的 Codex 扩展")
        #expect(!isCodexDesktopProcess(executablePath: vscode, desktopApplicationPath: "/Applications/ChatGPT.app"))
        #expect(isCodexDesktopProcess(executablePath: desktop, desktopApplicationPath: "/Applications/ChatGPT.app"))
        #expect(codexProcessLabel(executablePath: "/opt/homebrew/bin/codex") == "Codex CLI 或 app-server")
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

    @Test func preparesOfficialThreadCatalogRebuildWithBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("state_5.sqlite")
        try runSQLiteForTest(database, sql: "CREATE TABLE backfill_state (id INTEGER PRIMARY KEY, status TEXT NOT NULL); INSERT INTO backfill_state VALUES (1, 'complete');")

        let backup = try await CABService().prepareCodexThreadIndexRebuild(codexHome: root.path)

        #expect(backup != nil)
        #expect(FileManager.default.fileExists(atPath: backup?.path ?? ""))
        #expect(try sqliteScalarForTest(database, sql: "SELECT count(*) FROM backfill_state;") == "0")
        #expect(try sqliteScalarForTest(database, sql: "PRAGMA integrity_check;") == "ok")
    }

    @Test func synchronizesOnlyAllowlistedWorkspaceCatalogFields() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try #"{"local-projects":{"project-a":{"id":"project-a"}},"project-order":["project-a"],"thread-project-assignments":{"thread-a":{"projectId":"project-a"}},"selected-project":{"projectId":"project-a","type":"local"},"account-token":"must-not-copy","electron-persisted-atom-state":{"prompt-history":["private"]}}"#.write(
            to: source.appendingPathComponent(".codex-global-state.json"), atomically: true, encoding: .utf8
        )
        try #"{"local-projects":{"project-b":{"id":"project-b"}},"project-order":["project-b"],"account-token":"target-only","window-preference":42}"#.write(
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

        #expect(result.projectCount == 2)
        #expect(result.backupURL != nil)
        #expect(Set(projects.keys) == ["project-a", "project-b"])
        #expect(state["project-order"] as? [String] == ["project-a", "project-b"])
        #expect(state["account-token"] as? String == "target-only")
        #expect(state["electron-persisted-atom-state"] == nil)
        #expect(state["window-preference"] as? Int == 42)
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
        #expect(service.officialLoginURL(in: "https://auth.openai.com/oauth/authorize?redirect_uri=https%3A%2F%2Fevil.example%2Fcallback") == nil)
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
