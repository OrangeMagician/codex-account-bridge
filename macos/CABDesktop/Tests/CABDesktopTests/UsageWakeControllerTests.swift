import Foundation
import Testing
@testable import CABDesktop

@MainActor
struct UsageWakeControllerTests {
    @Test(arguments: ["confirmed", "no_countdown", "failure", "nearby_reset", "no_five_hour", "exhausted", "long_countdown"])
    func realControllerMakesOneRequestAndPersistsItsVerifiedOutcome(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "fixture-" + UUID().uuidString
        let executable = root.appendingPathComponent("cab")
        let quotedName = String(data: try JSONEncoder().encode(name), encoding: .utf8)!
        let quotedMode = String(data: try JSONEncoder().encode(mode), encoding: .utf8)!
        let script = """
        #!/usr/bin/python3
        import sys,json,time,pathlib,datetime
        root=pathlib.Path(__file__).parent
        args=sys.argv[1:]
        name=\(quotedName)
        mode=\(quotedMode)
        calls=root/'calls'
        if args[0]=='status':
            print(json.dumps({'shared_sessions':False,'rotation':{'enabled':False},'accounts':[{'name':name,'home':str(root),'login':'present','default':False,'remote':False}]}))
        elif args[:2]==['usage','probe']:
            with calls.open('a') as f:f.write('x')
            if mode=='failure':
                print('codex usage probe failed: rate_limited',file=sys.stderr)
                sys.exit(1)
        elif args[0]=='usage':
            active=calls.exists() and mode in ['confirmed','nearby_reset']
            initial=root/'initial_reset'
            if not initial.exists():initial.write_text(str(int(time.time())+(3 if mode=='nearby_reset' else 14400 if mode=='long_countdown' else -1)))
            initial_reset=int(initial.read_text())
            limits={'primary':{'used_percent':1 if active else 100,'window_duration_mins':300,'resets_at':int(time.time())+18000 if active or mode=='exhausted' else initial_reset},'secondary':{'used_percent':10,'window_duration_mins':10080,'resets_at':int(time.time())+86400}}
            if not active:limits['rate_limit_reached_type']='rate_limit_reached'
            if mode=='no_five_hour':
                del limits['primary']
                del limits['rate_limit_reached_type']
            print(json.dumps({'fetched_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'accounts':[{'name':name,'usage':{'rate_limits':limits}}]}))
        else:sys.exit(2)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let store = CABStore(service: CABService(executable: executable))
        store.usageWakeJournal = UsageWakeJournal(url: root.appendingPathComponent("events.jsonl"))
        store.usageWakeSettings.enabled = true
        let endpoint = UsageWakeEndpoint(key: name, target: .local, host: "")
        let date = Date()
        let slot = UsageTimeOfDay(date: date)
        await store.runScheduledUsageWake(slot: slot, scheduledAt: date, endpoint: endpoint)
        if mode == "nearby_reset" {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("calls").path))
            #expect(store.usageWakeState.scheduledWaitsByAccount?[name + "|" + name] != nil)
            let later = date.addingTimeInterval(60)
            await store.runScheduledUsageWake(slot: UsageTimeOfDay(date: later), scheduledAt: later, endpoint: endpoint)
            try await Task.sleep(nanoseconds: 4_000_000_000)
            await store.runScheduledUsageWake(slot: slot, scheduledAt: date, endpoint: endpoint)
        }
        await store.runScheduledUsageWake(slot: slot, scheduledAt: date, endpoint: endpoint)
        if mode == "nearby_reset" {
            let later = date.addingTimeInterval(60)
            await store.runScheduledUsageWake(slot: UsageTimeOfDay(date: later), scheduledAt: later, endpoint: endpoint)
            #expect(store.usageWakeState.scheduledWaitsByAccount?[name + "|" + name] == nil)
        }
        if mode == "no_five_hour" || mode == "exhausted" || mode == "long_countdown" {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("calls").path))
        } else {
            #expect(try String(contentsOf: root.appendingPathComponent("calls")) == "x")
        }
        if mode == "confirmed" || mode == "nearby_reset" {
            let displayed = store.usageCacheByKey[name]?.reports[name]
            #expect(usageWakeDecision(report: displayed) == .fiveHourActive)
        }
        let log = try String(contentsOf: store.usageWakeJournal.url)
        switch mode {
        case "confirmed", "nearby_reset": #expect(log.contains("five_hour_confirmed"))
        case "no_five_hour": #expect(log.contains("noFiveHourLimit"))
        case "exhausted": #expect(log.contains("fiveHourExhausted") && log.contains("waiting_for_current_five_hour_reset"))
        case "long_countdown": #expect(log.contains("waiting_for_current_five_hour_reset"))
        case "no_countdown": #expect(log.contains("five_hour_not_started"))
        default: #expect(log.contains("request_failed") && log.contains("rate_limited"))
        }
        if mode == "long_countdown" || mode == "exhausted" {
            let pending = try #require(store.usageWakeState.scheduledWaitsByAccount?[name + "|" + name])
            #expect(pending.resetAt.timeIntervalSince(date) > 3 * 3600)
            let later = date.addingTimeInterval(60)
            let laterSlot = UsageTimeOfDay(date: later)
            await store.runScheduledUsageWake(slot: laterSlot, scheduledAt: later, endpoint: endpoint)
            let merged = try #require(store.usageWakeState.scheduledWaitsByAccount?[name + "|" + name])
            #expect(merged.scheduledAt == pending.scheduledAt)
            #expect(merged.completionSlotID == usageScheduledProbeSlotIdentifier(at: later, time: laterSlot))
        }
        if mode != "no_five_hour" { #expect(log.contains("rate_limit_reached")) } // the exact initial snapshot survives
    }
}
