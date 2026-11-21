import Foundation

/// Which accounts get a panel tab: exactly those whose Panel switch is on
/// (JSB-112). No fallback - an empty list means Joel hid every account, and
/// showing them all would ignore that.
enum PanelTabs {
    static let emptyMessage = "No account is shown in the panel. Turn on Panel for an account in Settings > Accounts."

    static func visible(enabled: [ProviderID]) -> [ProviderID] {
        enabled
    }

    static func selection(selected: ProviderID, tabs: [ProviderID]) -> ProviderID? {
        tabs.contains(selected) ? selected : tabs.first
    }
}
