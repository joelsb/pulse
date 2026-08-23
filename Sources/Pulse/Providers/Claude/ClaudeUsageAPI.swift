import Foundation

/// The endpoint behind Claude Code's `/usage` view.
///
/// The response carries two generations of schema side by side:
///
/// - **Flat windows** keyed by name (`five_hour`, `seven_day`, `seven_day_opus`,
///   …). The key set is feature-flagged and grows over time, so decoding
///   iterates keys dynamically and keeps anything shaped like
///   `{utilization, resets_at}`.
/// - A structured **`limits` array** (`{kind, percent, resets_at, scope}`) that
///   is the only place model-scoped weekly caps such as **Fable** are reported
///   — they never appear as flat keys. Claude Code renders its
///   "Current week (Fable)" row from exactly this array.
struct ClaudeUsageAPI: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Model families whose scoped weekly cap is promoted to a full gauge card
    /// (`Gauges.tertiary`) instead of a compact "Model Limits" row. Matched
    /// case-insensitively against the API's `scope.model.display_name`, so the
    /// card follows whatever the frontier family is called. Mythos is the same
    /// tier as Fable (same model, different availability).
    static let featuredModelNames: Set<String> = ["fable", "mythos"]

    var http: HTTPClient

    func fetchUsage(accessToken: String) async throws -> ClaudeUsageResponse {
        let headers = [
            "Authorization": "Bearer \(accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1.0",
            "Accept": "application/json",
        ]
        let data = try await http.get(Self.endpoint, headers: headers)
        return try ClaudeUsageResponse.parse(data)
    }

    /// The gauges one usage response maps to.
    struct Gauges: Sendable, Equatable {
        /// 5-hour session window.
        var primary: LimitWindow?
        /// All-models weekly window.
        var secondary: LimitWindow?
        /// The featured model-scoped weekly cap (Fable), rendered as a full
        /// card beneath the weekly gauge.
        var tertiary: LimitWindow?
        /// Remaining per-model weekly caps, shown as compact rows once they
        /// carry signal.
        var extras: [LimitWindow]
    }

    static func limitWindows(from response: ClaudeUsageResponse) -> Gauges {
        // Session + weekly: the flat keys are authoritative; the structured
        // array backs them up should the flat keys ever disappear.
        let primary = response.windows["five_hour"].map {
            LimitWindow(
                id: "five_hour",
                title: "5-Hour Session",
                systemImage: "clock",
                utilization: $0.utilization,
                resetsAt: $0.resetsAt,
                windowDuration: 5 * 3600
            )
        } ?? response.limits.first(where: { $0.kind == "session" }).map {
            LimitWindow(
                id: "five_hour",
                title: "5-Hour Session",
                systemImage: "clock",
                utilization: $0.percent,
                resetsAt: $0.resetsAt,
                windowDuration: 5 * 3600
            )
        }
        let secondary = response.windows["seven_day"].map {
            LimitWindow(
                id: "seven_day",
                title: "Weekly Limit",
                systemImage: "calendar",
                utilization: $0.utilization,
                resetsAt: $0.resetsAt,
                windowDuration: 7 * 86400
            )
        } ?? response.limits.first(where: { $0.kind == "weekly_all" }).map {
            LimitWindow(
                id: "seven_day",
                title: "Weekly Limit",
                systemImage: "calendar",
                utilization: $0.percent,
                resetsAt: $0.resetsAt,
                windowDuration: 7 * 86400
            )
        }

        // Model-scoped weekly caps from the structured array. The featured
        // family (Fable) gets its own card as soon as the bucket is live —
        // used this week, or scheduled to reset — so an account that never
        // touches Fable keeps a quiet panel. The rest join the compact rows.
        var tertiary: LimitWindow?
        var extras: [LimitWindow] = []
        var scopedModelNames: Set<String> = []
        for limit in response.limits where limit.kind == "weekly_scoped" {
            guard let model = limit.modelName else { continue }
            let key = model.lowercased()
            guard scopedModelNames.insert(key).inserted else { continue }

            if tertiary == nil, featuredModelNames.contains(key) {
                guard limit.percent > 0 || limit.resetsAt != nil else { continue }
                tertiary = LimitWindow(
                    id: "weekly_scoped.\(key)",
                    title: "\(model) Weekly",
                    systemImage: "sparkle",
                    utilization: limit.percent,
                    resetsAt: limit.resetsAt,
                    windowDuration: 7 * 86400
                )
            } else if limit.percent > 0 {
                extras.append(
                    LimitWindow(
                        id: "weekly_scoped.\(key)",
                        title: "\(model) Weekly",
                        systemImage: "sparkles",
                        utilization: limit.percent,
                        resetsAt: limit.resetsAt,
                        windowDuration: 7 * 86400
                    )
                )
            }
        }

        // Legacy flat per-model keys, unless the structured array already
        // covers that model (it is the newer, more complete source).
        let legacyPerModel: [(key: String, model: String)] = [
            ("seven_day_opus", "Opus"),
            ("seven_day_sonnet", "Sonnet"),
        ]
        for (key, model) in legacyPerModel where !scopedModelNames.contains(model.lowercased()) {
            guard let window = response.windows[key], window.utilization > 0 else { continue }
            extras.append(
                LimitWindow(
                    id: key,
                    title: "\(model) Weekly",
                    systemImage: "sparkles",
                    utilization: window.utilization,
                    resetsAt: window.resetsAt,
                    windowDuration: 7 * 86400
                )
            )
        }
        return Gauges(primary: primary, secondary: secondary, tertiary: tertiary, extras: extras)
    }
}

