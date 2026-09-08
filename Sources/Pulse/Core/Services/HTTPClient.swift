import Foundation

/// Thin URLSession wrapper shared by all providers.
///
/// Uses an ephemeral session with cookies and caching disabled: providers manage
/// their own auth headers (Cursor sends an explicit Cookie header) and nothing
/// should leak into shared state on disk.
struct HTTPClient: Sendable {
    private let session: URLSession

    init(timeout: TimeInterval = 15) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await send(request)
    }

    func post(_ url: URL, headers: [String: String] = [:], jsonBody: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonBody
        }
        return try await send(request)
    }

    func postRaw(_ url: URL, headers: [String: String] = [:], jsonBody: Data? = nil) async throws -> (status: Int, data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonBody
        }
        return try await sendRaw(request)
    }

    /// Same shape as `postRaw`, but the body is `application/x-www-form-urlencoded`
    /// instead of JSON — JSB-9: OpenAI's `/oauth/token` rejects a JSON body
    /// outright (Anthropic's, which `postRaw`/`jsonBody` already serve, takes
    /// JSON). Added alongside the JSON path rather than replacing it — every
    /// existing `postRaw`/`post` caller, and `scripts/verify-rate-limit-backoff.sh`,
    /// which exercises `postRaw`'s JSON path indirectly through `ClaudeOAuthClient`,
    /// keeps working unchanged.
    func postFormRaw(_ url: URL, headers: [String: String] = [:], form: [String: String]) async throws -> (status: Int, data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(form).utf8)
        return try await sendRaw(request)
    }

    /// `application/x-www-form-urlencoded`, RFC 3986 unreserved characters
    /// plus `-._~` left alone, everything else percent-encoded — deliberately
    /// NOT `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`,
    /// which leaves `+` and `&` unescaped and would corrupt a value containing
    /// either (a scope string with a literal `+`, or a code value that happens
    /// to contain `&`).
    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }

    /// Sends a request and returns the status, raw body AND the response
    /// WITHOUT collapsing a non-2xx status into the coarse
    /// `ProviderFetchError` taxonomy `send` uses — for the rare caller that
    /// has to read the response BODY to tell two failures apart (e.g.
    /// `ClaudeOAuthClient` distinguishing a dead refresh token's
    /// `400 {"error":"invalid_grant"}` from every other 400, which `send`
    /// cannot do because it discards the body before throwing) or needs a
    /// HEADER `send` would also have discarded (e.g. `Retry-After` on a 429).
    /// Transport failures and cancellation still throw, same as `send`; only
    /// status-code handling is left to the caller.
    func sendRaw(_ request: URLRequest) async throws -> (status: Int, data: Data, response: HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ProviderFetchError.network(description: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderFetchError.network(description: "Non-HTTP response")
        }
        return (http.statusCode, data, http)
    }

    /// Sends a request, mapping transport errors and non-2xx statuses to
    /// `ProviderFetchError` (401/403 → `.unauthorized`). Task cancellation is
    /// rethrown as `CancellationError` — never disguised as a network failure —
    /// so a Settings toggle mid-fetch can't poison provider state.
    func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ProviderFetchError.network(description: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderFetchError.network(description: "Non-HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw ProviderFetchError.unauthorized
        case 429:
            throw ProviderFetchError.rateLimited(retryAfter: Self.retryAfter(from: http))
        default:
            throw ProviderFetchError.http(status: http.statusCode)
        }
    }

    /// `Retry-After`, in seconds from now, in either form RFC 9110 allows:
    /// delta-seconds (`2808`) or an HTTP-date (`Wed, 01 Sep 2026 16:05:00 GMT`).
    ///
    /// This used to be dropped on the floor with the rest of the headers, which
    /// is why a 429 could not be waited out: the app knew it was rate limited
    /// and never knew for how long, so it kept asking on the ordinary refresh
    /// tick and renewed the penalty every time.
    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return nil }

        if let seconds = TimeInterval(raw) {
            // A past or absurd value is treated as absent rather than trusted:
            // a negative delta would disable the cooldown entirely.
            return seconds > 0 ? min(seconds, 24 * 3600) : nil
        }
        guard let date = httpDateFormatter.date(from: raw) else { return nil }
        let interval = date.timeIntervalSinceNow
        return interval > 0 ? min(interval, 24 * 3600) : nil
    }

    /// IMF-fixdate, the only form a server must send. Locale and time zone are
    /// pinned: the default locale would fail to parse "Wed" on a Spanish Mac.
    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// Decodes JSON, mapping failures to `ProviderFetchError.parsing`.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ProviderFetchError.parsing(description: "\(T.self): \(error.localizedDescription)")
        }
    }
}
