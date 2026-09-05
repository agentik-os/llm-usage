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

private struct PoolPreferences: Codable {
    var accountID: UUID?
    var selectionID: String?
    var devices: [PoolDevice] = []
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
    private var polling: Task<Void, Never>?
    private let file: URL
    private let preview: Bool
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

    private func save(account: UUID?, selection: String?, devices: [PoolDevice]) throws {
        guard !preview else { return }
        guard canSave else { throw UsageError.message("Restore device settings before changing them.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(PoolPreferences(accountID: account, selectionID: selection, devices: devices.filter { !$0.isLocal }))
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

    func use(_ account: Account) async {
        guard !isWorking, account.isCodex else { return }
        if preview {
            accountID = account.id; selectionID = UUID().uuidString
            connections[PoolDevice.local.id] = DeviceConnection(status: PeerStatus(accountID: account.id.uuidString, selectionID: selectionID, name: account.name,
                codexConnected: true, state: "active", hermesInstalled: true), reachable: true, checkedAt: Date())
            return
        }
        guard let grantProvider else { return }
        isWorking = true; error = nil
        defer { isWorking = false }
        do {
            guard canSave else { throw UsageError.message("Restore device settings before switching accounts.") }
            let selection = UUID().uuidString
            let grant = try await grantProvider(account.id, selection)
            let status = try await send(.local, grant: grant)
            // Record the selected account only after this Mac confirms it.
            try save(account: account.id, selection: selection, devices: devices)
            accountID = account.id; selectionID = selection
            connections[PoolDevice.local.id] = DeviceConnection(status: status, reachable: true, checkedAt: Date())
            await syncRemote(grant)
        } catch { self.error = error.localizedDescription }
    }

    private func command(_ device: PoolDevice, _ command: String, input: Data? = nil, timeout: Double = 30) async throws -> Data {
        if device.isLocal { return try await PoolProcess.run(python, [resource.path, command], input: input, timeout: timeout) }
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

    private func syncRemote(_ grant: PoolGrant?) async {
        // Each device is independent, but each selection waits for every attempt
        // so an older refresh cannot overtake a new manual choice.
        await withTaskGroup(of: Void.self) { group in
            for device in devices where !device.isLocal { group.addTask { await self.update(device, grant: grant) } }
        }
    }

    func synchronize() async {
        guard !isWorking, !preview else { return }
        isWorking = true
        defer { isWorking = false }
        var grant: PoolGrant?
        if let accountID, let selectionID, let grantProvider {
            do { grant = try await grantProvider(accountID, selectionID); error = nil }
            catch { self.error = "The selected account needs attention. Open its settings to sign in again." }
        }
        await update(.local, grant: grant)
        await syncRemote(grant)
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
            let grant = try await currentGrant()
            await update(device, grant: grant)
        } catch { self.error = "Couldn’t connect this VPS. Verify SSH access, Python 3.9+, Codex, and a user systemd session." }
    }

    private func currentGrant() async throws -> PoolGrant? {
        guard let accountID, let selectionID, let grantProvider else { return nil }
        return try await grantProvider(accountID, selectionID)
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
        guard connection.reachable else { return accountID == nil ? "Not connected" : "Offline · switch pending" }
        guard let status = connection.status else { return "Ready" }
        if status.state == "expired" { return "Account expired · open QuotaBar" }
        if status.state == "attention" { return "Needs attention" }
        if let accountID, status.accountID == accountID.uuidString, status.selectionID == selectionID, status.codexConnected == true {
            return "Using \(status.name ?? "selected account")"
        }
        return accountID == nil ? "Ready to switch" : "Waiting to switch"
    }

    var confirmedCount: Int {
        devices.filter { device in
            guard let value = connections[device.id], value.reachable, let status = value.status else { return false }
            return accountID != nil && status.accountID == accountID?.uuidString && status.selectionID == selectionID && status.state == "active"
        }.count
    }
}
