import Foundation
import Testing
@testable import Pulse

// JSB-112: "Show idle accounts" puts a selected account with real, measured
// zero usage in the menu bar. Off by default (old behaviour).
@Suite("Menu bar: show idle accounts (JSB-112)")
@MainActor
struct MenuBarIdleAccountsTests {
    private func idleSnapshot(_ id: ProviderID) -> UsageSnapshot {
        var s = UsageSnapshot(providerID: id)
        s.primary = CodexLimitWindows.fiveHour(utilization: 0, resetsAt: nil, windowDuration: 18000)
        s.secondary = CodexLimitWindows.weekly(utilization: 0, resetsAt: nil, windowDuration: 604800)
        return s
    }

    @Test func idleAccountsAppearOnlyWhenTheSwitchIsOnAndUsageIsMeasured() {
        let busy = ProviderID.claude
        let idle = ProviderID.codexAccount(slot: "codex-1111111")
        let hidden = ProviderID.claudeConnected(uuid: "uuid-hidden")
        let unknown = ProviderID.claudeConnected(uuid: "uuid-unknown")
        let disconnected = ProviderID.codexAccount(slot: "codex-2222222")
        let failing = ProviderID.cursor
        let signingOut = ProviderID.gemini

        let store = UsageStore()
        var active = idleSnapshot(busy); active.primary?.utilization = 30
        store.apply(active)
        store.apply(idleSnapshot(idle))
        store.apply(idleSnapshot(hidden))
        // `unknown` never loaded: no snapshot at all.
        store.applyNotConnected(disconnected, hint: "Disconnected")
        store.apply(idleSnapshot(failing)); store.applyError(failing, .network(description: "offline"))
        // First failed sign-in probe keeps the old snapshot: still not shown.
        store.apply(idleSnapshot(signingOut)); store.applyNotConnected(signingOut, hint: "Signed out")

        let selected = [busy, idle, unknown, disconnected, failing, signingOut]  // `hidden`: Menu icon off

        #expect(StatusBarLabelView.menuBarAccounts(selected: selected, store: store, showIdle: false) == [busy])
        #expect(StatusBarLabelView.menuBarAccounts(selected: selected, store: store, showIdle: true) == [busy, idle])
    }

    @Test func switchIsOffByDefaultAndPersists() throws {
        let suite = "pulse-tests-idle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = SettingsStore(defaults: defaults, providers: [.claude])
        #expect(first.showIdleAccounts == false)
        first.showIdleAccounts = true

        let relaunched = SettingsStore(defaults: defaults, providers: [.claude])
        #expect(relaunched.showIdleAccounts == true)
    }
}
