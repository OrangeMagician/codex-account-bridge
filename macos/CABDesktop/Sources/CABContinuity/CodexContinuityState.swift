import Foundation

public struct CodexContinuityBackup {
    public let targetURL: URL
    public let backupURL: URL?
    public let targetPreviouslyExisted: Bool
}

public struct CodexContinuitySyncResult {
    public let backups: [CodexContinuityBackup]
    public let fileCount: Int
    public let databaseCount: Int
}

public enum CodexContinuityError: LocalizedError {
    case failure(String)

    public var errorDescription: String? {
        guard case let .failure(message) = self else { return nil }
        return message
    }
}

public enum CodexContinuityState {
    private static let portableDirectories = [
        "attachments",
        "generated_images",
        "visualizations",
        "prompts",
        "skills",
        "rules",
        "memories",
        "vendor_imports",
    ]
    private static let portableFiles = ["AGENTS.md"]
    private static let mergedLineFiles = ["history.jsonl", "session_index.jsonl", "transcription-history.jsonl"]
    // Git's fsmonitor daemon creates this Unix-domain socket inside a
    // repository. It is a process-local endpoint, not portable workspace
    // state, and attempting to copy it would make an otherwise valid switch
    // fail (or revive a stale socket for another process).
    private static let transientSocketNames = Set(["fsmonitor--daemon.ipc"])
    private static let maximumFileCount = 100_000
    private static let maximumTotalBytes: Int64 = 1_024 * 1_024 * 1_024
    private static let maximumDatabaseSize = 1_024 * 1_024 * 1_024

    private struct SyncAccumulator {
        var backups: [CodexContinuityBackup] = []
        var fileCount = 0
        var databaseCount = 0

        var result: CodexContinuitySyncResult {
            CodexContinuitySyncResult(backups: backups, fileCount: fileCount, databaseCount: databaseCount)
        }
    }

    public static func synchronize(
        sourceHome: String,
        targetHome: String,
        knownHomes: [String],
        fileManager: FileManager = .default
    ) throws -> CodexContinuitySyncResult {
        let targetHomeURL = URL(fileURLWithPath: targetHome, isDirectory: true).standardizedFileURL
        let sourceHomes = preferredSourceHomes(sourceHome: sourceHome, targetHome: targetHome, knownHomes: knownHomes)
        var accumulator = SyncAccumulator()
        let stamp = Int(Date().timeIntervalSince1970 * 1_000)

        do {
            try synchronizeDirectories(sourceHomes: sourceHomes, targetHomeURL: targetHomeURL, stamp: stamp, fileManager: fileManager, accumulator: &accumulator)
            try synchronizePortableFiles(sourceHomes: sourceHomes, targetHomeURL: targetHomeURL, stamp: stamp, fileManager: fileManager, accumulator: &accumulator)
            try synchronizeLineFiles(sourceHomes: sourceHomes, targetHomeURL: targetHomeURL, stamp: stamp, fileManager: fileManager, accumulator: &accumulator)
            try synchronizeDatabases(sourceHomes: sourceHomes, targetHomeURL: targetHomeURL, stamp: stamp, fileManager: fileManager, accumulator: &accumulator)
        } catch {
            do {
                try restore(accumulator.result, fileManager: fileManager)
            } catch let restoreError {
                throw CodexContinuityError.failure("无法同步完整工作区，且自动恢复失败。\n\(error.localizedDescription)\n恢复错误：\(restoreError.localizedDescription)")
            }
            throw CodexContinuityError.failure("无法同步完整工作区；已恢复目标账号原状态。\n\(error.localizedDescription)")
        }

        return accumulator.result
    }

    private static func synchronizeDirectories(
        sourceHomes: [String], targetHomeURL: URL, stamp: Int, fileManager: FileManager,
        accumulator: inout SyncAccumulator
    ) throws {
        for relativePath in portableDirectories {
            let sources = existingItems(relativePath, homes: sourceHomes, fileManager: fileManager)
            guard !sources.isEmpty else { continue }
            let targetURL = targetHomeURL.appendingPathComponent(relativePath).standardizedFileURL
            accumulator.backups.append(try backupItem(targetURL, stamp: stamp, fileManager: fileManager))
            accumulator.fileCount += try mergeDirectories(sources, into: targetURL, fileManager: fileManager)
        }
    }

