import Foundation
import Darwin

struct DiscoveredSSHHost: Identifiable, Equatable, Sendable {
    let alias: String
    var hostname: String?
    var user: String?
    var port: String?
    var id: String { alias }
    var destination: String {
        guard let hostname else { return "Uses your SSH configuration" }
        return (user.map { $0 + "@" } ?? "") + hostname + (port.map { " · port " + $0 } ?? "")
    }
}

struct SSHDiscoveryResult: Sendable {
    var hosts: [DiscoveredSSHHost] = []
    var incomplete = false
}

/// Lists concrete aliases without running SSH, Match exec, ProxyCommand or any
/// network probe. Connection-time resolution remains entirely owned by SSH.
enum SSHHostDiscovery {
    static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     systemConfig: URL? = URL(fileURLWithPath: "/etc/ssh/ssh_config")) -> SSHDiscoveryResult {
        var scanner = Scanner(home: home)
        scanner.read(home.appendingPathComponent(".ssh/config"), base: home.appendingPathComponent(".ssh"))
        scanner.current = []
        if let systemConfig { scanner.read(systemConfig, base: systemConfig.deletingLastPathComponent()) }
        scanner.result.hosts.sort { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
        return scanner.result
    }

    private struct Scanner {
        let home: URL
        var result = SSHDiscoveryResult()
        var visited: Set<String> = []
        var bytes = 0
        var current: [String] = []

        mutating func read(_ file: URL, base: URL, depth: Int = 0) {
            let path = file.standardizedFileURL.resolvingSymlinksInPath()
            guard !visited.contains(path.path) else { return }
            guard depth < 24, visited.count < 128 else { result.incomplete = true; return }
            guard FileManager.default.fileExists(atPath: path.path) else { return }
            visited.insert(path.path)
            do {
                let info = try path.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard info.isRegularFile == true, let size = info.fileSize,
                      size <= 1_000_000, bytes + size <= 4_000_000 else { result.incomplete = true; return }
                bytes += size
                let contents = try String(contentsOf: path, encoding: .utf8)
                for line in contents.components(separatedBy: .newlines) {
                    let words = SSHHostDiscovery.tokens(line)
                    guard let key = words.first?.lowercased(), words.count > 1 else { continue }
                    let values = Array(words.dropFirst())
                    switch key {
                    case "include":
                        for value in values {
                            let expanded = value.hasPrefix("~/") ? home.path + String(value.dropFirst()) : value
                            let pattern = expanded.hasPrefix("/") ? expanded : base.appendingPathComponent(expanded).path
                            for included in SSHHostDiscovery.paths(pattern) { read(included, base: base, depth: depth + 1) }
                        }
                    case "host":
                        current = values.filter { alias in
                            !alias.isEmpty && alias.count <= 200 && !alias.hasPrefix("-") &&
                            alias.unicodeScalars.allSatisfy {
                                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
                            }
                        }
                        for alias in current where !result.hosts.contains(where: { $0.alias == alias }) {
                            result.hosts.append(DiscoveredSSHHost(alias: alias))
                        }
                    case "match":
                        // Conditional directives cannot be evaluated safely here.
                        current = []
                    case "hostname", "user", "port":
                        // Display explicit hints only. Wildcard/Match rules and
                        // precedence are resolved by the actual ssh invocation.
                        for index in result.hosts.indices where current.contains(result.hosts[index].alias) {
                            if key == "hostname", result.hosts[index].hostname == nil { result.hosts[index].hostname = values[0] }
                            if key == "user", result.hosts[index].user == nil { result.hosts[index].user = values[0] }
                            if key == "port", result.hosts[index].port == nil { result.hosts[index].port = values[0] }
                        }
                    default: break
                    }
                }
            } catch { result.incomplete = true }
        }
    }

    private static func paths(_ pattern: String) -> [URL] {
        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(pattern, 0, nil, &matches) == 0, let paths = matches.gl_pathv else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { index in
            paths[index].map { URL(fileURLWithPath: String(cString: $0)) }
        }
    }

    static func tokens(_ line: String) -> [String] {
        var result: [String] = [], token = "", quote: Character?, escaped = false
        for character in line {
            if escaped { token.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let active = quote {
                if character == active { quote = nil } else { token.append(character) }
            } else if character == "\"" || character == "'" { quote = character }
            else if character == "#" { break }
            else if character.isWhitespace || (character == "=" && result.count <= 1) {
                if !token.isEmpty { result.append(token); token = "" }
            } else { token.append(character) }
        }
        if !token.isEmpty { result.append(token) }
        return result
    }
}
