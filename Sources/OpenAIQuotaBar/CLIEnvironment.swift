import Foundation

/// Finder and launchd do not inherit the PATH configured in a terminal.
/// Resolve installed tools without running a login shell or sourcing user scripts.
enum CLIEnvironment {
    static func directories(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let paths = [".local/bin", ".local/node/bin", ".npm-global/bin", ".volta/bin", ".bun/bin",
                     ".codex/packages/standalone/current/bin", ".codex/packages/standalone/current", ".claude/local"]
            .map { home.appendingPathComponent($0).path }
            + (inherited["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return paths.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    static func executable(_ name: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           inherited: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        directories(home: home, inherited: inherited).map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) && !$0.hasDirectoryPath }
    }

    static func environment(inherited: [String: String] = ProcessInfo.processInfo.environment,
                            executable: URL? = nil) -> [String: String] {
        var environment = inherited
        // A package-manager launcher may use /usr/bin/env node beside the launcher.
        var paths = directories(inherited: inherited)
        if let executable { paths.insert(executable.deletingLastPathComponent().path, at: 0) }
        environment["PATH"] = paths.joined(separator: ":")
        return environment
    }
}
