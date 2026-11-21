import Foundation
import Observation

/// Local display names Joel gives his Claude and Codex accounts (JSB-112).
///
/// Keyed by a fingerprint of the ACCOUNT's own identity (Anthropic account
/// uuid, ChatGPT account id) within its provider family, never by row,
/// provider id, Keychain slot, folder or credential. Each row is bound to the
/// account that currently serves it, so a name follows its account: if the
/// first row's login changes, that row shows its default name again.
@MainActor
@Observable
final class AccountNames {
    static let key = "accountDisplayNames"

    @ObservationIgnored private let defaults: UserDefaults
    private var names: [String: String]
    private var identities: [ProviderID: String] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.names = (defaults.dictionary(forKey: Self.key) as? [String: String]) ?? [:]
    }

    /// Ties a row to the account serving it now; nil when unknown (no rename).
    func bind(_ id: ProviderID, accountID: String?) {
        guard let family = Self.family(of: id), let accountID, !accountID.isEmpty else {
            identities[id] = nil
            return
        }
        identities[id] = PiAccountResolver.fingerprint("\(family):\(accountID)")
    }

    func canRename(_ id: ProviderID) -> Bool { identities[id] != nil }

    func name(for id: ProviderID) -> String? {
        identities[id].flatMap { names[$0] }
    }

    /// Saves a trimmed name; an empty one restores the default.
    func setName(_ name: String?, for id: ProviderID) {
        guard let identity = identities[id] else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        names[identity] = trimmed.isEmpty ? nil : String(trimmed.prefix(40))
        defaults.set(names, forKey: Self.key)
    }

    private static func family(of id: ProviderID) -> String? {
        if id == .claude || id.isClaudeConnected { return "claude" }
        if id == .codex || id.isCodexAccount { return "codex" }
        return nil
    }
}
