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

    // These are portable workspace fields used by the official desktop app.
    // Account identity, plugin/OAuth state, device identifiers, and security
    // preferences remain account-local.
    private static let mergedObjectKeys = [
        "local-projects",
        "app-server-project-id-by-legacy-project-id-by-host",
        "app-server-projects-migration-by-host",
        "remote-connection-analytics-id-by-host-id",
        "remote-connection-auto-connect-by-host-id",
        "thread-project-assignments",
        "thread-workspace-root-hints",
        "thread-projectless-output-directories",
        "thread-writable-roots",
        "sidebar-project-thread-orders",
        "queued-follow-ups",
    ]
    private static let orderedArrayKeys = [
        "electron-saved-workspace-roots",
        "project-order",
        "projectless-thread-ids",
    ]
    private static let entityArrayKeys = [
        "codex-managed-remote-connections": "hostId",
        "remote-projects": "id",
    ]
    private static let entityAllowedFields = [
        "codex-managed-remote-connections": Set(["hostId", "displayName", "source", "alias", "hostname", "sshPort", "connectionAnalyticsId"]),
        "remote-projects": Set(["id", "hostId", "remotePath", "label"]),
    ]
    private static let selectedValueKeys = [
        "active-workspace-roots",
        "remote-project-connection-backfill-completed",
        "selected-project",
        "selected-remote-host-id",
    ]
    private static let portableAtomKeys = Set([
        "chatgpt-sidebar-state-v1",
        "client-thread-bindings-v1",
        "composer-auto-context-enabled",
        "composer-prompt-drafts-v1",
        "composer-prompt-drafts-v2",
        "composer-retained-documents-v1",
        "flat-project-sidebar-preferences-v1",
        "home-composer-mode-v1",
        "prompt-history",
        "remote-hosted-pip-hidden-thread-ids",
        "sidebar-custom-sections-v3",
        "sidebar-project-list-expanded-v1",
        "thread-descriptions-v1",
        "unread-thread-ids-by-host-v1",
    ])
    private static let portableAtomPrefixes = [
        "codex-writing-block-deleted-thread-v1:",
        "sidebar-project-expanded-v1-codex:",
        "thread-browser-tabs-v1:",
        "thread-client-id-v1:",
        "thread-reference-capability:",
        "thread-summary-panel-section-expanded-environment-",
        "thread-tab-routes-v1:",
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

        for (key, identityKey) in entityArrayKeys {
            var merged: [[String: Any]] = []
            var positions: [String: Int] = [:]
            let allowedFields = entityAllowedFields[key] ?? []
            for state in states.reversed() {
                guard let values = state[key] as? [[String: Any]] else { continue }
                for value in values {
                    guard let identity = value[identityKey] as? String, !identity.isEmpty else { continue }
                    let sanitized = value.filter { allowedFields.contains($0.key) }
                    if let position = positions[identity] {
                        merged[position] = sanitized
                    } else {
                        positions[identity] = merged.count
                        merged.append(sanitized)
                    }
                }
            }
            if !merged.isEmpty || targetState[key] != nil { targetState[key] = merged }
        }

        for key in selectedValueKeys {
            if let value = states.compactMap({ meaningfulValue($0[key]) }).first {
                targetState[key] = value
            }
        }

        var targetAtoms = targetState["electron-persisted-atom-state"] as? [String: Any] ?? [:]
        for state in states.reversed() {
            guard let atoms = state["electron-persisted-atom-state"] as? [String: Any] else { continue }
            for (key, value) in atoms where isPortableAtomKey(key) {
                targetAtoms[key] = mergePortableValue(current: targetAtoms[key], preferred: value)
            }
        }
        if !targetAtoms.isEmpty || targetState["electron-persisted-atom-state"] != nil {
            targetState["electron-persisted-atom-state"] = targetAtoms
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
            projectCount: ((targetState["local-projects"] as? [String: Any])?.count ?? 0)
                + ((targetState["remote-projects"] as? [[String: Any]])?.count ?? 0)
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

    private static func isPortableAtomKey(_ key: String) -> Bool {
        portableAtomKeys.contains(key) || portableAtomPrefixes.contains { key.hasPrefix($0) }
    }

    private static func mergePortableValue(current: Any?, preferred: Any) -> Any {
        guard let current else { return preferred }
        if let currentObject = current as? [String: Any], let preferredObject = preferred as? [String: Any] {
            var merged = currentObject
            for (key, value) in preferredObject {
                merged[key] = mergePortableValue(current: merged[key], preferred: value)
            }
            return merged
        }
        if let currentArray = current as? [Any], let preferredArray = preferred as? [Any] {
            var merged: [Any] = []
            var fingerprints = Set<Data>()
            for value in preferredArray + currentArray {
                guard let fingerprint = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]) else {
                    continue
                }
                if fingerprints.insert(fingerprint).inserted { merged.append(value) }
            }
            return merged
        }
        return preferred
    }

    private static func uniqueHomes(_ homes: [String]) -> [String] {
        var seen = Set<String>()
        return homes.compactMap {
            let path = URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
            return seen.insert(path).inserted ? path : nil
        }
    }
}