struct ClaudeUsageResponse: Sendable, Equatable {
    struct Window: Sendable, Equatable {
        var utilization: Double
        var resetsAt: Date?
    }

    /// One entry of the structured `limits` array:
    /// `{kind, group, percent, severity, resets_at, scope, is_active}`.
    /// Only what the gauges need is kept.
    struct Limit: Sendable, Equatable {
        /// `session`, `weekly_all`, `weekly_scoped`, … (open set).
        var kind: String
        /// 0…100, same unit as the flat windows' `utilization`.
        var percent: Double
        var resetsAt: Date?
        /// `scope.model.display_name` for model-scoped limits ("Fable"),
        /// nil for unscoped or surface-scoped entries.
        var modelName: String?
    }

    /// Window key → window, for every flat response key that looks like one.
    var windows: [String: Window]
    /// The structured `limits` array, in response order. Empty on older
    /// responses that predate it.
    var limits: [Limit] = []

    /// Keys that carry a `utilization` field but are not rate-limit windows.
    private static let excludedKeys: Set<String> = ["extra_usage"]

    static func parse(_ data: Data) throws -> ClaudeUsageResponse {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ProviderFetchError.parsing(description: "oauth/usage: not JSON")
        }
        guard let root = object as? [String: Any] else {
            throw ProviderFetchError.parsing(description: "oauth/usage: unexpected top-level shape")
        }
        let iso = ClaudeISO8601()

        var windows: [String: Window] = [:]
        for (key, value) in root where !excludedKeys.contains(key) {
            guard let dict = value as? [String: Any],
                  let utilization = (dict["utilization"] as? NSNumber)?.doubleValue
            else { continue }
            let resetsAt = (dict["resets_at"] as? String).flatMap(iso.date(from:))
            windows[key] = Window(utilization: utilization, resetsAt: resetsAt)
        }

        // Entries missing `kind` or `percent` are skipped rather than failing
        // the whole response — the array is additive and still evolving.
        var limits: [Limit] = []
        for case let entry as [String: Any] in root["limits"] as? [Any] ?? [] {
            guard let kind = entry["kind"] as? String,
                  let percent = (entry["percent"] as? NSNumber)?.doubleValue
            else { continue }
            let scope = entry["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            limits.append(
                Limit(
                    kind: kind,
                    percent: percent,
                    resetsAt: (entry["resets_at"] as? String).flatMap(iso.date(from:)),
                    modelName: (model?["display_name"] as? String).flatMap { name in
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        return trimmed.isEmpty ? nil : trimmed
                    }
                )
            )
        }

        // A 2xx whose body carries no window-shaped keys (e.g. an error
        // envelope) is a schema problem, not "all limits are gone".
        guard !windows.isEmpty || !limits.isEmpty else {
            throw ProviderFetchError.parsing(description: "oauth/usage: no rate-limit windows in response")
        }
        return ClaudeUsageResponse(windows: windows, limits: limits)
    }
}

/// ISO-8601 parsing tolerant of the timestamp shapes both Claude sources emit:
/// JSONL logs use millisecond "…T21:47:03.483Z", the usage endpoint emits
/// 6-digit fractional seconds "…T02:40:00.086425+00:00", and `resets_at` can
/// also arrive without any fraction.
///
/// Holds its two `ISO8601DateFormatter`s so hot loops (one call per log line)
/// don't re-allocate them. Not Sendable — create one per parse pass.
struct ClaudeISO8601 {
    private let fractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
    }

    func date(from string: String) -> Date? {
        if let date = fractional.date(from: string) { return date }
        if let date = plain.date(from: string) { return date }
        // Unusual fractional precision: normalize to milliseconds and retry.
        guard let dotIndex = string.firstIndex(of: ".") else { return nil }
        let tail = string[string.index(after: dotIndex)...]
        guard let suffixIndex = tail.firstIndex(where: { !$0.isNumber }), suffixIndex > tail.startIndex else {
            return nil
        }
        let millis = String(tail[..<suffixIndex].prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        let suffix = tail[suffixIndex...]
        if let date = fractional.date(from: "\(string[..<dotIndex]).\(millis)\(suffix)") { return date }
        return plain.date(from: "\(string[..<dotIndex])\(suffix)")
    }
}
