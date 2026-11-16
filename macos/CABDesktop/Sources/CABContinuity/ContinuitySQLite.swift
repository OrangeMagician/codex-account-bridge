import Foundation

public enum ContinuitySQLite {
    public static let checkpointSQL = "PRAGMA busy_timeout=5000; PRAGMA wal_checkpoint(TRUNCATE); PRAGMA integrity_check;"

    public static func readyForBackup(_ output: String) -> Bool {
        let lines = output.split(whereSeparator: \.isNewline)
        // A busy checkpoint also exits successfully and can be followed by "ok".
        // Only a truncated WAL or a non-WAL database is safe to copy on its own.
        return lines == ["5000", "0|0|0", "ok"] || lines == ["5000", "0|-1|-1", "ok"]
    }

    public static func run(_ databaseURL: URL, sql: String) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-batch", "-bail", databaseURL.path, sql]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CodexContinuityError.failure(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
