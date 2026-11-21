import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let environment: AppEnvironment

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var settings: SettingsStore { environment.settings }
    private var store: UsageStore { environment.store }

    /// Shipped version from the bundle's Info.plist — the single source of
    /// truth (set by build-app.sh), so the About row never drifts from the build.
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        settings.launchAtLogin = newValue
                        launchAtLogin = settings.launchAtLogin
                    }

                Picker("Refresh every", selection: $settings.refreshInterval) {
                    Text("30 seconds").tag(TimeInterval(30))
                    Text("1 minute").tag(TimeInterval(60))
                    Text("2 minutes").tag(TimeInterval(120))
                    Text("5 minutes").tag(TimeInterval(300))
                }

                Picker("Limit gauges show", selection: $settings.gaugeDirection) {
                    ForEach(SettingsStore.GaugeDirection.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(settings.gaugeDirection == .used
                    ? "Bars fill left to right as you spend."
                    : "Bars drain right to left like a fuel gauge.")
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)

                Toggle(isOn: $settings.showPaceMarker) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show pace marker")
                        Text("A tick on each gauge marking how far through the window you are, so the bar can be read against the clock: ahead of it means you are burning the limit faster than it refills.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            AccountsSection(environment: environment)

            Section("Panel") {
                Picker("Show", selection: $settings.panelMode) {
                    ForEach(SettingsStore.PanelMode.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(settings.panelMode == .simple
                    ? "One ring per provider for the live session window, its weekly bar underneath, and CPU + memory for this Mac. Rates, history and token costs are one click away (⌘E, or the button left of the analytics icon)."
                    : "Every card each provider publishes: session and weekly gauges, per-model caps, usage rate, daily history, token costs. ⌘E switches to the short version.")
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)

                Picker("Providers", selection: $settings.panelLayout) {
                    ForEach(SettingsStore.PanelLayout.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(settings.panelMode == .simple)
                Text(settings.panelLayout == .columns
                    ? "One click shows every enabled provider at once, side by side. The panel widens by one column per provider, capped at what the screen holds."
                    : "One provider at a time, switched with the tab bar (⌘1…⌘4, arrow keys).")
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)

                Toggle(isOn: $settings.showSystemStats) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show this Mac's stats")
                        Text("A sidebar left of the providers with CPU, memory pressure, swap and free disk — what decides whether the machine can take another local agent, next to what decides whether the account can.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $settings.showSystemProcesses) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("List top processes")
                        Text("The four heaviest processes by CPU, read from `ps` while the panel is open.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.showSystemStats)
            }

            Section("Menu Bar") {
                Picker("Style", selection: $settings.menuBarStyle) {
                    Text("Provider stats").tag(SettingsStore.MenuBarStyle.stats)
                    Text("Icon only").tag(SettingsStore.MenuBarStyle.icon)
                }
                .pickerStyle(.segmented)

                if settings.menuBarStyle == .stats {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Second line", selection: $settings.menuBarSecondaryRow) {
                            ForEach(SettingsStore.MenuBarSecondaryRow.allCases, id: \.self) { row in
                                Text(row.title).tag(row)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text("The top line is always the session window. Below it: the 7-day limit, or how the session percentage moved in the last hour.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Text("Which accounts appear in the menu bar is set per account under Accounts.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                sourceToggle(
                    isOn: $settings.countProviderLogs,
                    title: "Provider sessions",
                    detail: "What the provider's own CLI logged — `~/.claude/projects`, `~/.codex/sessions`."
                )
                sourceToggle(
                    isOn: $settings.countJcodeSessions,
                    title: "jcode sessions",
                    detail: "`~/.jcode/sessions`. jcode runs against these same accounts, so its tokens are billed here, not somewhere else."
                )
                sourceToggle(
                    isOn: $settings.countPiSessions,
                    title: "pi sessions",
                    detail: "`~/.pi/agent/sessions`. Same account, different harness."
                )
            } header: {
                Text("Count Tokens From")
            } footer: {
                Text("Applies to the token card, the daily chart and the breakdown together. Limits and quotas are never affected: they come from the provider's API and belong to the account, whichever tool spent it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Usage Breakdown") {
                Toggle(isOn: $settings.useSessionTitles) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show session titles")
                        Text("Uses the short titles your CLI already generates (e.g. Claude's), read only on your Mac. Off keeps the breakdown strictly content-blind.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Byte Pulse").font(.system(size: 13, weight: .semibold))
                        Text("AI usage in your menu bar — a Byte product.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(appVersion)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
    }

    /// One "count this source" switch. Every change forces an immediate
    /// refresh: the whole point of the switch is to watch the totals move, and
    /// waiting up to five minutes for the next tick reads as a broken toggle.
    private func sourceToggle(isOn: Binding<Bool>, title: String, detail: String) -> some View {
        Toggle(isOn: Binding(
            get: { isOn.wrappedValue },
            set: { newValue in
                isOn.wrappedValue = newValue
                environment.scheduler.refreshAll()
            }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(.init(detail))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

}

/// Human messages for a failed browser sign-in. Never include token material:
/// every failure these flows throw is a status code, a timeout or a parse error.
enum SignInMessages {
    /// Never includes token material — there is none in any error this flow
    /// can throw (see `ClaudeOAuthClient`/`PulseOAuthStore`: every failure
    /// path is a status code, a timeout, or a parse failure).
    static func claude(_ error: Error) -> String {
        if let fetchError = error as? ProviderFetchError { return fetchError.userMessage }
        if let tokenEndpointError = error as? ClaudeOAuthClient.TokenEndpointError {
            switch tokenEndpointError {
            case .invalidGrant: return "Sign-in was rejected - try again"
            case .other(let status): return "Sign-in failed (\(status))"
            }
        }
        if let listenerFailure = error as? LoopbackCallbackListener.Failure {
            switch listenerFailure {
            case .timeout: return "Timed out waiting for the browser"
            case .deniedByProvider: return "Sign-in was declined"
            case .invalidCallback: return "Unexpected sign-in response"
            case .listenerFailed: return "Couldn’t open a local port - port 53810 busy?"
            }
        }
        // `PulseOAuthStore.signIn` persists the grant right after a
        // successful browser round trip - a Keychain write failure this late
        // used to fall through to the same bare "Sign-in failed" as a 400
        // from the token endpoint, which is why a human saw one useless
        // string for two unrelated causes (round 5). Named here instead.
        if let keychainFailure = error as? KeychainWriter.Failure {
            switch keychainFailure {
            case .verificationFailed: return "Sign-in succeeded, but saving it to the Keychain failed - try again"
            case .failed: return "Sign-in succeeded, but the Keychain didn’t respond - try again"
            case .lineTooLong: return "Sign-in succeeded, but the saved data was too long for the Keychain - this is a bug, not a retry-and-hope"
            }
        }
        return "Sign-in failed"
    }

    /// Never includes token material, same discipline as `claude(_:)`.
    static func codex(_ error: Error) -> String {
        if let fetchError = error as? ProviderFetchError { return fetchError.userMessage }
        if let tokenEndpointError = error as? CodexOAuthClient.TokenEndpointError {
            switch tokenEndpointError {
            case .invalidGrant: return "Sign-in was rejected - try again"
            case .other(let status): return "Sign-in failed (\(status))"
            }
        }
        if let listenerFailure = error as? LoopbackCallbackListener.Failure {
            switch listenerFailure {
            case .timeout: return "Timed out waiting for the browser"
            case .deniedByProvider: return "Sign-in was declined"
            case .invalidCallback: return "Unexpected sign-in response"
            // Constraint 1: port 1455 is the Codex CLI's OWN login port — a
            // bind failure here almost always means a `codex login` is
            // running at the same time, not a generic "port busy" cause.
            case .listenerFailed: return "Couldn’t open port 1455 - a Codex CLI login may be in progress"
            }
        }
        if let keychainFailure = error as? KeychainWriter.Failure {
            switch keychainFailure {
            case .verificationFailed: return "Sign-in succeeded, but saving it to the Keychain failed - try again"
            case .failed: return "Sign-in succeeded, but the Keychain didn’t respond - try again"
            case .lineTooLong: return "Sign-in succeeded, but the saved data was too long for the Keychain - this is a bug, not a retry-and-hope"
            }
        }
        return "Sign-in failed"
    }
}
