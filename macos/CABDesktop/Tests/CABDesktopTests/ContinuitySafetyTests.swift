import CABContinuity
import Foundation
import Testing

struct ContinuitySafetyTests {
    @Test(arguments: [false, true])
    func refusesNestedCredentialsBeforeCopyingSkills(inTarget: Bool) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        for home in [source, target] {
            try fm.createDirectory(at: home.appendingPathComponent("skills/example"), withIntermediateDirectories: true)
        }
        let protected = (inTarget ? target : source).appendingPathComponent("skills/example/AUTH.JSON")
        try fm.createDirectory(at: protected, withIntermediateDirectories: false)
        #expect(throws: CodexContinuityError.self) {
            try CodexContinuityState.synchronize(sourceHome: source.path, targetHome: target.path, knownHomes: [])
        }
        #expect(fm.fileExists(atPath: protected.path))
        #expect(fm.fileExists(atPath: target.appendingPathComponent("skills/example/AUTH.JSON").path) == inTarget)
        if inTarget {
            #expect(try fm.contentsOfDirectory(atPath: target.path) == ["skills"])
        }
    }

    @Test func restorePreservesUnrelatedNeighborsAndCurrentDataWhenBackupIsMissing() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        for home in [source, target] {
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            try Data(home.lastPathComponent.utf8).write(to: home.appendingPathComponent("AGENTS.md"))
        }
        let neighbor = target.appendingPathComponent("AGENTS.md-wal")
        let current = target.appendingPathComponent("AGENTS.md")
        try Data("independent".utf8).write(to: neighbor)
        let result = try CodexContinuityState.synchronize(sourceHome: source.path, targetHome: target.path, knownHomes: [])
        try CodexContinuityState.restore(result)
        #expect(try Data(contentsOf: neighbor) == Data("independent".utf8))
        let backup = try #require(result.backups.first?.backupURL)
        try fm.removeItem(at: backup)
        #expect(throws: (any Error).self) { try CodexContinuityState.restore(result) }
        #expect(try Data(contentsOf: current) == Data("target".utf8))
    }

    @Test func sqliteDrainsLargeResultsAndRequiresACompletedCheckpoint() throws {
        let db = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: db) }
        let output = try ContinuitySQLite.run(db, sql: "SELECT hex(zeroblob(200000));")
        #expect(output.utf8.count == 400001)
        #expect(try ContinuitySQLite.readyForBackup(ContinuitySQLite.run(db, sql: ContinuitySQLite.checkpointSQL)))
        _ = try ContinuitySQLite.run(db, sql: "PRAGMA journal_mode=WAL; CREATE TABLE sample (id INTEGER);")
        #expect(try ContinuitySQLite.readyForBackup(ContinuitySQLite.run(db, sql: ContinuitySQLite.checkpointSQL)))
        #expect(!ContinuitySQLite.readyForBackup("5000\n1|8|4\nok\n"))
    }
}
