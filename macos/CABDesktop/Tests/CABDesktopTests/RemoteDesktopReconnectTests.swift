import Foundation
import AppKit
import SwiftUI
import Testing
@testable import CABDesktop

@MainActor
struct RemoteDesktopReconnectTests {
    @Test func renderRemoteAccountActionsWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["CAB_REMOTE_RECONNECT_RENDER_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let store = CABStore(desktopHome: { .notRunning })
        let server = RemoteServer(name: "oraclearm", host: "oraclearm")
        store.remoteServers = [server]; store.selectedRemoteID = server.id; store.target = .remote
        store.status = BridgeStatus(remoteAccount: "CKF", sharedSessions: true, rotation: RotationStatus(enabled: false), accounts: [
            AccountStatus(name: "CKF", home: "/accounts/CKF", login: "present", default: true, remote: true),
            AccountStatus(name: "Foxmail", home: "/accounts/Foxmail", login: "present", default: false, remote: false),
        ])
        for selected in ["CKF", "Foxmail"] {
            store.selectedAccount = selected
            for width in [900, 1100] {
                for dark in [false, true] {
                    let content = ContentView(performsLiveChecks: false).environmentObject(store)
                        .frame(width: CGFloat(width), height: 650)
                        .environment(\.colorScheme, dark ? .dark : .light).cabPreservingActiveColors()
                    let hosting = NSHostingView(rootView: content)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 650), styleMask: .borderless, backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = hosting; hosting.frame = window.contentLayoutRect
                    hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(selected)-\(width)-\(dark).png"))
                }
            }
        }
    }

    private func snapshot(_ connections: [RemoteDesktopConnection], fresh: Bool = false, checked: Bool = true) -> RemoteConnectionVerification {
        RemoteConnectionVerification(account: "work", home: "/work", freshConnectionVerified: fresh,
            otherAccountProcesses: 50, unknownProcesses: 0, processesChecked: true,
            desktopConnections: connections, desktopConnectionsChecked: checked)
    }
    private var old: RemoteDesktopConnection { .init(pid: 10, home: "/old") }
    private var correct: RemoteDesktopConnection { .init(pid: 20, home: "/work") }
    private var replacement: RemoteDesktopConnection { .init(pid: 30, home: "/work") }

    @Test func replacesOnlyConfirmedOldDesktopAndVerifiesReconnection() async throws {
        var stopped: [[Int]] = []
        var polls = 0
        let initial = snapshot([old, correct], fresh: true)
        let result = try await reconnectRemoteDesktops(accountName: "work", home: "/work", initial: initial,
            approvedPIDs: [10], stop: { stopped.append($0) }, inspect: {
                polls += 1
                return polls == 1 ? snapshot([correct]) : snapshot([correct, replacement])
            }, pause: {}, pollLimit: 2)
        #expect(stopped == [[10]])
        #expect(polls == 2)
        #expect(result.outcome == "桌面连接已验证")
        // Background agent stdio servers can intentionally keep another account.
        #expect(!result.needsReconnect && result.otherAccountProcesses == 50)
    }

    @Test func sameSavedAccountCanRepairAnExistingOldConnection() async throws {
        var stopped = false
        _ = try await reconnectRemoteDesktops(accountName: "work", home: "/work",
            initial: snapshot([old], fresh: true), approvedPIDs: [10], stop: { _ in stopped = true },
            inspect: { snapshot([replacement]) }, pause: {}, pollLimit: 0)
        #expect(stopped)
    }

    @Test func neverStopsUnconfirmedConnectionsOrUnverifiedTargets() async {
        let legacy = RemoteConnectionVerification(account: "work", home: "/work", freshConnectionVerified: true,
            otherAccountProcesses: 1, unknownProcesses: 0, processesChecked: true)
        for initial in [snapshot([old]), snapshot([old], fresh: true, checked: false), legacy, snapshot([.init(pid: 99, home: "/old")], fresh: true)] {
            do {
                _ = try await reconnectRemoteDesktops(accountName: "work", home: "/work", initial: initial,
                    approvedPIDs: [10], stop: { _ in Issue.record("Must not stop a process before all preconditions pass") },
                    inspect: { Issue.record("Must not poll after failed preflight"); return initial }, pause: {}, pollLimit: 0)
                Issue.record("Expected failed preflight")
            } catch { #expect(error is BridgeError) }
        }
    }

    @Test func disappearanceOrOldHomeReconnectionCannotCountAsSuccess() async {
        for connections in [[], [correct], [correct, .init(pid: 31, home: "/old")]] as [[RemoteDesktopConnection]] {
            var stops = 0
            do {
                _ = try await reconnectRemoteDesktops(accountName: "work", home: "/work",
                    initial: snapshot([old, correct], fresh: true), approvedPIDs: [10], stop: { _ in stops += 1 },
                    inspect: { snapshot(connections) }, pause: {}, pollLimit: 1)
                Issue.record("Missing or incorrectly routed replacements must not pass")
            } catch { #expect(error is BridgeError) }
            #expect(stops == 1)
        }
    }

    @Test func recoversOnlyFromStopErrorsWithVerifiedReplacement() async throws {
        let error = BridgeError.commandFailed("stop command disconnected")
        let result = try await reconnectRemoteDesktops(accountName: "work", home: "/work",
            initial: snapshot([old], fresh: true), approvedPIDs: [10], stop: { _ in throw error },
            inspect: { snapshot([replacement]) }, pause: {}, pollLimit: 0)
        #expect(result.outcome == "桌面连接已验证")
        do {
            _ = try await reconnectRemoteDesktops(accountName: "work", home: "/work",
                initial: snapshot([old], fresh: true), approvedPIDs: [10], stop: { _ in throw error },
                inspect: { snapshot([old]) }, pause: {}, pollLimit: 0)
            Issue.record("A remaining old process must preserve the stop failure")
        } catch { #expect(error.localizedDescription.contains("stop command disconnected")) }
    }

    @Test func noOldDesktopDoesNotDisconnectCorrectConnections() async throws {
        let result = try await reconnectRemoteDesktops(accountName: "work", home: "/work",
            initial: snapshot([correct], fresh: true), approvedPIDs: [], stop: { _ in Issue.record("Already correct") },
            inspect: { Issue.record("No reconnect required"); return snapshot([correct]) }, pause: {})
        #expect(result.outcome == "桌面连接已验证")
    }

    @Test func transientInspectionRaceIsRetriedWithoutStoppingAgain() async throws {
        var polls = 0
        let result = try await reconnectRemoteDesktops(accountName: "work", home: "/work",
            initial: snapshot([old], fresh: true), approvedPIDs: [10], stop: { _ in }, inspect: {
                polls += 1
                return snapshot([replacement], checked: polls > 1)
            }, pause: {}, pollLimit: 2)
        #expect(result.outcome == "桌面连接已验证" && polls == 2)
    }
}
