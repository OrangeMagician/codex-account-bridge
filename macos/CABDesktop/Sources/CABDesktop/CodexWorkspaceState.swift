import Foundation

struct CodexWorkspaceSyncResult {
    let targetURL: URL
    let backupURL: URL?
    let targetPreviouslyExisted: Bool
    let projectCount: Int
}

enum CodexWorkspaceState {
    private static let stateFileName = ".codex-global-state.json"
    private static let maximumStateFileSize = 16 * 1_024 * 1_024

    // These are the workspace catalog fields used by the official desktop app.
    // Account identity, plugin state, prompts, UI experiments, and other global
    // preferences are deliberately excluded.
    private static let mergedObjectKeys = [
        "local-projects",
        "thread-project-assignments",
        "thread-workspace-root-hints",
        "thread-projectless-output-directories",
        "thread-writable-roots",
    ]
    private static let orderedArrayKeys = [
        "electron-saved-workspace-roots",
        "project-order",
        "projectless-thread-ids",
    ]
    private static let selectedValueKeys = [
        "active-workspace-roots",
        "selected-project",
    ]

    static func synchronize(
        sourceHome: String,
        targetHome: String,
        knownHomes: [String],
        fileManager: FileManager = .default
    ) throws -> CodexWorkspaceSyncResult {
        let targetHomeURL = URL(fileURLWithPath: targetHome, isDirectory: true).standardizedFileURL
        let targetURL = targetHomeURL.appendingPathComponent(stateFileName)
        let orderedHomes = uniqueHomes([sourceHome, targetHome] + knownHomes)
        let states = try orderedHomes.compactMap { home -> [String: Any]? in
            let url = URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL.appendingPathComponent(stateFileName)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return try readObject(at: url, fileManager: fileManager)
        }

        let targetPreviouslyExisted = fileManager.fileExists(atPath: targetURL.path)
        var targetState = targetPreviouslyExisted
            ? try readObject(at: targetURL, fileManager: fileManager)
            : [:]

        for key in mergedObjectKeys {
            var merged: [String: Any] = [:]
            for state in states.reversed() {
                guard let object = state[key] as? [String: Any] else { continue }
                merged.merge(object) { _, preferred in preferred }
            }
            if !merged.isEmpty || targetState[key] != nil { targetState[key] = merged }
        }

        for key in orderedArrayKeys {
            var merged: [Any] = []
            var fingerprints = Set<Data>()
            for state in states {
                guard let values = state[key] as? [Any] else { continue }
                for value in values {
                    let fingerprint = try JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
                    if fingerprints.insert(fingerprint).inserted { merged.append(value) }
                }
            }
            if !merged.isEmpty || targetState[key] != nil { targetState[key] = merged }
        }

        for key in selectedValueKeys {
            if let value = states.compactMap({ meaningfulValue($0[key]) }).first {
                targetState[key] = value
            }
        }

        guard JSONSerialization.isValidJSONObject(targetState) else {
            throw BridgeError.commandFailed("Codex 项目状态包含无法安全写入的数据，已停止切换。")
        }
        let encoded = try JSONSerialization.data(withJSONObject: targetState, options: [.sortedKeys])
        guard encoded.count <= maximumStateFileSize else {
            throw BridgeError.commandFailed("Codex 项目状态超过安全大小限制，已停止切换。")
        }

        try fileManager.createDirectory(at: targetHomeURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backupURL: URL?
        if targetPreviouslyExisted {
            backupURL = targetHomeURL.appendingPathComponent("\(stateFileName).cab-backup-\(Int(Date().timeIntervalSince1970 * 1_000))")
            try fileManager.copyItem(at: targetURL, to: backupURL!)
        } else {
            backupURL = nil
        }
        do {
            try encoded.write(to: targetURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
        } catch {
            if let backupURL {
                try? fileManager.removeItem(at: targetURL)
                try? fileManager.copyItem(at: backupURL, to: targetURL)
            } else {
                try? fileManager.removeItem(at: targetURL)
            }
            throw BridgeError.commandFailed("无法安全写入 Codex 项目状态：\(error.localizedDescription)")
        }

        return CodexWorkspaceSyncResult(
            targetURL: targetURL,
            backupURL: backupURL,
            targetPreviouslyExisted: targetPreviouslyExisted,
            projectCount: (targetState["local-projects"] as? [String: Any])?.count ?? 0
        )
    }

    static func restore(_ result: CodexWorkspaceSyncResult, fileManager: FileManager = .default) throws {
        if let backupURL = result.backupURL {
            if fileManager.fileExists(atPath: result.targetURL.path) {
                try fileManager.removeItem(at: result.targetURL)
            }
            try fileManager.copyItem(at: backupURL, to: result.targetURL)
        } else if !result.targetPreviouslyExisted, fileManager.fileExists(atPath: result.targetURL.path) {
            try fileManager.removeItem(at: result.targetURL)
        }
    }

    private static func readObject(at url: URL, fileManager: FileManager) throws -> [String: Any] {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw BridgeError.commandFailed("拒绝读取非普通文件或符号链接形式的 Codex 项目状态。")
        }
        guard (values.fileSize ?? 0) <= maximumStateFileSize else {
            throw BridgeError.commandFailed("Codex 项目状态超过安全大小限制，已停止切换。")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.commandFailed("Codex 项目状态不是有效的 JSON 对象，已停止切换。")
        }
        return object
    }

    private static func meaningfulValue(_ value: Any?) -> Any? {
        switch value {
        case let array as [Any] where !array.isEmpty: return array
        case let object as [String: Any] where !object.isEmpty: return object
        case let string as String where !string.isEmpty: return string
        case let number as NSNumber: return number
        default: return nil
        }
    }

    private static func uniqueHomes(_ homes: [String]) -> [String] {
        var seen = Set<String>()
        return homes.compactMap {
            let path = URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
            return seen.insert(path).inserted ? path : nil
        }
    }
}
