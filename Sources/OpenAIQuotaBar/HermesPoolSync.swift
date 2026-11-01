import Foundation
import OSLog

struct HermesSyncConfiguration: Decodable {
    let enabled: Bool
    let homes: [String]
}

struct HermesSyncResult: Decodable {
    let accountCount: Int
    let profileCount: Int
    let strategy: String
}

/// Runs inside the native app's existing sign-in context. Only expiring access
/// grants cross stdin to Hermes; refresh credentials stay in Codex's Keychain.
@MainActor
enum HermesPoolSync {
    private static let logger = Logger(subsystem: "com.openaiquotabar.app", category: "hermes-sync")

    static func reportFailure() {
        logger.error("Local Hermes pool sync failed; existing native sign-ins were preserved. Check connected accounts and the configured local homes. The app will retry automatically.")
    }

    static var configuration: HermesSyncConfiguration? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/llm-usage/hermes-sync.json")
        guard let data = try? Data(contentsOf: path),
              let value = try? JSONDecoder().decode(HermesSyncConfiguration.self, from: data),
              value.enabled, !value.homes.isEmpty else { return nil }
        return value
    }

    static func apply(_ grants: [PoolGrant], configuration: HermesSyncConfiguration) async throws -> HermesSyncResult {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let hermes = home.appendingPathComponent(".hermes/hermes-agent")
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Bridge/hermes_pool_sync.py")
        let resource = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? Bundle.module.resourceURL!.appendingPathComponent("Resources/hermes_pool_sync.py")
        struct Payload: Encodable { let accounts: [PoolGrant]; let homes: [String] }
        let input = try JSONEncoder().encode(Payload(accounts: grants, homes: configuration.homes))
        let output = try await PoolProcess.run(hermes.appendingPathComponent("venv/bin/python").path,
            [resource.path, "--hermes-root", hermes.path], input: input, timeout: 45)
        return try JSONDecoder().decode(HermesSyncResult.self, from: output)
    }
}
