import Foundation
import AppKit

struct PoolGrant: Codable {
    let selectionID: String
    let accountID: String
    let name: String
    let accessToken: String
    let chatgptAccountId: String
    let planType: String

    static func make(account: Account, selectionID: String, token: String) throws -> PoolGrant {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { throw UsageError.message("OpenAI did not provide a usable account token.") }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let claims = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String, !accountID.isEmpty,
              let expires = claims["exp"] as? Double, expires > Date().timeIntervalSince1970 + 30 else {
            throw UsageError.message("This account needs a fresh sign-in before it can be used.")
        }
        return PoolGrant(selectionID: selectionID, accountID: account.id.uuidString, name: account.name,
                         accessToken: token, chatgptAccountId: accountID, planType: account.planType ?? "")
    }
}

struct PoolDevice: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var sshHost: String
    static let local = PoolDevice(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "This Mac", sshHost: "")
    var isLocal: Bool { sshHost.isEmpty }
}

struct PeerStatus: Decodable {
    var version: String?
    var hostname: String?
    var accountID: String?
    var selectionID: String?
    var name: String?
    var codexConnected: Bool?
    var expiresAt: Double?
    var lastConfirmed: Double?
    var state: String?
    var error: String?
    var hermesInstalled: Bool?
}

struct DeviceConnection {
    var status: PeerStatus?
    var reachable = false
    var checking = false
    var error: String?
    var checkedAt: Date?
}

struct DeviceSelection: Codable, Equatable {
    var accountID: UUID
    var selectionID: String
}

private struct PoolPreferences: Codable {
    var accountID: UUID?
    var selectionID: String?
    var devices: [PoolDevice] = []
    var selections: [String: DeviceSelection]?
}

/// Short subprocesses receive secrets only through stdin. Stderr is discarded,
/// and callers use fixed, non-secret diagnostics rather than raw process output.
enum PoolProcess {
    static func run(_ executable: String, _ arguments: [String], input: Data? = nil, timeout: Double = 30) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(), output = Pipe(), stdin = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = stdin
                do {
                    try process.run()
                    let expiry = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: expiry)
                    if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
                    try stdin.fileHandleForWriting.close()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    expiry.cancel()
                    guard process.terminationStatus == 0, data.count < 1_000_000 else {
                        throw UsageError.message("The device didn’t respond. Check its connection and try again.")
                    }
                    continuation.resume(returning: data)
                } catch {
                    if process.isRunning { process.terminate() }
                    continuation.resume(throwing: UsageError.message("The device didn’t respond. Check its connection and try again."))
                }
            }
        }
    }
}

@MainActor
final class AccountPool: ObservableObject {
    @Published private(set) var accountID: UUID?
    @Published private(set) var devices: [PoolDevice] = [.local]
    @Published private(set) var connections: [UUID: DeviceConnection] = [:]
    @Published private(set) var isWorking = false
    @Published var error: String?
    @Published var showingDevices = false
    var grantProvider: ((UUID, String) async throws -> PoolGrant)?
    private var selectionID: String?
    @Published private(set) var selections: [UUID: DeviceSelection] = [:]
    var transport: ((PoolDevice, String, Data?) async throws -> Data)?
    private var polling: Task<Void, Never>?
    private let file: URL
    let preview: Bool
    var previewRuntime: [UUID: RuntimeSnapshot] = [:]
    private var canSave = true

    init(preview: Bool = false, file: URL? = nil) {
        self.preview = preview
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenAIQuotaBar/pool.json")
        if !preview, FileManager.default.fileExists(atPath: self.file.path) {
            do {
                let value = try JSONDecoder().decode(PoolPreferences.self, from: Data(contentsOf: self.file))
                accountID = value.accountID; selectionID = value.selectionID
                devices = [.local] + value.devices.filter { !$0.isLocal }
                if let saved = value.selections {
                    for device in devices { selections[device.id] = saved[device.id.uuidString] }
                } else if let id = value.accountID, let selection = value.selectionID {
                    for device in devices { selections[device.id] = DeviceSelection(accountID: id, selectionID: selection) }
                }
            } catch { canSave = false; self.error = "Device settings need recovery. Your original file has been preserved." }
        }
    }

