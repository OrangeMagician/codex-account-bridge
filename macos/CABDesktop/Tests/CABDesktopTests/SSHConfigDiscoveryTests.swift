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