    private static func synchronizePortableFiles(
        sourceHomes: [String], targetHomeURL: URL, stamp: Int, fileManager: FileManager,
        accumulator: inout SyncAccumulator
    ) throws {
        for relativePath in portableFiles {
            guard let preferred = existingItems(relativePath, homes: sourceHomes, fileManager: fileManager).last else { continue }
            try validatePortableFile(preferred)
            let targetURL = targetHomeURL.appendingPathComponent(relativePath).standardizedFileURL
            accumulator.backups.append(try backupItem(targetURL, stamp: stamp, fileManager: fileManager))
            try replaceFile(from: preferred, to: targetURL, fileManager: fileManager)
            accumulator.fileCount += 1
        }
    }

    private static func synchronizeLineFiles(
        sourceHomes: [String], targetHomeURL: URL, stamp: Int, fileManager: FileManager,
        accumulator: inout SyncAccumulator
    ) throws {
        for relativePath in mergedLineFiles {
            let targetURL = targetHomeURL.appendingPathComponent(relativePath).standardizedFileURL
            var sources = fileManager.fileExists(atPath: targetURL.path) ? [targetURL] : []
            sources.append(contentsOf: existingItems(relativePath, homes: sourceHomes, fileManager: fileManager))
            guard !sources.isEmpty else { continue }
            accumulator.backups.append(try backupItem(targetURL, stamp: stamp, fileManager: fileManager))
            try mergeLineFiles(sources, into: targetURL, fileManager: fileManager)
            accumulator.fileCount += 1
        }
    }

    private static func synchronizeDatabases(
        sourceHomes: [String], targetHomeURL: URL, stamp: Int, fileManager: FileManager,
        accumulator: inout SyncAccumulator
    ) throws {
        for specification in databaseSpecifications {
            guard let backup = try mergeDatabase(specification, sourceHomes: sourceHomes, targetHomeURL: targetHomeURL, stamp: stamp, fileManager: fileManager) else { continue }
            accumulator.backups.append(backup)
            accumulator.databaseCount += 1
        }
    }

    private static func existingItems(_ relativePath: String, homes: [String], fileManager: FileManager) -> [URL] {
        var result: [URL] = []
        for home in homes {
            let url = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(relativePath).standardizedFileURL
            if fileManager.fileExists(atPath: url.path) { result.append(url) }
        }
        return result
    }