    static func validSSHHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 200 && !host.hasPrefix("-") &&
        host.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@._-").contains($0) }
    }

    private var resource: URL {
        if let packaged = Bundle.main.url(forResource: "quotabar_peer", withExtension: "py", subdirectory: "Bridge") { return packaged }
        return Bundle.module.url(forResource: "quotabar_peer", withExtension: "py", subdirectory: "Resources")!
    }
    private var python: String {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first(where: FileManager.default.isExecutableFile(atPath:)) ?? "/usr/bin/python3"
    }

    private func save(account: UUID?, selection: String?, devices: [PoolDevice], choices: [UUID: DeviceSelection]? = nil) throws {
        guard !preview else { return }
        guard canSave else { throw UsageError.message("Restore device settings before changing them.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(PoolPreferences(accountID: account, selectionID: selection, devices: devices.filter { !$0.isLocal },
            selections: Dictionary(uniqueKeysWithValues: (choices ?? selections).map { ($0.key.uuidString, $0.value) })))
            .write(to: file, options: .atomic)
    }

    func start() {
        guard !preview, polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.synchronize()
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { break }
            }
        }
    }
    func stop() { polling?.cancel(); polling = nil }

    func use(_ account: Account, on targetIDs: Set<UUID>? = nil) async {
        guard !isWorking, account.isCodex else { return }
        let targets = devices.filter { (targetIDs ?? Set(devices.map(\.id))).contains($0.id) }
        guard !targets.isEmpty else { error = "Choose at least one device."; return }
        isWorking = true; error = nil
        defer { isWorking = false }
        do {
            let selection = UUID().uuidString
            let grant: PoolGrant?
            if preview { grant = nil }
            else {
                guard let grantProvider else { throw UsageError.message("Account connection unavailable.") }
                grant = try await grantProvider(account.id, selection)
            }
            var choices = selections
            for device in targets { choices[device.id] = DeviceSelection(accountID: account.id, selectionID: selection) }
            let local = choices[PoolDevice.local.id]
            // Persist intent before delivery: offline targets retry their own choice.
            try save(account: local?.accountID, selection: local?.selectionID, devices: devices, choices: choices)
            selections = choices; accountID = local?.accountID; selectionID = local?.selectionID
            for device in targets {
                if preview {
                    connections[device.id] = DeviceConnection(status: PeerStatus(accountID: account.id.uuidString,
                        selectionID: selection, name: account.name, codexConnected: true, state: "active"), reachable: true, checkedAt: Date())
                } else { await update(device, grant: grant) }
            }
            if targets.contains(where: { !isConfirmed($0) }) { error = "Some devices have not confirmed. Their selection is saved and will retry." }
        } catch { self.error = error.localizedDescription }
    }

    func isSelected(_ id: UUID) -> Bool { selections.values.contains { $0.accountID == id } }

    func isInUse(_ id: UUID) -> Bool {
        isSelected(id) || connections.values.contains { $0.status?.accountID == id.uuidString }
    }

    func isConfirmed(_ device: PoolDevice) -> Bool {
        guard let choice = selections[device.id], let connection = connections[device.id],
              connection.reachable, let status = connection.status else { return false }
        return status.accountID == choice.accountID.uuidString && status.selectionID == choice.selectionID
            && status.state == "active" && status.codexConnected == true
    }

    func activeDevices(for id: UUID) -> [PoolDevice] {
        devices.filter { selections[$0.id]?.accountID == id && isConfirmed($0) }
    }

    func command(_ device: PoolDevice, _ command: String, input: Data? = nil, timeout: Double = 30) async throws -> Data {
        if let transport { return try await transport(device, command, input) }
        if device.isLocal { return try await PoolProcess.run(python, [resource.path, command], input: input, timeout: timeout) }
        if command == "runtime" {
            guard Self.validSSHHost(device.sshHost) else { throw UsageError.message("Invalid SSH host.") }
            let script = try String(contentsOf: resource, encoding: .utf8)
            let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
            return try await PoolProcess.run("/usr/bin/ssh", ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6",
                "--", device.sshHost, "python3 -c " + quoted + " runtime"], input: input, timeout: timeout)
        }
        guard Self.validSSHHost(device.sshHost), ["rpc", "status", "install-hermes"].contains(command) else {
            throw UsageError.message("Use an SSH alias or user@hostname.")
        }
        return try await PoolProcess.run("/usr/bin/ssh", ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", "--", device.sshHost,
            "python3 ~/.local/share/quotabar/quotabar-peer.py " + command], input: input, timeout: timeout)
    }

    private func decode(_ data: Data) throws -> PeerStatus {
        struct Reply: Decodable { let ok: Bool; let result: PeerStatus?; let error: String? }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.ok, let status = reply.result else {
            throw UsageError.message(reply.error ?? "The connector did not confirm this request.")
        }
        return status
    }

    private func send(_ device: PoolDevice, grant: PoolGrant?) async throws -> PeerStatus {
        struct Selection: Encodable { let command = "select"; let grant: PoolGrant }
        if let grant {
            var data = try JSONEncoder().encode(Selection(grant: grant)); data.append(0x0A)
            let status = try decode(await command(device, "rpc", input: data))
            guard status.selectionID == grant.selectionID, status.accountID == grant.accountID, status.state == "active" else {
                throw UsageError.message("The device has not confirmed this account yet.")
            }
            return status
        }
        return try decode(await command(device, "status"))
    }

    private func update(_ device: PoolDevice, grant: PoolGrant?) async {
        connections[device.id, default: DeviceConnection()].checking = true
        do {
            let status = try await send(device, grant: grant)
            connections[device.id] = DeviceConnection(status: status, reachable: true, checkedAt: Date())
        } catch {
            var previous = connections[device.id] ?? DeviceConnection()
            previous.reachable = false; previous.checking = false
            previous.error = "Not connected · will retry"; previous.checkedAt = Date()
            connections[device.id] = previous
        }
    }

    func synchronize() async {
        guard !isWorking, !preview else { return }
        isWorking = true; error = nil
        defer { isWorking = false }
        for device in devices {
            do { await update(device, grant: try await currentGrant(for: device)) }
            catch {
                connections[device.id, default: DeviceConnection()].reachable = false
                self.error = "An account needs attention. Sign in again to renew its devices."
            }
        }
    }

    func connect(name: String, host: String) async {
        guard !isWorking else { return }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validSSHHost(host) else { error = "Enter an SSH alias, such as my-vps, or user@hostname."; return }
        guard !devices.contains(where: { $0.sshHost == host }) else { error = "This device is already connected."; return }
        if preview {
            let device = PoolDevice(name: name.isEmpty ? host : name, sshHost: host)
            devices.append(device)
            connections[device.id] = DeviceConnection(status: PeerStatus(codexConnected: true, state: "ready", hermesInstalled: true), reachable: true, checkedAt: Date())
            return
        }
        isWorking = true; error = nil
        defer { isWorking = false }
        let device = PoolDevice(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : String(name.prefix(60)), sshHost: host)
        do {
            let script = try Data(contentsOf: resource)
            let data = try await PoolProcess.run("/usr/bin/ssh", ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "--", host,
                "umask 077; mkdir -p ~/.local/share/quotabar; cat > ~/.local/share/quotabar/quotabar-peer.py; python3 ~/.local/share/quotabar/quotabar-peer.py install"], input: script, timeout: 45)
            _ = try decode(data)
            try save(account: accountID, selection: selectionID, devices: devices + [device])
            devices.append(device)
            try? await Task.sleep(nanoseconds: 500_000_000)
            let grant = try await currentGrant(for: device)
            await update(device, grant: grant)
        } catch { self.error = "Couldn’t connect this VPS. Verify SSH access, Python 3.9+, Codex, and a user systemd session." }
    }

    private func currentGrant(for device: PoolDevice) async throws -> PoolGrant? {
        guard let choice = selections[device.id], let grantProvider else { return nil }
        return try await grantProvider(choice.accountID, choice.selectionID)
    }

    func installLocal() async {
        guard !isWorking else { return }
        if preview {
            connections[PoolDevice.local.id] = DeviceConnection(status: PeerStatus(codexConnected: true, state: "ready"), reachable: true, checkedAt: Date())
            return
        }
        isWorking = true; error = nil
        defer { isWorking = false }
        do {
            _ = try decode(await command(.local, "install", timeout: 45))
            try? await Task.sleep(nanoseconds: 700_000_000)
            await update(.local, grant: nil)
        } catch { self.error = "Couldn’t install the Mac connector. Check that Codex is installed." }
    }

    func connectHermes(_ device: PoolDevice) async {
        guard !isWorking else { return }
        if preview { connections[device.id]?.status?.hermesInstalled = true; return }
        isWorking = true; error = nil
        defer { isWorking = false }
        do {
            _ = try decode(await command(device, "install-hermes", timeout: 50))
            await update(device, grant: nil)
        } catch { self.error = "Hermes could not enable the connector. Check that Hermes is installed on this device." }
    }

    func label(for device: PoolDevice) -> String {
        guard let connection = connections[device.id] else { return "Not connected" }
        if connection.checking { return "Connecting…" }
        guard connection.reachable else { return selections[device.id] == nil ? "Not connected" : "Offline · switch pending" }
        guard let status = connection.status else { return "Ready" }
        if status.state == "expired" { return "Account expired · open LLM Usage" }
        if status.state == "attention" { return "Needs attention" }
        if isConfirmed(device) {
            return "Using \(status.name ?? "selected account")"
        }
        return selections[device.id] == nil ? "Ready to switch" : "Waiting to switch"
    }

    var confirmedCount: Int { devices.filter { isConfirmed($0) }.count }
}
