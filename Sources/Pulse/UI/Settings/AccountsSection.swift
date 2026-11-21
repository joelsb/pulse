import AppKit
import SwiftUI

/// Settings > Accounts (JSB-112, approved layout A): one group per provider,
/// one row per account, each with its own Panel (tab) and Menu icon switch.
///
/// Claude and Codex accept further accounts through their existing browser
/// sign-in; Cursor, Copilot and Gemini show only the login their own tool
/// holds on this Mac, with the reason (`AccountCapability`). Pulse never signs
/// out, rewrites or deletes those tool logins or their folders: Disconnect
/// only deletes Pulse's own Keychain grant for an account it connected.
struct AccountsSection: View {
    let environment: AppEnvironment

    @State private var claudeEntries: [ClaudeAccountEntry] = []
    @State private var codexEntries: [CodexAccountEntry] = []
    /// The provider group running a browser sign-in, if any.
    @State private var busy: ProviderID?
    @State private var task: Task<Void, Never>?
    @State private var notes: [ProviderID: Note] = [:]
    @State private var confirm: Confirm?
    @State private var relaunchNeeded = false
    /// Whether Pulse holds its own grant for the first Claude / Codex account.
    @State private var primaryGrant: [ProviderID: Bool] = [:]
    /// The row being renamed and its unsaved text.
    @State private var renaming: ProviderID?
    @State private var draft = ""

    struct Note: Equatable { var text: String; var isError: Bool }

    struct Confirm: Identifiable {
        enum Kind { case disconnect, remove, signOutPulse }
        let account: ProviderID
        let kind: Kind
        let name: String
        var id: String { account.rawValue + "\(kind)" }
    }

    private var settings: SettingsStore { environment.settings }
    private var store: UsageStore { environment.store }

