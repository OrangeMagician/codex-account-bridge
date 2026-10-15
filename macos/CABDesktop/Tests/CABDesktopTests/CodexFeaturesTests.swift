import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CABDesktop

private func featureCatalog() throws -> AccountModelCatalog {
    let json = #"{"models":[{"id":"sol","model":"gpt-6.1-sol","displayName":"GPT-6.1 Sol","description":"Near-Astra performance for complex work","isDefault":true,"defaultReasoningEffort":"medium","supportedReasoningEfforts":[{"reasoningEffort":"medium","description":"Balanced"},{"reasoningEffort":"high","description":"Deep"}],"serviceTiers":[{"id":"priority","name":"Fast","description":"Faster"},{"id":"ultrafast","name":"Ultrafast","description":"Fastest"}]}],"fetched_at":"2026-10-13T00:00:00Z","scope":"selected_account_catalog_not_verified_entitlement"}"#
    let decoder = CABService().cabDateDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(AccountModelCatalog.self, from: Data(json.utf8))
}

@Suite("Codex catalogs and launch presets")
struct CodexFeaturesTests {
    @Test func oldProfilesDecodeWithOfficialDefaults() throws {
        let data = Data(#"{"id":"8c43ee19-e8b6-4ce2-b2e0-9b53aebff312","name":"App","directory":"/project","account":"work","remoteHost":""}"#.utf8)
        let profile = try JSONDecoder().decode(ProjectLaunchProfile.self, from: data)
        #expect(profile.preset == nil)
        #expect((profile.preset ?? LaunchPreset()).arguments.isEmpty)
        #expect(retirementNotice("gpt-5.5") != nil)
    }

    @Test func catalogRestrictsEffortsAndMapsPriorityToFast() throws {
        let catalog = try featureCatalog()
        #expect(catalog.models[0].advertisedSpeeds == ["fast", "ultrafast"])
        try LaunchPreset(model: "gpt-6.1-sol", effort: "high", speed: "fast").validate(catalog: catalog)
        #expect(throws: (any Error).self) { try LaunchPreset(model: "retired").validate(catalog: catalog) }
        #expect(throws: (any Error).self) { try LaunchPreset(speed: "fast").validate(catalog: catalog) }
        #expect(throws: (any Error).self) { try LaunchPreset(model: "gpt-6.1-sol", effort: "ultra").validate(catalog: catalog) }
        #expect(speedCostNotice("ultrafast") != nil)
    }

    @Test func launchQuotesEveryPresetAndResumeArgument() throws {
        let command = try codexRunTerminalCommand(target: .remote, remoteHost: "server", cabExecutablePath: nil, realCodexPath: nil, accountName: "work", directory: "/project's $(name)", preset: LaunchPreset(model: "gpt-6.1-sol", effort: "high", speed: "fast"), resume: "thread-1")
        #expect(command.contains("--model") && command.contains("--effort") && command.contains("--speed") && command.contains("--resume"))
        #expect(!command.contains("dangerously") && !command.contains("sandbox") && !command.contains("approval"))
        #expect(throws: (any Error).self) { try codexRunTerminalCommand(target: .local, remoteHost: "", cabExecutablePath: "/cab", realCodexPath: nil, accountName: nil, preset: LaunchPreset(model: "gpt-6.1-sol")) }
        #expect(throws: (any Error).self) { try LaunchPreset(model: "--bypass").validateSyntax() }
        #expect(isReadOnlyCommand(["models", "--account", "work"]))
        #expect(!isReadOnlyCommand(["tasks", "pin", "--account", "work"]))
        #expect(!isReadOnlyCommand(["worktrees", "remove", "--account", "work"]))
    }

    @MainActor @Test func contextChangeClearsOtherAccountData() throws {
        let model = CodexFeaturesStore()
        model.changeContext("first")
        model.catalog = try featureCatalog()
        model.tasks = [StoredCodexTask(id: "task", name: "Work", cwd: "/project", updatedAt: 1, isPinned: true)]
        model.changeContext("second")
        #expect(model.catalog == nil && model.tasks.isEmpty && model.worktrees.isEmpty)
    }

    @MainActor @Test func renderCodexFeatureViews() throws {
        guard let path = ProcessInfo.processInfo.environment["CAB_FEATURE_RENDER_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let account = AccountStatus(name: "Work", home: "/accounts/work", login: "present", default: true, remote: false)
        let store = CABStore(); store.status.accounts = [account]
        let model = CodexFeaturesStore(); model.catalog = try featureCatalog()
        model.tasks = [StoredCodexTask(id: "thread-1", name: "Review background server account routing and preserve pending tasks", cwd: "/Users/example/Workspace/My/codex-account-bridge", updatedAt: 1_800_000_000, isPinned: true)]
        model.worktrees = [ManagedWorktree(id: "tree", account: "Work", repository: "/Users/example/project", path: "/Users/example/.local/share/codex-account-bridge/worktrees/0123456789abcdef0123456789abcdef", ref: "main", createdAt: Date(), exists: true)]
        func render<V: View>(_ content: V, name: String, width: Int, dark: Bool) throws {
            let view = content.padding(24).frame(width: CGFloat(width)).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light).cabPreservingActiveColors()
            _ = NSApplication.shared
            let hosting = NSHostingView(rootView: view); let size = hosting.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = hosting
            hosting.frame = NSRect(origin: .zero, size: size); hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path).appendingPathComponent("\(name)-\(width)-\(dark).png"))
        }
        for width in [620, 900] {
            for dark in [false, true] {
                for section in ["cab.models", "cab.tasks", "cab.worktrees"] {
                    try render(CodexFeaturesView(model: model, section: section, performsLiveChecks: false, initialAccount: "Work").environmentObject(store), name: section, width: width, dark: dark)
                }
                var profile = ProjectLaunchProfile(name: "App", directory: "/project", account: "Work", remoteHost: "")
                profile.preset = LaunchPreset(model: "gpt-6.1-sol", effort: "high", speed: "ultrafast")
                try render(ProjectProfileEditor(profile: profile, accounts: [account], save: { _ in }, performsLiveChecks: false), name: "preset-editor", width: width, dark: dark)
            }
        }
    }
}