    public static func restore(_ result: CodexContinuitySyncResult, fileManager: FileManager = .default) throws {
        for backup in result.backups.reversed() {
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: backup.targetURL.path + suffix)
                if fileManager.fileExists(atPath: sidecar.path) { try fileManager.removeItem(at: sidecar) }
            }
            if fileManager.fileExists(atPath: backup.targetURL.path) {
                try fileManager.removeItem(at: backup.targetURL)
            }
            if let backupURL = backup.backupURL {
                try fileManager.copyItem(at: backupURL, to: backup.targetURL)
            } else if backup.targetPreviouslyExisted {
                throw CodexContinuityError.failure("完整工作区备份缺失：\(backup.targetURL.lastPathComponent)")
            }
        }
    }

    private struct DatabaseSpecification {
        let relativePath: String
        let requiredColumns: [String: [String]]
    }

    private static var databaseSpecifications: [DatabaseSpecification] {
        [threadHistorySpecification(), goalsSpecification(), memoriesSpecification(), queueSpecification(), stateSpecification()]
    }

    private static func threadHistorySpecification() -> DatabaseSpecification {
        DatabaseSpecification(
            relativePath: "thread_history_1.sqlite",
            requiredColumns: [
                "thread_history_projection_state": ["thread_id", "next_rollout_byte_offset", "next_rollout_ordinal"],
                "thread_items": ["thread_id", "turn_id", "item_id", "rollout_ordinal", "created_at_ms", "item_json", "item_type", "updated_at_ordinal"],
                "thread_realtime_items": ["thread_id", "item_id", "rollout_ordinal", "created_at_ms", "item_type", "item_json"],
                "thread_turns": ["thread_id", "turn_id", "rollout_ordinal", "status", "error_json", "started_at", "completed_at", "duration_ms", "first_user_item_id", "final_agent_item_id", "rollout_byte_offset", "rollout_end_ordinal", "rollout_end_byte_offset"],
            ]
        )
    }

    private static func goalsSpecification() -> DatabaseSpecification {
        DatabaseSpecification(
            relativePath: "goals_1.sqlite",
            requiredColumns: [
                "thread_goals": ["thread_id", "goal_id", "objective", "status", "token_budget", "tokens_used", "time_used_seconds", "created_at_ms", "updated_at_ms"],
                "thread_goal_continuation_deferrals": ["thread_id"],
            ]
        )
    }

    private static func memoriesSpecification() -> DatabaseSpecification {
        DatabaseSpecification(
            relativePath: "memories_1.sqlite",
            requiredColumns: [
                "stage1_outputs": ["thread_id", "source_updated_at", "raw_memory", "rollout_summary", "rollout_slug", "generated_at", "usage_count", "last_usage", "selected_for_phase2", "selected_for_phase2_source_updated_at"],
            ]
        )
    }

    private static func queueSpecification() -> DatabaseSpecification {
        DatabaseSpecification(
            relativePath: "queue_1.sqlite",
            requiredColumns: [
                "queued_items": ["id", "thread_id", "payload_json", "queue_order", "created_at_ms", "updated_at_ms"],
                "queued_thread_revisions": ["revision", "thread_id"],
            ]
        )
    }

    private static func stateSpecification() -> DatabaseSpecification {
        DatabaseSpecification(
            relativePath: "state_5.sqlite",
            requiredColumns: [
                "projects": ["id", "name", "metadata", "position", "created_at_ms", "updated_at_ms"],
                "project_roots": ["project_id", "position", "path"],
                "thread_sections": ["id", "name", "appearance"],
                "threads": ["id", "rollout_path", "created_at", "updated_at", "source", "model_provider", "cwd", "title", "sandbox_policy", "approval_mode", "tokens_used", "has_user_event", "archived", "archived_at", "git_sha", "git_branch", "git_origin_url", "cli_version", "first_user_message", "agent_nickname", "agent_role", "memory_mode", "model", "reasoning_effort", "agent_path", "created_at_ms", "updated_at_ms", "thread_source", "preview", "recency_at", "recency_at_ms", "history_mode", "name", "is_pinned", "thread_section_id", "section_position", "section_entered_at_ms", "project_id"],
                "thread_dynamic_tools": ["thread_id", "position", "name", "description", "input_schema", "defer_loading", "namespace"],
                "thread_artifacts": ["id", "thread_id", "artifact_type", "identity_key", "payload", "created_at"],
                "thread_spawn_edges": ["parent_thread_id", "child_thread_id", "status"],
            ]
        )
    }

    private static func mergeDatabase(
        _ specification: DatabaseSpecification,
        sourceHomes: [String],
        targetHomeURL: URL,
        stamp: Int,
        fileManager: FileManager
    ) throws -> CodexContinuityBackup? {
        guard fileManager.isExecutableFile(atPath: "/usr/bin/sqlite3") else {
            throw CodexContinuityError.failure("系统缺少 /usr/bin/sqlite3，无法安全同步完整工作区。")
        }
        let targetURL = targetHomeURL.appendingPathComponent(specification.relativePath).standardizedFileURL
        guard fileManager.fileExists(atPath: targetURL.path) else { return nil }
        try validateDatabase(targetURL, requiredColumns: specification.requiredColumns)
        let sources = try sourceHomes.compactMap { home -> URL? in
            let homeURL = URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL
            let url = homeURL.appendingPathComponent(specification.relativePath).standardizedFileURL
            guard fileManager.fileExists(atPath: url.path), url != targetURL else { return nil }
            try validateDatabase(url, requiredColumns: specification.requiredColumns)
            return url
        }
        guard !sources.isEmpty else { return nil }

        let checked = try runSQLite(targetURL, sql: "PRAGMA busy_timeout=5000; PRAGMA wal_checkpoint(TRUNCATE); PRAGMA integrity_check;")
        guard checked.split(whereSeparator: \.isNewline).contains("ok") else {
            throw CodexContinuityError.failure("\(specification.relativePath) 完整性检查失败，已停止切换。")
        }
        let backup = try backupItem(targetURL, stamp: stamp, fileManager: fileManager)
        do {
            var sql = "PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON;"
            for (index, source) in sources.enumerated() {
                sql += " ATTACH DATABASE '\(quoted(source.path))' AS cab_source_\(index);"
            }
            sql += " BEGIN IMMEDIATE;"
            for index in sources.indices {
                for statement in mergeStatements(for: specification, alias: "cab_source_\(index)") {
                    sql += " \(statement);"
                }
            }
            sql += " COMMIT;"
            for index in sources.indices { sql += " DETACH DATABASE cab_source_\(index);" }
            sql += " PRAGMA integrity_check;"
            let merged = try runSQLite(targetURL, sql: sql)
            guard merged.split(whereSeparator: \.isNewline).contains("ok") else {
                throw CodexContinuityError.failure("\(specification.relativePath) 同步后完整性检查失败。")
            }
            return backup
        } catch {
            try restore(CodexContinuitySyncResult(backups: [backup], fileCount: 0, databaseCount: 0), fileManager: fileManager)
            throw error
        }
    }

    private static func mergeStatements(for specification: DatabaseSpecification, alias: String) -> [String] {
        func copy(_ table: String, conflict: String = "REPLACE") -> String {
            let columns = specification.requiredColumns[table] ?? []
            let list = columns.joined(separator: ", ")
            return "INSERT OR \(conflict) INTO main.\(table) (\(list)) SELECT \(list) FROM \(alias).\(table)"
        }

        switch specification.relativePath {
        case "thread_history_1.sqlite":
            return [
                copy("thread_history_projection_state"),
                copy("thread_items"),
                copy("thread_realtime_items"),
                copy("thread_turns"),
            ]
        case "goals_1.sqlite":
            return [copy("thread_goals"), copy("thread_goal_continuation_deferrals", conflict: "IGNORE")]
        case "memories_1.sqlite":
            return [copy("stage1_outputs")]
        case "queue_1.sqlite":
            return [
                copy("queued_items"),
                "INSERT OR IGNORE INTO main.queued_thread_revisions (thread_id) SELECT thread_id FROM \(alias).queued_thread_revisions",
            ]
        case "state_5.sqlite":
            return [
                copy("projects", conflict: "IGNORE"),
                copy("project_roots"),
                copy("thread_sections", conflict: "IGNORE"),
                copy("threads", conflict: "IGNORE"),
                copy("thread_dynamic_tools"),
                copy("thread_artifacts"),
                copy("thread_spawn_edges"),
            ]
        default:
            return []
        }
    }

    private static func validateDatabase(_ url: URL, requiredColumns: [String: [String]]) throws {
        try validatePortableFile(url)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumDatabaseSize else {
            throw CodexContinuityError.failure("\(url.lastPathComponent) 超过安全大小限制，已停止切换。")
        }
        for (table, expectedColumns) in requiredColumns {
            let columns = try runSQLite(url, sql: "SELECT name FROM pragma_table_info('\(quoted(table))') ORDER BY cid;")
                .split(whereSeparator: \.isNewline).map(String.init)
            guard Set(expectedColumns).isSubset(of: Set(columns)) else {
                throw CodexContinuityError.failure("\(url.lastPathComponent) 的 \(table) 结构不兼容，已停止切换。")
            }
        }
    }

    private static func mergeDirectories(_ sources: [URL], into targetURL: URL, fileManager: FileManager) throws -> Int {
        let staging = targetURL.deletingLastPathComponent().appendingPathComponent(".\(targetURL.lastPathComponent).cab-stage-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var totalCount = 0
        var totalBytes: Int64 = 0
        do {
            if fileManager.fileExists(atPath: targetURL.path) {
                try mergeDirectory(from: targetURL, into: staging, fileCount: &totalCount, totalBytes: &totalBytes, fileManager: fileManager)
            }
            for source in sources where source != targetURL {
                try mergeDirectory(from: source, into: staging, fileCount: &totalCount, totalBytes: &totalBytes, fileManager: fileManager)
            }
            if fileManager.fileExists(atPath: targetURL.path) { try fileManager.removeItem(at: targetURL) }
            try fileManager.moveItem(at: staging, to: targetURL)
            return totalCount
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private static func mergeDirectory(
        from source: URL,
        into destination: URL,
        fileCount: inout Int,
        totalBytes: inout Int64,
        fileManager: FileManager
    ) throws {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CodexContinuityError.failure("拒绝同步非目录或符号链接形式的工作区内容。\n来源目录：\(source.path)")
        }
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else { return }
        while let item = enumerator.nextObject() as? URL {
            if shouldSkipTransientGitItem(item) {
                continue
            }
            let itemValues = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard itemValues.isSymbolicLink != true else {
                throw CodexContinuityError.failure("工作区内容包含符号链接。\n来源目录：\(source.path)\n未同步文件：\(item.path)")
            }
            let resolvedSourcePath = source.resolvingSymlinksInPath().path
            let resolvedItemPath = item.resolvingSymlinksInPath().path
            let relative = resolvedItemPath.replacingOccurrences(of: resolvedSourcePath + "/", with: "", options: [.anchored])
            guard !relative.isEmpty, relative != resolvedItemPath, !relative.hasPrefix("/") else {
                throw CodexContinuityError.failure("无法确定工作区内容的安全相对路径。\n来源目录：\(source.path)\n未同步文件：\(item.path)")
            }
            let target = destination.appendingPathComponent(relative)
            if itemValues.isDirectory == true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            } else if itemValues.isRegularFile == true {
                fileCount += 1
                totalBytes += Int64(itemValues.fileSize ?? 0)
                guard fileCount <= maximumFileCount, totalBytes <= maximumTotalBytes else {
                    throw CodexContinuityError.failure("工作区内容超过安全数量或大小限制。\n来源目录：\(source.path)\n停止位置：\(item.path)")
                }
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                do {
                    try fileManager.copyItem(at: item, to: target)
                } catch {
                    throw CodexContinuityError.failure(
                        "复制工作区文件失败。\n来源目录：\(source.path)\n未同步文件：\(item.path)\n目标位置：\(target.path)\n原因：\(error.localizedDescription)"
                    )
                }
            } else {
                throw CodexContinuityError.failure("工作区内容包含不支持的特殊文件。\n来源目录：\(source.path)\n未同步文件：\(item.path)")
            }
        }
    }

    private static func shouldSkipTransientGitItem(_ url: URL) -> Bool {
        guard transientSocketNames.contains(url.lastPathComponent) else { return false }
        return url.pathComponents.contains(".git")
    }

    private static func mergeLineFiles(_ sources: [URL], into targetURL: URL, fileManager: FileManager) throws {
        var lines: [String] = []
        var seen = Set<String>()
        for source in sources {
            try validatePortableFile(source)
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            guard data.count <= 64 * 1_024 * 1_024 else {
                throw CodexContinuityError.failure("\(source.lastPathComponent) 超过安全大小限制，已停止切换。")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw CodexContinuityError.failure("\(source.lastPathComponent) 不是有效 UTF-8，已停止切换。")
            }
            for line in text.split(whereSeparator: \.isNewline).map(String.init) where seen.insert(line).inserted {
                lines.append(line)
            }
        }
        let encoded = Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8)
        try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: targetURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
    }

    private static func backupItem(_ targetURL: URL, stamp: Int, fileManager: FileManager) throws -> CodexContinuityBackup {
        let existed = fileManager.fileExists(atPath: targetURL.path)
        guard existed else {
            return CodexContinuityBackup(targetURL: targetURL, backupURL: nil, targetPreviouslyExisted: false)
        }
        let backupURL = targetURL.deletingLastPathComponent().appendingPathComponent("\(targetURL.lastPathComponent).cab-backup-\(stamp)-\(UUID().uuidString)")
        try fileManager.copyItem(at: targetURL, to: backupURL)
        return CodexContinuityBackup(targetURL: targetURL, backupURL: backupURL, targetPreviouslyExisted: true)
    }

    private static func replaceFile(from source: URL, to target: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).cab-stage-\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: staging)
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        try fileManager.moveItem(at: staging, to: target)
    }

    private static func validatePortableFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CodexContinuityError.failure("拒绝同步非普通文件或符号链接形式的工作区内容。\n未同步文件：\(url.path)")
        }
    }

    private static func preferredSourceHomes(sourceHome: String, targetHome: String, knownHomes: [String]) -> [String] {
        let target = standardizedHome(targetHome)
        let source = standardizedHome(sourceHome)
        var homes = uniqueHomes(knownHomes).filter { $0 != target && $0 != source }
        homes.append(source)
        return homes
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
            throw CodexContinuityError.failure(message.trimmingCharacters(in: .whitespacesAndNewlines))
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
