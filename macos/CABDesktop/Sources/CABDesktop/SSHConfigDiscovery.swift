import Darwin
import Foundation

struct SSHConfigDiscovery {
    private let fileManager = FileManager.default
    private let homeDirectory: URL
    private let maxFiles = 64
    private let maxFileSize = 1_048_576

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    func discover() throws -> [String] {
        let root = homeDirectory.appendingPathComponent(".ssh/config")
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        var visited = Set<String>()
        var aliases = Set<String>()
        try parse(root, visited: &visited, aliases: &aliases)
        return aliases.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func parse(_ url: URL, visited: inout Set<String>, aliases: inout Set<String>) throws {
        guard visited.count < maxFiles else {
            throw BridgeError.commandFailed("SSH 配置包含过多 Include 文件，已停止读取。")
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard !visited.contains(resolved.path) else { return }
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { return }
        guard (values.fileSize ?? 0) <= maxFileSize else {
            throw BridgeError.commandFailed("SSH 配置文件超过 1 MB，已停止读取：\(url.lastPathComponent)")
        }
        visited.insert(resolved.path)
        let text = try String(contentsOf: resolved, encoding: .utf8)
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let fields = tokens(String(rawLine))
            guard let keyword = fields.first?.lowercased() else { continue }
            if keyword == "host" {
                for alias in fields.dropFirst() where isConcreteAlias(alias) {
                    aliases.insert(alias)
                }
            } else if keyword == "include" {
                for pattern in fields.dropFirst() {
                    for included in resolveInclude(pattern) {
                        try parse(included, visited: &visited, aliases: &aliases)
                    }
                }
            }
        }
    }

    private func resolveInclude(_ value: String) -> [URL] {
        let expanded: URL
        if value == "~" || value.hasPrefix("~/") {
            expanded = homeDirectory.appendingPathComponent(String(value.dropFirst(2)))
        } else if value.hasPrefix("/") {
            expanded = URL(fileURLWithPath: value)
        } else {
            expanded = homeDirectory.appendingPathComponent(".ssh").appendingPathComponent(value)
        }
        let pattern = expanded.lastPathComponent
        guard pattern.contains("*") || pattern.contains("?") else { return [expanded] }
        let directory = expanded.deletingLastPathComponent()
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter { fnmatch(pattern, $0.lastPathComponent, 0) == 0 }
    }

    private func tokens(_ line: String) -> [String] {
        var result: [String] = []
        var token = ""
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped {
                token.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil } else { token.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                break
            } else if character.isWhitespace || character == "=" {
                if !token.isEmpty { result.append(token); token = "" }
            } else {
                token.append(character)
            }
        }
        if escaped { token.append("\\") }
        if !token.isEmpty { result.append(token) }
        return result
    }

    private func isConcreteAlias(_ alias: String) -> Bool {
        guard !alias.hasPrefix("!"), !alias.contains(where: { "*?!".contains($0) }) else { return false }
        return alias.range(of: "^[A-Za-z0-9][A-Za-z0-9._@:\\[\\]%-]{0,254}$", options: .regularExpression) != nil
    }
}
