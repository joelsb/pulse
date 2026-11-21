import AppKit
import SwiftUI
import Testing
@testable import Pulse

// JSB-112 regression: one Accounts row wider than the Settings window made
// the whole grouped Form wider than the window, so every section was cut off
// on both sides. The rows below are the widest real combinations.
@Suite("Settings fits its window (JSB-112)")
@MainActor
struct SettingsGeometryTests {
    private func rows() -> some View {
        let b = ProviderID.claudeConnected(uuid: "uuid-b")
        let c = ProviderID.codexAccount(slot: "codex-1111111")
        let claude = AccountRow.rows(family: .claude, registered: [.claude, b], claude: [
            ClaudeAccountEntry(uuid: "uuid-b", label: "averyveryverylongname.for.testing@example-company.com"),
        ], codex: [])
        let codex = AccountRow.rows(family: .codex, registered: [.codex, c], claude: [],
                                    codex: [CodexAccountEntry(slot: "codex-1111111", accountID: "x", label: "te…@example.org")])
        func small(_ title: String) -> some View { Button(title) {}.controlSize(.small) }
        let rename = AnyView(Button("Rename…") {}.buttonStyle(.borderless).controlSize(.small))
        return Form {
            Section {
                AccountRowView(row: claude[0], title: "Claude", accessory: rename,
                               subtitle: "Pulse sign-in for this Mac's Claude Code account · Max 5× · averyveryverylongname@example.com",
                               panel: .constant(true), menu: .constant(true)) {
                    small("Reconnect…"); small("Sign out of Pulse…")
                }
                AccountRowView(row: claude[1], title: "Work account with a really long display name to stress layout", accessory: rename,
                               subtitle: "Pro · averyveryverylongname.for.testing@example-company.com",
                               panel: .constant(true), menu: .constant(false)) {
                    small("Reconnect…"); small("Disconnect…")
                }
            } header: { Text("Claude") }
            Section {
                AccountRowView(row: codex[1], title: "Team",
                               editor: AnyView(HStack(spacing: 6) {
                                   TextField("Name", text: .constant("Team"), prompt: Text(codex[1].name)).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                                   small("Cancel"); small("Save")
                               }),
                               subtitle: "Disconnected", panel: .constant(true), menu: .constant(true)) {
                    small("Reconnect…"); small("Remove…")
                }
            } header: { Text("Codex") }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.width)
    }

    /// The window integration as built: a hosting controller in an NSWindow
    /// at the Settings width. The Form's scroll view must not be wider than
    /// the window, nor start left of it.
    @Test func accountRowsFitTheSettingsWindow() throws {
        let host = NSHostingController(rootView: rows())
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: SettingsView.width, height: 600))
        host.view.layoutSubtreeIfNeeded()

        let scroll = try #require(Self.firstScrollView(in: host.view))
        let frame = scroll.convert(scroll.bounds, to: host.view)
        #expect(frame.minX >= -0.5)
        #expect(frame.width <= SettingsView.width + 0.5)
        #expect(host.sizeThatFits(in: NSSize(width: SettingsView.width, height: 10_000)).width <= SettingsView.width + 0.5)
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = firstScrollView(in: sub) { return found } }
        return nil
    }
}
