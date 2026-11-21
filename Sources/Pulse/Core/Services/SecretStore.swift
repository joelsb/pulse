import Foundation

/// Where Pulse's OAuth stores (`PulseOAuthStore`, `CodexOAuthStore`) keep
/// their secrets, keyed like the Keychain by (service, account). The seam
/// exists so JSB-112's multi-account flows are tested on an in-memory store
/// instead of this Mac's real Keychain.
protocol SecretStore: Sendable {
    func read(service: String, account: String) async throws -> String
    func write(service: String, account: String, secret: String) async throws
    func delete(service: String, account: String) async throws
    /// True when an item exists; throws when that cannot be told (timeout,
    /// denied), so a caller about to write can fail safe instead of assuming
    /// the slot is free.
    func exists(service: String, account: String) async throws -> Bool
}

/// The production store: `security`-backed reads and writes, base64 at rest.
struct KeychainSecretStore: SecretStore {
    var reader = KeychainReader()
    var writer = KeychainWriter()

    func read(service: String, account: String) async throws -> String {
        let stored = try await reader.readGenericPassword(service: service, account: account)
        guard let secret = KeychainWriter.decode(stored) else {
            throw ProviderFetchError.parsing(description: "Pulse OAuth store: stored item could not be decoded")
        }
        return secret
    }

    func write(service: String, account: String, secret: String) async throws {
        try await writer.write(service: service, account: account, secret: secret)
    }

    func delete(service: String, account: String) async throws {
        try await writer.delete(service: service, account: account)
    }

    func exists(service: String, account: String) async throws -> Bool {
        do {
            _ = try await reader.readGenericPassword(service: service, account: account)
            return true
        } catch KeychainReader.Failure.itemNotFound {
            return false
        }
    }
}
