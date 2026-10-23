import Foundation
import Testing
@testable import Pulse

@Suite("Glance window placement")
@MainActor
struct ProviderGlanceCardTests {
    @Test func codexWeeklyOnlyKeepsEmptySessionRingAboveWeeklyBar() throws {
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(#"""
        {"plan_type":"prolite","rate_limit":{
          "primary_window":{"limit_window_seconds":604800,"used_percent":55,"reset_after_seconds":530114},
          "secondary_window":null}}
        """#.utf8))
        let mapped = CodexUsageAPI.limitWindows(
            from: response, now: Date(timeIntervalSince1970: 1_765_000_000)
        )
        var snapshot = UsageSnapshot(providerID: .codex)
        snapshot.primary = mapped.primary
        snapshot.secondary = mapped.secondary

        let placement = ProviderGlanceCard.windows(for: snapshot)

        // No session value or reset is invented, and the real weekly data stays below.
        #expect(placement.ring == nil)
        #expect(placement.bar?.id == "weekly")
        #expect(placement.bar?.title == "Weekly Limit")
        #expect(placement.bar?.utilization == 55)
        #expect(placement.bar?.windowDuration == 604800)
        #expect(placement.bar?.resetsAt == Date(timeIntervalSince1970: 1_765_530_114))
    }

    @Test func traditionalCodexKeepsSessionRingAndWeeklyBar() throws {
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: Data(#"""
        {"plan_type":"plus","rate_limit":{
          "primary_window":{"limit_window_seconds":18000,"used_percent":42,"reset_after_seconds":9960},
          "secondary_window":{"limit_window_seconds":604800,"used_percent":28,"reset_at":1765900000}}}
        """#.utf8))
        let mapped = CodexUsageAPI.limitWindows(
            from: response, now: Date(timeIntervalSince1970: 1_765_000_000)
        )
        var snapshot = UsageSnapshot(providerID: .codex)
        snapshot.primary = mapped.primary
        snapshot.secondary = mapped.secondary

        let placement = ProviderGlanceCard.windows(for: snapshot)

        #expect(placement.ring?.title == "5-Hour Session")
        #expect(placement.ring?.utilization == 42)
        #expect(placement.ring?.windowDuration == 18000)
        #expect(placement.ring?.resetsAt == Date(timeIntervalSince1970: 1_765_009_960))
        #expect(placement.bar?.title == "Weekly Limit")
        #expect(placement.bar?.utilization == 28)
        #expect(placement.bar?.resetsAt == Date(timeIntervalSince1970: 1_765_900_000))
    }

    @Test func claudeWeeklyOnlyStillFallsBackToWeeklyRing() {
        var snapshot = UsageSnapshot(providerID: .claude)
        snapshot.secondary = LimitWindow(
            id: "seven_day", title: "Weekly Limit", systemImage: "calendar",
            utilization: 35, resetsAt: Date(timeIntervalSince1970: 1_765_900_000),
            windowDuration: 604800
        )

        let placement = ProviderGlanceCard.windows(for: snapshot)

        #expect(placement.ring?.id == "seven_day")
        #expect(placement.ring?.title == "Weekly Limit")
        #expect(placement.ring?.utilization == 35)
        #expect(placement.ring?.resetsAt == Date(timeIntervalSince1970: 1_765_900_000))
        #expect(placement.bar == nil)
    }
}
