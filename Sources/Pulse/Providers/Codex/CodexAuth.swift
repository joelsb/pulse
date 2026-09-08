import Foundation

/// Credentials of the Codex CLI / Codex Desktop, read from `~/.codex/auth.json`.
///
/// The file is re-read on every fetch because the CLI refreshes its own tokens
/// (roughly every few days) and rewrites the file. Pulse never writes it back
/// and never triggers a refresh. The refresh token is deliberately not loaded
/// into memory — only the fields Pulse actually needs.
///
/// Verified shape on this machine (docs/RESEARCH/codex.md §1):
/// `{auth_mode, tokens: {id_token, access_token, refresh_token, account_id}, last_refresh}`.
struct CodexAuth: Sendable {
    var authMode: String?
    /// Bearer token for `chatgpt.com/backend-api/wham/usage` (a JWT).
    var accessToken: String
    /// Carries the `https://api.openai.com/auth` claim dict with `chatgpt_plan_type`.
    var idToken: String?
    /// Sent as the `ChatGPT-Account-Id` header.
    var accountID: String?
    /// Epoch MILLISECONDS, matching `ClaudeCredentials.expiresAt`'s convention
    /// — JSB-9: nil for `~/.codex/auth.json` (that file carries no expiry
    /// field of its own; `load` derives one from the access token's JWT `exp`
    /// claim, seconds × 1000) and populated directly from jcode/pi's own
    /// millisecond fields when a candidate comes from one of those stores
    /// instead (see `CodexCredentialSources.swift`).
    var expiresAt: Double? = nil

    /// `expiresAt` is epoch milliseconds; nil never expires (matches
    /// `ClaudeCredentials.isExpired` — an absent expiry is not evidence of
    /// staleness, only of a source that doesn't report one).
    func isExpired(now: Date = .now) -> Bool {
        guard let expiresAt else { return false }
        return now.timeIntervalSince1970 * 1000 >= expiresAt
    }

    static var defaultFileURL: URL {
        AppPaths.home.appendingPathComponent(".codex/auth.json")
    }

    /// Loads and validates the auth file. Throws `.notLoggedIn` when the file is
    /// missing or carries no ChatGPT access token (e.g. API-key mode).
    static func load(from url: URL = defaultFileURL) throws -> CodexAuth {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProviderFetchError.notLoggedIn(hint: "Sign in to the Codex CLI to start tracking.")
        }
        let file: AuthFile
        do {
            file = try JSONDecoder().decode(AuthFile.self, from: data)
        } catch {
            // Never include file contents in the error — the file holds secrets.
            throw ProviderFetchError.parsing(description: "auth.json has an unrecognized format")
        }
        guard let accessToken = file.tokens?.accessToken, !accessToken.isEmpty else {
            let hint = file.openAIAPIKey == nil
                ? "Sign in to the Codex CLI to start tracking."
                : "Codex CLI uses an API key — usage tracking needs a ChatGPT login."
            throw ProviderFetchError.notLoggedIn(hint: hint)
        }
        return CodexAuth(
            authMode: file.authMode,
            accessToken: accessToken,
            idToken: file.tokens?.idToken,
            accountID: file.tokens?.accountID,
            // No literal expiry field in this file - derived from the token
            // itself. Review S2: the ACCESS token's own `exp` first, not the
            // id_token's - it is the credential every request actually
            // carries, and its lifetime routinely differs from the id_token's
            // (an OIDC id_token commonly outlives the access token it shipped
            // with). Reading the id_token's `exp` first meant a still-live
            // access token could read as expired (dropped from the fallback
            // chain with no error anywhere) or a dead one could read as fresh
            // and get sent (breaking the intent's own "a token known to be
            // expired is never sent") depending only on which claim happened
            // to answer first - neither is what this field is supposed to mean.
            expiresAt: Self.expiresAt(idToken: file.tokens?.idToken, accessToken: accessToken)
        )
    }

    /// JWT `exp` is epoch SECONDS (RFC 7519 §4.1.4); converted × 1000 to match
    /// this type's own millisecond convention. `JSONSerialization` decodes a
    /// bare JSON number as `NSNumber`, which bridges to both `Int` and
    /// `Double` — tried in that order since `as? Double` on an `NSNumber`
    /// holding an integer value succeeds in practice but the `Int` path is
    /// kept as the primary, unambiguous case. Access token first (S2) - the
    /// id_token is only a fallback hint when there is no access token to ask.
    static func expiresAt(idToken: String?, accessToken: String?) -> Double? {
        for token in [accessToken, idToken].compactMap({ $0 }) {
            if let seconds = JWT.claim("exp", of: token, as: Int.self) { return Double(seconds) * 1000 }
            if let seconds = JWT.claim("exp", of: token, as: Double.self) { return seconds * 1000 }
        }
        return nil
    }

    // MARK: - JWT-derived account info

    /// Plan label from the `chatgpt_plan_type` key of the namespaced
    /// `https://api.openai.com/auth` claim dict ("plus" → "Plus").
    /// Prefers the id_token; the access_token carries the same claim.
    var plan: String? {
        for token in [idToken, accessToken].compactMap({ $0 }) {
            guard let auth = JWT.claim("https://api.openai.com/auth", of: token, as: [String: Any].self),
                  let raw = auth["chatgpt_plan_type"] as? String,
                  !raw.isEmpty
            else { continue }
            return Self.planDisplayName(raw)
        }
        return nil
    }

    /// Masked email for the Settings account hint, e.g. "bu…@example.com".
    /// Reads the namespaced `https://api.openai.com/profile` claim dict first
    /// (present on the access_token), then the id_token's top-level `email`.
    var accountLabel: String? {
        let tokens = [idToken, accessToken].compactMap { $0 }
        for token in tokens {
            if let profile = JWT.claim("https://api.openai.com/profile", of: token, as: [String: Any].self),
               let email = profile["email"] as? String,
               let masked = Self.maskedEmail(email) {
                return masked
            }
        }
        for token in tokens {
            if let email = JWT.claim("email", of: token, as: String.self),
               let masked = Self.maskedEmail(email) {
                return masked
            }
        }
        return nil
    }

    /// "plus" → "Plus", "free_workspace" → "Free Workspace".
    static func planDisplayName(_ raw: String) -> String {
        raw.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// First two characters of the local part + "…@" + domain.
    static func maskedEmail(_ email: String) -> String? {
        guard let at = email.firstIndex(of: "@"), at != email.startIndex else { return nil }
        let domain = email[email.index(after: at)...]
        guard !domain.isEmpty else { return nil }
        return "\(email[..<at].prefix(2))…@\(domain)"
    }
}

/// Targeted decode of auth.json — ignores everything Pulse does not need
/// (notably the refresh token, which is never read into memory).
private struct AuthFile: Decodable {
    var authMode: String?
    var openAIAPIKey: String?
    var tokens: Tokens?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case openAIAPIKey = "OPENAI_API_KEY"
        case tokens
    }

    struct Tokens: Decodable {
        var accessToken: String?
        var idToken: String?
        var accountID: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case idToken = "id_token"
            case accountID = "account_id"
        }
    }
}
