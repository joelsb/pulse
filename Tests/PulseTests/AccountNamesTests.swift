import Foundation
import Observation
import Testing
@testable import Pulse

// JSB-112: local display names for Claude and Codex accounts, keyed by the
// account's own identity, never by row, credential, folder or provider id.
@Suite("Account display names (JSB-112)")
@MainActor
struct AccountNamesTests {
    private func defaults() throws -> (UserDefaults, () -> Void) {
        let suite = "pulse-tests-names-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        return (d, { d.removePersistentDomain(forName: suite) })
    }

    @Test func twoAccountsKeepTheirOwnNamesAcrossARelaunch() throws {
        let (d, cleanUp) = try defaults()
        defer { cleanUp() }
        let b = ProviderID.claudeConnected(uuid: "uuid-b")
        let names = AccountNames(defaults: d)
        names.bind(.claude, accountID: "uuid-a")
        names.bind(b, accountID: "uuid-b")

        names.setName("  Personal ", for: .claude)
        names.setName("Work", for: b)
        #expect(names.name(for: .claude) == "Personal")
        #expect(names.name(for: b) == "Work")

        let relaunched = AccountNames(defaults: d)
        relaunched.bind(.claude, accountID: "uuid-a")
        relaunched.bind(b, accountID: "uuid-b")
        #expect(relaunched.name(for: .claude) == "Personal")
        #expect(relaunched.name(for: b) == "Work")
    }

    @Test func clearingRestoresTheDefaultAndOnlyThatAccount() throws {
        let (d, cleanUp) = try defaults()
        defer { cleanUp() }
        let names = AccountNames(defaults: d)
        names.bind(.codex, accountID: "acct-a")
        names.bind(.codexAccount(slot: "codex-1111111"), accountID: "acct-b")
        names.setName("Main", for: .codex)
        names.setName("Team", for: .codexAccount(slot: "codex-1111111"))

        names.setName("   ", for: .codex)
        #expect(names.name(for: .codex) == nil)
        #expect(names.name(for: .codexAccount(slot: "codex-1111111")) == "Team")
    }

    /// A first-row name belongs to the account, not the row: a different login
    /// on the same row shows the default, and the name returns with its account.
    @Test func aNameNeverMovesToAnotherLogin() throws {
        let (d, cleanUp) = try defaults()
        defer { cleanUp() }
        let names = AccountNames(defaults: d)
        names.bind(.claude, accountID: "uuid-a")
        names.setName("Mine", for: .claude)

        names.bind(.claude, accountID: "uuid-x")
        #expect(names.name(for: .claude) == nil)
        #expect(!names.canRename(.cursor))

        names.bind(.claude, accountID: nil)       // no identity: cannot rename
        #expect(!names.canRename(.claude))
        names.setName("Ignored", for: .claude)
        #expect(names.name(for: .claude) == nil)

        names.bind(.claude, accountID: "uuid-a")
        #expect(names.name(for: .claude) == "Mine")
        // Same uuid connected as an extra: same account, same name.
        names.bind(.claudeConnected(uuid: "uuid-a"), accountID: "uuid-a")
        #expect(names.name(for: .claudeConnected(uuid: "uuid-a")) == "Mine")
        // Claude and Codex identities never collide.
        names.bind(.codex, accountID: "uuid-a")
        #expect(names.name(for: .codex) == nil)
    }

    @Test func storedDataHoldsNoAccountIDsOrProviderIDs() throws {
        let (d, cleanUp) = try defaults()
        defer { cleanUp() }
        let names = AccountNames(defaults: d)
        names.bind(.claudeConnected(uuid: "uuid-secret-b"), accountID: "uuid-secret-b")
        names.setName("Work", for: .claudeConnected(uuid: "uuid-secret-b"))
        let stored = "\(d.dictionary(forKey: AccountNames.key) ?? [:])"
        #expect(stored.contains("Work"))
        #expect(!stored.contains("uuid-secret-b"))
        #expect(!stored.contains("claudeConnected"))
    }

    @Test func renamingIsObservedImmediately() throws {
        let (d, cleanUp) = try defaults()
        defer { cleanUp() }
        let names = AccountNames(defaults: d)
        names.bind(.claude, accountID: "uuid-a")
        let changed = Flag()
        withObservationTracking { _ = names.name(for: .claude) } onChange: { changed.set() }
        names.setName("Personal", for: .claude)
        #expect(changed.value)
    }

    @Test func menuBarTooltipNamesTheShownAccounts() {
        let b = ProviderID.claudeConnected(uuid: "uuid-b")
        let tip = StatusBarLabelView.tooltip(shown: [.claude, b], name: { $0 == b ? "Work" : "Claude" })
        #expect(tip == "Byte Pulse — Claude, Work")
        #expect(StatusBarLabelView.tooltip(shown: [], name: { _ in "x" }) == "Byte Pulse — AI usage")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}