    var body: some View {
        ForEach(ProviderID.builtIns) { family in
            Section {
                ForEach(AccountRow.rows(
                    family: family,
                    registered: ProviderID.allCases,
                    claude: claudeEntries,
                    codex: codexEntries
                )) { row in
                    rowView(row)
                }
                if let note = notes[family] {
                    Text(note.text)
                        .font(.system(size: 11))
                        .foregroundStyle(note.isError ? PulseColor.critical : .secondary)
                }
                if relaunchNeeded, AccountCapability.canAddAccounts(family) {
                    HStack {
                        Text("New accounts get their tab and menu icon at the next launch.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch Pulse", action: Self.relaunch).controlSize(.small)
                    }
                }
            } header: {
                header(family)
            } footer: {
                if let reason = AccountCapability.unavailableReason(family) {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await reload() }
        .alert(item: $confirm) { item in
            Alert(
                title: Text(Self.confirmTitle(item)),
                message: Text(Self.confirmMessage(item)),
                primaryButton: .destructive(Text(Self.confirmButton(item))) { perform(item) },
                secondaryButton: .cancel { note(AccountRow.family(of: item.account), "Cancelled. Nothing changed.") }
            )
        }
    }

    // MARK: - Pieces

    private func header(_ family: ProviderID) -> some View {
        HStack {
            Text(environment.descriptor(for: family).name)
            Spacer()
            if AccountCapability.canAddAccounts(family) {
                if busy == family {
                    ProgressView().controlSize(.mini)
                    Button("Cancel") { task?.cancel() }.controlSize(.small)
                } else {
                    Button("Add account…") { add(family) }
                        .controlSize(.small)
                        .disabled(busy != nil)
                        .help("Signs in another account in your browser. The accounts already connected stay signed in.")
                }
            }
        }
    }

    private func displayName(_ row: AccountRow) -> String {
        environment.accountNames.name(for: row.id) ?? row.name
    }

    private func rowView(_ row: AccountRow) -> some View {
        AccountRowView(
            row: row,
            title: displayName(row),
            editor: renaming == row.id ? AnyView(renameEditor(row)) : nil,
            accessory: AnyView(renameButton(row)),
            subtitle: subtitle(row),
            panel: panelBinding(row.id),
            menu: menuBinding(row.id)
        ) { actions(row) }
    }

    private func renameEditor(_ row: AccountRow) -> some View {
        HStack(spacing: 6) {
            TextField("Name", text: $draft, prompt: Text(row.name))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .onSubmit { saveName(row) }
            Button("Cancel") { renaming = nil }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            Button("Save") { saveName(row) }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func saveName(_ row: AccountRow) {
        environment.accountNames.setName(draft, for: row.id)
        renaming = nil
    }

    @ViewBuilder
    private func renameButton(_ row: AccountRow) -> some View {
        if AccountRow.family(of: row.id) == .claude || AccountRow.family(of: row.id) == .codex {
            let known = environment.accountNames.canRename(row.id)
            Button("Rename…") {
                draft = environment.accountNames.name(for: row.id) ?? ""
                renaming = row.id
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!known || renaming != nil)
            .help(known
                ? "A name only Pulse uses, kept for this account on this Mac. Leave it empty to go back to the default."
                : "Pulse doesn't know which account this is yet. Sign in first.")
        }
    }

    @ViewBuilder
    private func actions(_ row: AccountRow) -> some View {
        switch row.kind {
        case .local:
            // The first account: Pulse may hold its own grant for it (Claude,
            // Codex). Signing that grant out never touches the tool's login.
            if row.id == .claude || row.id == .codex {
                let hasGrant = primaryGrant[row.id] == true
                Button(hasGrant ? "Reconnect…" : "Sign in…") { signInPrimary(row.id) }
                    .controlSize(.small)
                    .disabled(busy != nil)
                    .help("Pulse's own sign-in for this account, refreshed by Pulse instead of the tool.")
                if hasGrant {
                    Button("Sign out of Pulse…") { confirm = Confirm(account: row.id, kind: .signOutPulse, name: displayName(row)) }
                        .controlSize(.small)
                        .foregroundStyle(PulseColor.critical)
                }
            }
        case .connected(let disconnected):
            Button("Reconnect…") { reconnect(row) }
                .controlSize(.small)
                .disabled(busy != nil)
            if disconnected {
                Button("Remove…") { confirm = Confirm(account: row.id, kind: .remove, name: displayName(row)) }
                    .controlSize(.small)
                    .foregroundStyle(PulseColor.critical)
            } else {
                Button("Disconnect…") { confirm = Confirm(account: row.id, kind: .disconnect, name: displayName(row)) }
                    .controlSize(.small)
                    .foregroundStyle(PulseColor.critical)
            }
        case .pendingRelaunch:
            EmptyView()
        }
    }

    private func subtitle(_ row: AccountRow) -> String {
        switch row.kind {
        case .pendingRelaunch:
            return "Added · appears after a relaunch"
        case .connected(true):
            return "Disconnected"
        case .local:
            let source = primaryGrant[row.id] == true
                ? AccountCapability.pulseSource(row.id)
                : AccountCapability.localSource(row.id)
            return source + " · " + status(row.id)
        case .connected(false):
            return status(row.id)
        }
    }

    private func status(_ id: ProviderID) -> String {
        let record = store.record(for: id)
        switch record.displayState {
        case .data:
            let plan = record.snapshot?.plan.map { "\($0) · " } ?? ""
            return plan + (record.snapshot?.accountLabel ?? "Connected")
        case .notConnected(let hint): return hint
        case .error(let error): return error.userMessage
        case .loading: return "Checking…"
        }
    }

    private func panelBinding(_ id: ProviderID) -> Binding<Bool> {
        Binding(
            get: { settings.enabledProviders.contains(id) },
            set: { on in
                if on {
                    settings.enabledProviders = ProviderID.allCases.filter { settings.enabledProviders.contains($0) || $0 == id }
                } else {
                    settings.enabledProviders.removeAll { $0 == id }
                }
                environment.scheduler.syncLoops()
            }
        )
    }

    private func menuBinding(_ id: ProviderID) -> Binding<Bool> {
        Binding(
            get: { settings.menuBarProviders.contains(id) },
            set: { on in
                if on { settings.menuBarProviders.insert(id) } else { settings.menuBarProviders.remove(id) }
                environment.scheduler.syncLoops()
            }
        )
    }

    // MARK: - Actions

    private func note(_ family: ProviderID, _ text: String, error: Bool = false) {
        notes[family] = Note(text: text, isError: error)
    }

    private func reload() async {
        claudeEntries = await environment.claudeAccounts.entries()
        codexEntries = await environment.codexAccounts.entries()
        primaryGrant[.claude] = await environment.claudeAccounts.primaryHasPulseGrant()
        primaryGrant[.codex] = await environment.codexOAuthStore.hasGrant()
        await environment.bindAccountNames()
    }

    private func signInPrimary(_ family: ProviderID) {
        let environment = environment
        run(family) {
            if family == .claude {
                switch try await environment.claudeAccounts.signInPrimary(authorize: {
                    try await environment.pulseOAuthStore.authorize { NSWorkspace.shared.open($0) }
                }) {
                case .signedIn(let label): return "Signed in as \(label ?? "this Mac's Claude account")."
                case .mismatch(let label):
                    return "The browser signed in as \(label ?? "another account"), not this Mac's Claude Code account. Use Add account… for it. Nothing changed."
                case .unknownPrimary:
                    return "No Claude Code account found on this Mac to sign in for. Use Add account… instead. Nothing changed."
                }
            }
            switch try await environment.codexAccounts.signInPrimary(signIn: {
                try await CodexOAuthClient().signIn { NSWorkspace.shared.open($0) }
            }, primary: environment.codexOAuthStore) {
            case .signedIn(let label): return "Signed in as \(label ?? "the first Codex account")."
            case .duplicate(let label): return "\(label ?? "That account") is already connected below. Nothing changed."
            }
        }
    }

    private static func confirmTitle(_ item: Confirm) -> String {
        switch item.kind {
        case .disconnect: "Disconnect \(item.name)?"
        case .remove: "Remove \(item.name)?"
        case .signOutPulse: "Sign \(item.name) out of Pulse?"
        }
    }

    private static func confirmMessage(_ item: Confirm) -> String {
        switch item.kind {
        case .disconnect:
            "Pulse deletes its own sign-in for this account and stops reading its usage. The account itself and every other sign-in on this Mac stay as they are."
        case .remove:
            "Pulse forgets this account: its row, tab and menu icon block."
        case .signOutPulse:
            "Pulse deletes its own sign-in for this account and reads \(AccountCapability.localSource(item.account).lowercased()) again. That login is not touched."
        }
    }

    private static func confirmButton(_ item: Confirm) -> String {
        switch item.kind {
        case .disconnect: "Disconnect"
        case .remove: "Remove"
        case .signOutPulse: "Sign out of Pulse"
        }
    }

    private func run(_ family: ProviderID, _ work: @escaping @MainActor () async throws -> String) {
        guard busy == nil else { return }
        busy = family
        notes[family] = nil
        task = Task { @MainActor in
            defer { busy = nil }
            do {
                note(family, try await work())
            } catch is CancellationError {
                note(family, "Cancelled. Nothing changed.")
            } catch {
                note(family, Self.failure(error, family: family), error: true)
            }
            await reload()
            environment.scheduler.refreshAll()
        }
    }

    private func add(_ family: ProviderID) {
        let environment = environment
        run(family) {
            switch family {
            case .claude:
                switch try await environment.claudeAccounts.add(authorize: {
                    try await environment.pulseOAuthStore.authorize { NSWorkspace.shared.open($0) }
                }) {
                case .added(let label):
                    relaunchNeeded = true
                    return "Added \(label ?? "the account"). Relaunch for its tab and menu icon."
                case .duplicate(let label):
                    return "\(label ?? "That account") is already connected. Nothing changed."
                }
            default:
                switch try await environment.codexAccounts.add(signIn: {
                    try await CodexOAuthClient().signIn { NSWorkspace.shared.open($0) }
                }) {
                case .added(let label):
                    relaunchNeeded = true
                    return "Added \(label ?? "the account"). Relaunch for its tab and menu icon."
                case .duplicate(let label):
                    return "\(label ?? "That account") is already connected. Nothing changed."
                }
            }
        }
    }

    private func reconnect(_ row: AccountRow) {
        let environment = environment
        let family = AccountRow.family(of: row.id)
        run(family) {
            let outcomeLabel: String?
            let matched: Bool
            if let uuid = row.claudeUUID {
                switch try await environment.claudeAccounts.reconnect(uuid: uuid, authorize: {
                    try await environment.pulseOAuthStore.authorize { NSWorkspace.shared.open($0) }
                }) {
                case .reconnected(let label): (outcomeLabel, matched) = (label, true)
                case .mismatch(let label): (outcomeLabel, matched) = (label, false)
                }
            } else if let slot = row.codexSlot {
                switch try await environment.codexAccounts.reconnect(slot: slot, signIn: {
                    try await CodexOAuthClient().signIn { NSWorkspace.shared.open($0) }
                }) {
                case .reconnected(let label): (outcomeLabel, matched) = (label, true)
                case .mismatch(let label): (outcomeLabel, matched) = (label, false)
                }
            } else {
                return "Nothing to reconnect."
            }
            return matched
                ? "\(displayName(row)) reconnected."
                : "The browser signed in as \(outcomeLabel ?? "another account"), not \(displayName(row)). Nothing changed."
        }
    }

    private func perform(_ item: Confirm) {
        let family = AccountRow.family(of: item.account)
        let row = AccountRow.rows(family: family, registered: ProviderID.allCases, claude: claudeEntries, codex: codexEntries)
            .first { $0.id == item.account }
        Task { @MainActor in
            do {
                switch item.kind {
                case .signOutPulse:
                    if item.account == .claude { await environment.claudeAccounts.forgetPrimary() }
                    if item.account == .codex { await environment.codexOAuthStore.forget() }
                    note(family, "\(item.name) signed out of Pulse.")
                case .disconnect:
                    if let uuid = row?.claudeUUID { await environment.claudeAccounts.disconnect(uuid: uuid) }
                    if let slot = row?.codexSlot { await environment.codexAccounts.disconnect(slot: slot) }
                    note(family, "\(item.name) disconnected.")
                case .remove:
                    if let uuid = row?.claudeUUID { try await environment.claudeAccounts.remove(uuid: uuid) }
                    if let slot = row?.codexSlot { try await environment.codexAccounts.remove(slot: slot) }
                    settings.enabledProviders.removeAll { $0 == item.account }
                    settings.menuBarProviders.remove(item.account)
                    environment.scheduler.syncLoops()
                    note(family, "\(item.name) removed.")
                }
            } catch {
                note(family, Self.failure(error, family: family), error: true)
            }
            await reload()
            environment.scheduler.refreshAll()
        }
    }

    private static func failure(_ error: Error, family: ProviderID) -> String {
        switch error {
        case ClaudeAccounts.Failure.usageCheckFailed, CodexAccounts.AddFailure.usageCheckFailed:
            return "Couldn’t read that account’s usage. Nothing saved."
        case CodexAccounts.AddFailure.unidentified:
            return "Couldn’t identify that account. Nothing saved."
        case CodexAccounts.AddFailure.slotCheckFailed:
            return "Couldn’t confirm a free Keychain slot. Nothing saved."
        case ClaudeAccounts.Failure.stillConnected, CodexAccounts.AddFailure.stillConnected:
            return "Disconnect the account before removing it."
        default:
            return family == .claude ? SignInMessages.claude(error) : SignInMessages.codex(error)
        }
    }

    /// Starts a fresh instance of this app, then quits this one.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// The layout of one account row: name, menu bar code, status, the two
/// independent switches and the row's actions.
struct AccountRowView<Actions: View>: View {
    let row: AccountRow
    /// The account's display name (Joel's own name when set).
    var title: String? = nil
    /// Shown in place of the title while the row is being renamed.
    var editor: AnyView? = nil
    /// Small control after the menu bar code (Rename…).
    var accessory: AnyView? = nil
    let subtitle: String
    let panel: Binding<Bool>
    let menu: Binding<Bool>
    @ViewBuilder var actions: Actions

    @ViewBuilder
    private var switches: some View {
        if row.kind != .pendingRelaunch {
            labeledSwitch("Panel", isOn: panel)
            labeledSwitch("Menu icon", isOn: menu)
        }
    }

    /// A compact switch with its text beside it. NOT `Toggle(...).fixedSize()`:
    /// inside a grouped Form a toggle lays out as a full-width row, and fixing
    /// that ideal size made the whole Form wider than the window, cutting off
    /// every section on both sides.
    private func labeledSwitch(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 4) {
            Toggle(title, isOn: isOn).labelsHidden()
            Text(title).onTapGesture { isOn.wrappedValue.toggle() }
        }
        .fixedSize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(PulseColor.accent(row.id)).frame(width: 7, height: 7)
                if let editor {
                    editor
                } else {
                    // One line, truncated: a long name must never widen the
                    // Form past the window (it then clips every section).
                    Text(title ?? row.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(row.code)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(PulseColor.hairline))
                    .help("Menu bar code")
                if editor == nil, let accessory { accessory }
            }
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            // Switches and buttons on one line when they fit the window,
            // otherwise buttons on a second line (never wider than the Form).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    switches
                    Spacer(minLength: 4)
                    actions
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) { switches }
                    HStack(spacing: 6) { actions }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.vertical, 2)
    }
}

/// One row of Settings > Accounts, derived from the registry (what has a
/// provider this launch) and the two account indexes (what Joel connected).
struct AccountRow: Identifiable, Equatable {
    enum Kind: Equatable {
        /// The login the provider's own tool holds on this Mac.
        case local
        /// An account connected in Settings, with or without Pulse's grant.
        case connected(disconnected: Bool)
        /// Connected this session; its provider exists from the next launch.
        case pendingRelaunch
    }

    let id: ProviderID
    let name: String
    let code: String
    let kind: Kind
    var claudeUUID: String?
    var codexSlot: String?

    static func family(of id: ProviderID) -> ProviderID {
        id.isClaudeConnected ? .claude : id.isCodexAccount ? .codex : id
    }

    static func rows(
        family: ProviderID,
        registered: [ProviderID],
        claude: [ClaudeAccountEntry],
        codex: [CodexAccountEntry]
    ) -> [AccountRow] {
        let firstCode: [ProviderID: String] = [.claude: "CLA", .codex: "CDX", .cursor: "CUR", .copilot: "COP", .gemini: "GEM"]
        let names: [ProviderID: String] = [.claude: "Claude", .codex: "Codex", .cursor: "Cursor", .copilot: "Copilot", .gemini: "Gemini"]
        var rows = [AccountRow(id: family, name: names[family] ?? family.rawValue, code: firstCode[family] ?? "", kind: .local)]
        func connected(id: ProviderID, position: Int, label: String?, disconnected: Bool) -> AccountRow {
            let prefix = String((firstCode[family] ?? "").prefix(2))
            return AccountRow(
                id: id,
                name: "\(names[family] ?? "") \(label ?? String(position))",
                code: "\(prefix)\(position)",
                kind: registered.contains(id) ? .connected(disconnected: disconnected) : .pendingRelaunch
            )
        }
        if family == .claude {
            for (i, e) in claude.enumerated() {
                var row = connected(id: .claudeConnected(uuid: e.uuid), position: i + 2, label: e.label, disconnected: e.disconnected)
                row.claudeUUID = e.uuid
                rows.append(row)
            }
        } else if family == .codex {
            for (i, e) in codex.enumerated() {
                var row = connected(id: .codexAccount(slot: e.slot), position: i + 2, label: e.label, disconnected: e.disconnected)
                row.codexSlot = e.slot
                rows.append(row)
            }
        }
        return rows
    }
}

/// What each provider can honestly offer in Settings > Accounts.
enum AccountCapability {
    static func canAddAccounts(_ family: ProviderID) -> Bool {
        family == .claude || family == .codex
    }

    /// The first row when Pulse holds its own grant for it.
    static func pulseSource(_ family: ProviderID) -> String {
        switch family {
        case .claude: "Pulse sign-in for this Mac's Claude Code account"
        case .codex: "Pulse sign-in (first Codex account)"
        default: localSource(family)
        }
    }

    static func localSource(_ family: ProviderID) -> String {
        switch family {
        case .claude: "This Mac's Claude Code login"
        case .codex: "This Mac's Codex login"
        case .cursor: "The Cursor app's login"
        case .copilot: "GitHub Copilot's login"
        case .gemini: "gemini-cli's login"
        default: "Local login"
        }
    }

    /// Why a provider shows only its tool's own login. Each names the concrete
    /// missing piece; none claims the provider forbids more accounts.
    static func unavailableReason(_ family: ProviderID) -> String? {
        switch family {
        case .cursor:
            "One account only: Pulse has no Cursor sign-in of its own. It reads the session the Cursor app keeps on this Mac, so it can only show the account signed in there."
        case .copilot:
            "One account only: Pulse reads GitHub Copilot's own sign-in on this Mac and has no GitHub sign-in of its own yet. Whether Copilot's usage can be read with a grant made for Pulse is not established."
        case .gemini:
            "One account only: Pulse reads gemini-cli's sign-in on this Mac and has no Google sign-in of its own yet. Whether a separate Google grant for Pulse can read Gemini quotas is not established."
        default:
            nil
        }
    }
}
