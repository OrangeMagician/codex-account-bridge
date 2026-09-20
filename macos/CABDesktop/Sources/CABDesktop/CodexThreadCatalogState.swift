import Foundation

struct CodexThreadCatalogSyncResult {
    let targetURL: URL
    let backupURL: URL
    let rowCount: Int
}

enum CodexThreadCatalogState {
    private static let relativePath = "sqlite/codex-dev.db"
    private static let maximumDatabaseSize = 256 * 1_024 * 1_024
    private static let catalogColumns = [
        "host_id", "thread_id", "display_title", "source_created_at", "source_updated_at", "cwd",
        "source_kind", "source_detail", "model_provider", "git_branch", "observation_sequence",
        "missing_candidate", "thread_source", "source_recency_at", "pending_observed_title",
        "project_id", "conversation_origin",
    ]

    static func synchronize(
        sourceHome: String,
        targetHome: String,
        knownHomes: [String],
        fileManager: FileManager = .default
    ) throws -> CodexThreadCatalogSyncResult? {
        guard fileManager.isExecutableFile(atPath: "/usr/bin/sqlite3") else {
            throw BridgeError.commandFailed("系统缺少 /usr/bin/sqlite3，无法安全同步 Codex 会话目录。")
        }
        let targetHomeURL = URL(fileURLWithPath: targetHome, isDirectory: true).standardizedFileURL
        let targetURL = targetHomeURL.appendingPathComponent(relativePath).standardizedFileURL
        guard fileManager.fileExists(atPath: targetURL.path) else { return nil }
        try validateDatabase(targetURL, inside: targetHomeURL)
        try validateSchema(targetURL)

        var sourceHomes = uniqueHomes(knownHomes + [sourceHome])
        sourceHomes.removeAll { $0 == targetHomeURL.path }
        if let sourceIndex = sourceHomes.firstIndex(of: standardizedHome(sourceHome)) {
            let preferred = sourceHomes.remove(at: sourceIndex)
            sourceHomes.append(preferred)
        }
        var sourceURLs: [URL] = []
        for home in sourceHomes {
            let homeURL = URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL
            let databaseURL = homeURL.appendingPathComponent(relativePath).standardizedFileURL
            guard fileManager.fileExists(atPath: databaseURL.path) else { continue }
            try validateDatabase(databaseURL, inside: homeURL)
            try validateSchema(databaseURL)
            sourceURLs.append(databaseURL)
        }
        guard !sourceURLs.isEmpty else { return nil }

        let checked = try runSQLite(targetURL, sql: "PRAGMA busy_timeout=5000; PRAGMA wal_checkpoint(TRUNCATE); PRAGMA integrity_check;")
        guard checked.split(whereSeparator: \.isNewline).contains("ok") else {
            throw BridgeError.commandFailed("Codex 会话目录完整性检查失败，已停止切换。")
        }
        let backupURL = targetURL.deletingLastPathComponent().appendingPathComponent(
            "codex-dev.db.cab-backup-\(Int(Date().timeIntervalSince1970 * 1_000))"
        )
        try fileManager.copyItem(at: targetURL, to: backupURL)

        do {
            var sql = "PRAGMA busy_timeout=5000;"
            for (index, sourceURL) in sourceURLs.enumerated() {
                let alias = "cab_source_\(index)"
                sql += " ATTACH DATABASE '\(quoted(sourceURL.path))' AS \(alias);"
            }
            sql += " BEGIN IMMEDIATE;"
            for index in sourceURLs.indices {
                let alias = "cab_source_\(index)"
                sql += " INSERT OR IGNORE INTO main.local_thread_catalog_hosts (host_id, host_kind) SELECT host_id, host_kind FROM \(alias).local_thread_catalog_hosts;"
                sql += catalogMergeSQL(sourceAlias: alias)
            }
            sql += " UPDATE main.local_thread_catalog_metadata SET catalog_revision = catalog_revision + 1 WHERE id = 1; COMMIT;"
            for index in sourceURLs.indices { sql += " DETACH DATABASE cab_source_\(index);" }
            sql += " PRAGMA integrity_check;"
            let merged = try runSQLite(targetURL, sql: sql)
            guard merged.split(whereSeparator: \.isNewline).contains("ok") else {
                throw BridgeError.commandFailed("同步 Codex 会话目录后的完整性检查失败。")
            }
            let count = Int(try runSQLite(targetURL, sql: "SELECT count(*) FROM local_thread_catalog;").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return CodexThreadCatalogSyncResult(targetURL: targetURL, backupURL: backupURL, rowCount: count)
        } catch {
            try? restore(CodexThreadCatalogSyncResult(targetURL: targetURL, backupURL: backupURL, rowCount: 0))
            throw BridgeError.commandFailed("无法安全同步 Codex 会话目录；已尝试恢复原索引。\n\(error.localizedDescription)")
        }
    }

    // Compare source timestamps, never observation_sequence: it belongs to each local catalog.
    // On ties keep the destination stable. A useful title can repair a placeholder even
    // when its row is older, but a placeholder must never erase a useful title.
    private static func catalogMergeSQL(sourceAlias: String) -> String {
        let current = "local_thread_catalog"
        let newer = "(excluded.source_updated_at IS NOT NULL AND (\(current).source_updated_at IS NULL OR excluded.source_updated_at > \(current).source_updated_at))"
        func usefulTitle(_ row: String) -> String {
            "(trim(coalesce(\(row).display_title, '')) <> '' AND trim(\(row).display_title) <> trim(coalesce(\(row).cwd, '')))"
        }
        let takeTitle = "(\(usefulTitle("excluded")) AND (NOT \(usefulTitle(current)) OR \(newer)))"
        var updates = [
            "display_title = CASE WHEN \(takeTitle) THEN excluded.display_title ELSE \(current).display_title END",
        ]
        for column in ["source_updated_at", "source_recency_at"] {
            updates.append("\(column) = CASE WHEN \(current).\(column) IS NULL OR excluded.\(column) > \(current).\(column) THEN excluded.\(column) ELSE \(current).\(column) END")
        }
        for column in ["source_created_at", "cwd", "source_kind", "source_detail", "model_provider", "git_branch", "thread_source", "project_id", "conversation_origin"] {
            updates.append("\(column) = CASE WHEN \(newer) THEN excluded.\(column) ELSE \(current).\(column) END")
        }
        // Keep destination observation/missing/pending flags; another account's cache
        // cannot establish what this desktop has observed or which tasks disappeared.
        let columns = catalogColumns.joined(separator: ", ")
        return " INSERT INTO main.local_thread_catalog (\(columns)) SELECT \(columns) FROM \(sourceAlias).local_thread_catalog WHERE 1 ON CONFLICT(host_id, thread_id) DO UPDATE SET \(updates.joined(separator: ", "));"
    }

    static func restore(_ result: CodexThreadCatalogSyncResult, fileManager: FileManager = .default) throws {
        let backup = result.backupURL.standardizedFileURL
        let target = result.targetURL.standardizedFileURL
        guard backup.deletingLastPathComponent() == target.deletingLastPathComponent(),
              backup.lastPathComponent.hasPrefix("codex-dev.db.cab-backup-") else {
            throw BridgeError.commandFailed("拒绝从会话目录之外恢复 Codex 索引。")
        }
        try validateRegularFile(backup)
        let staged = target.deletingLastPathComponent().appendingPathComponent(".codex-dev.db.restore-\(UUID().uuidString)")
        try fileManager.copyItem(at: backup, to: staged)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: target.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) { try fileManager.removeItem(at: sidecar) }
        }
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        try fileManager.moveItem(at: staged, to: target)
    }

    private static func validateSchema(_ databaseURL: URL) throws {
        let columns = try runSQLite(databaseURL, sql: "SELECT name FROM pragma_table_info('local_thread_catalog') ORDER BY cid;")
            .split(whereSeparator: \.isNewline).map(String.init)
        guard Set(catalogColumns).isSubset(of: Set(columns)) else {
            throw BridgeError.commandFailed("Codex 会话目录结构不兼容，已停止切换。")
        }
        let tables = try runSQLite(databaseURL, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('local_thread_catalog_hosts','local_thread_catalog_metadata');")
        guard tables.contains("local_thread_catalog_hosts"), tables.contains("local_thread_catalog_metadata") else {
            throw BridgeError.commandFailed("Codex 会话目录缺少必要表，已停止切换。")
        }
    }

    private static func validateDatabase(_ url: URL, inside homeURL: URL) throws {
        guard url.path.hasPrefix(homeURL.path + "/") else {
            throw BridgeError.commandFailed("拒绝读取账号目录之外的 Codex 会话目录。")
        }
        try validateRegularFile(url)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumDatabaseSize else {
            throw BridgeError.commandFailed("Codex 会话目录超过安全大小限制，已停止切换。")
        }
    }

    private static func validateRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw BridgeError.commandFailed("拒绝读取非普通文件或符号链接形式的 Codex 会话目录。")
        }
    }

    private static func runSQLite(_ databaseURL: URL, sql: String) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-batch", "-bail", databaseURL.path, sql]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "sqlite3 failed"
            throw BridgeError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private static func quoted(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "''") }
    private static func standardizedHome(_ home: String) -> String {
        URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL.path
    }
    private static func uniqueHomes(_ homes: [String]) -> [String] {
        var seen = Set<String>()
        return homes.compactMap {
            let home = standardizedHome($0)
            return seen.insert(home).inserted ? home : nil
        }
    }
}
