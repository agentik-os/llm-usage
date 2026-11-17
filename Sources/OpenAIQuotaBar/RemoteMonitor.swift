import Foundation
import Combine

struct MonitoredMachine: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var sshHost: String
}

struct MachineObservation: Codable, Equatable {
    struct ConnectedAccount: Codable, Equatable, Identifiable {
        struct Window: Codable, Equatable {
            var name: String
            var remainingPercent: Double
            var resetsAt: Double?
            var fraction: Double { min(1, max(0, remainingPercent / 100)) }
        }
        var id: String
        var provider: String
        var profile: String
        var isDefault: Bool
        var status: String
        var email: String?
        var plan: String?
        var windows: [Window]
        var checkedAt: Double
        var message: String?
        var providerName: String { provider == "codex" ? "Codex" : "Claude Code" }
        var identityLabel: String {
            if let email, !email.isEmpty { return email }
            if status == "signedOut" { return "Not signed in" }
            if status == "apiKey" { return "API key session" }
            return "Account unavailable"
        }
        var planLabel: String? {
            plan?.replacingOccurrences(of: "default_claude_", with: "")
                .replacingOccurrences(of: "claude_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    struct Usage: Codable, Equatable, Identifiable {
        var provider: String
        var id: String { provider }
        var tokens24h: Int
        var tokens7d: Int
        var input7d: Int
        var output7d: Int
        var cached7d: Int
        var lastActivity: Double?
        var sessions7d: Int
        var name: String { provider == "codex" ? "Codex" : "Claude Code" }
    }
    struct Model: Codable, Equatable { var name: String; var memoryBytes: Int64 }
    var version: Int
    var hostname: String
    var platform: String
    var collectedAt: Double
    var agents: [String: Int]?
    var models: [Model]?
    var usage: [Usage]
    var partial: Bool
    var sources: [String: Bool]
    var accounts: [ConnectedAccount]?
}

/// Monitoring has its own storage and transport. These machines are never targets
/// of account sharing, token grants, provider changes, or daemon restarts.
@MainActor
final class RemoteMonitor: ObservableObject {
    @Published private(set) var machines: [MonitoredMachine] = []
    @Published private(set) var observations: [UUID: MachineObservation] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var refreshing = Set<UUID>()
    @Published var storageError: String?
    let preview: Bool
    private let file: URL
    private let transport: (String, Data) async throws -> Data
    private var writable = true

    init(preview: Bool = false, file: URL? = nil, transport: ((String, Data) async throws -> Data)? = nil) {
        self.preview = preview
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenAIQuotaBar/monitored-machines.json")
        self.transport = transport ?? { host, script in
            try await PoolProcess.run("/usr/bin/ssh", ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", "ConnectTimeout=7", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", "--", host,
                "if [ -x /opt/homebrew/bin/python3 ]; then exec /opt/homebrew/bin/python3 -; elif [ -x /usr/local/bin/python3 ]; then exec /usr/local/bin/python3 -; else exec python3 -; fi"],
                input: script, timeout: 40)
        }
        guard !preview, FileManager.default.fileExists(atPath: self.file.path) else { return }
        do {
            machines = try JSONDecoder().decode([MonitoredMachine].self, from: Data(contentsOf: self.file))
            if let data = try? Data(contentsOf: cacheFile), let cache = try? JSONDecoder().decode([String: MachineObservation].self, from: data) {
                observations = Dictionary(uniqueKeysWithValues: machines.compactMap { machine in cache[machine.id.uuidString].map { (machine.id, $0) } })
            }
        } catch {
            writable = false
            storageError = "Saved machines could not be read. The original file has been preserved."
        }
    }

    private var cacheFile: URL { file.deletingLastPathComponent().appendingPathComponent("machine-observations.json") }
    private var collector: URL {
        if let url = Bundle.main.url(forResource: "machine_monitor", withExtension: "py", subdirectory: "Bridge") { return url }
        return Bundle.module.url(forResource: "machine_monitor", withExtension: "py", subdirectory: "Resources")!
    }

    func add(name: String, host: String) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AccountPool.validSSHHost(host), !name.isEmpty, name.count <= 60, !name.contains(where: \.isNewline) else {
            throw UsageError.message("Enter a name and an SSH alias or user@hostname.")
        }
        guard !machines.contains(where: { $0.sshHost.caseInsensitiveCompare(host) == .orderedSame }) else {
            throw UsageError.message("This machine is already monitored.")
        }
        let machine = MonitoredMachine(name: name, sshHost: host)
        let updated = machines + [machine]
        try save(updated)
        machines = updated
        if !preview { Task { await refresh(machine) } }
    }

    func remove(_ machine: MonitoredMachine) throws {
        let updated = machines.filter { $0.id != machine.id }
        try save(updated)
        machines = updated
        observations.removeValue(forKey: machine.id)
        errors.removeValue(forKey: machine.id)
        saveCache()
    }

    private func save(_ machines: [MonitoredMachine]) throws {
        guard !preview else { return }
        guard writable else { throw UsageError.message("Recover the saved machine list before changing it.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(machines).write(to: file, options: .atomic)
    }

    private func saveCache() {
        guard !preview, writable else { return }
        let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: observations.map { ($0.key.uuidString, $0.value) }))
        try? data?.write(to: cacheFile, options: .atomic)
    }

    func refreshAll() async {
        guard !preview else { return }
        let current = machines
        await withTaskGroup(of: Void.self) { group in
            for machine in current { group.addTask { await self.refresh(machine) } }
        }
    }

    func refresh(_ machine: MonitoredMachine) async {
        guard !preview, machines.contains(machine), !refreshing.contains(machine.id), AccountPool.validSSHHost(machine.sshHost) else { return }
        refreshing.insert(machine.id)
        defer { refreshing.remove(machine.id) }
        do {
            let data = try await transport(machine.sshHost, Data(contentsOf: collector))
            guard data.count < 1_000_000 else { throw UsageError.message("This machine returned too much data.") }
            let observation = try JSONDecoder().decode(MachineObservation.self, from: data)
            guard observation.version == 1, observation.collectedAt.isFinite else { throw UsageError.message("Update the machine monitor and try again.") }
            guard machines.contains(machine) else { return }
            observations[machine.id] = observation
            errors.removeValue(forKey: machine.id)
            saveCache()
        } catch {
            guard machines.contains(machine) else { return }
            errors[machine.id] = "Unable to read this machine. Check Tailscale, its SSH user, a trusted host key and key-based SSH access."
        }
    }
}
