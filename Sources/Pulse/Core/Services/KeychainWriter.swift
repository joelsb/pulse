import Foundation

/// Writes generic-password items via `/usr/bin/security`, never `SecItem` —
/// same rationale as `KeychainReader`: Pulse is ad-hoc signed, so its code
/// signature changes on every rebuild and a direct `SecItemAdd`/`SecItemUpdate`
/// would re-trigger the Keychain approval dialog after each build. The
/// Apple-signed `security` binary is stable, so a one-time "Always Allow"
/// sticks permanently.
///
/// **The secret is sent on stdin, never argv** — a process's argument list is
/// world-readable via `ps -ef`, which is exactly the kind of leak the token
/// rules in this repo exist to prevent.
///
/// **`-w` with no trailing value prompts for the password on stdin, twice,
/// AND silently truncates at 128 bytes.** Both measured 2026-09-08, on the
/// (now former) two-copy stdin-prompt write path:
///
/// 1. A mismatch between the two copies exits **0** either way, prints
///    "Passwords do not match" straight to the controlling tty (invisible to
///    a piped `Process`, which has none), and silently creates the item with
///    an **empty** password.
/// 2. Independently, and worse: the value itself is capped at exactly
///    **128 bytes**, silently, exit 0 on every length. Measured directly:
///    `sent 127 -> stored 127`, `sent 128 -> stored 128`, `sent 129 -> stored
///    128`, `sent 200 -> stored 128`, `sent 300 -> stored 128`. Pulse's real
///    OAuth payload is a ~350-byte JSON blob; Codex's access token alone is
///    1,698 bytes. Both round-tripped correctly through a hand-written
///    scratch test using an 18-character value, which is exactly why this
///    shipped once already — the first version's OWN verification (below)
///    only ever proved a short value works.
///
/// **The fix: `security -i` (interactive mode), base64-encoded.**
/// `-i` reads commands from stdin instead of argv, so the secret still never
/// appears in `ps -ef`, and it has NO length cap — measured up to 1,800 bytes
/// (the ceiling of what was tried, not a ceiling that was hit). Passed as an
/// inline `-w <value>` token on the command line (not omitted — no
/// double-copy prompt exists in this mode at all), so problem 1 above cannot
/// recur either. One remaining catch, also measured: `-i`'s own command
/// parser word-splits on whitespace, so a raw JSON payload (which always
/// contains at least one space, e.g. `"scope":"user:profile
/// user:inference"`) truncates at the first one (`sent 134 -> stored 117` on
/// the exact payload shape this file writes). **Base64-encoding the payload
/// before it ever reaches `security` solves this too** — the base64 alphabet
/// has no whitespace, and it round-trips exactly at every length tried,
/// including with `+`, `/` and `=` all present.
///
/// **The exit status STILL cannot tell you whether it worked** — nothing
/// about `-i` changes that. The read-back is unconditional and now compares
/// the DECODED value, so an encoding bug (forgetting to encode, or to
/// decode) cannot pass either: this is exactly the Keychain equivalent of
/// the pending→verify→promote pattern the OAuth rotation ADR uses for the
/// network side of the same problem — trust nothing that answered 200/0
/// until it also answers what you asked it.
///
/// **A THIRD limit, found 2026-09-08 building JSB-9 (Codex): the cap is on
/// the whole composed STDIN LINE, not on the secret value alone.** The
/// "up to 1,800 bytes" figure above was measured with a short, fixed
/// service/account name, which hid this — a longer service or account name
/// eats directly into the same budget. Measured with a SHORT service name:
/// `sent 4000 -> stored 4000`, `sent 4090 -> stored 4032`, `sent 4095 ->
/// stored 4032`, `sent 5000 -> stored 4032` (the ceiling is on the STORED
/// value once the line as a whole is too long, not proportional to how much
/// was sent past it). The identical test with the service name 105
/// characters longer moved the ceiling from 4032 down to 3924 — a drop of
/// 108, matching the longer name almost exactly:
/// `sent 3900 -> stored 3900`, `sent 3950 -> stored 3924`, `sent 4000 ->
/// stored 3924`. The line is `add-generic-password -U -a <account> -s
/// <service> -w <base64 secret>\n`, and the underlying limit (a `security -i`
/// stdin read buffer, ~4,096 bytes total) applies to that ENTIRE string —
/// **renaming a Keychain service or account can silently shrink the budget
/// a payload that used to fit needs**, which is why `write` below computes
/// the composed line and refuses to even attempt one that doesn't leave
/// enough headroom, rather than relying only on the post-write read-back to
/// notice.
struct KeychainWriter: Sendable {
    enum Failure: Error, Equatable {
        /// The read-back after the write didn't match what was sent, once
        /// both sides are base64-decoded — the write silently failed or
        /// truncated, or something else clobbered the item between the write
        /// and the check.
        case verificationFailed
        /// The composed `security -i` command line (`add-generic-password
        /// -U -a <account> -s <service> -w <base64>`) would exceed the
        /// measured stdin-line budget — see the type's own doc comment for
        /// the two measurements this threshold rests on. Thrown BEFORE the
        /// write is attempted, so this reads as "the line was too long" and
        /// not as the generic, harder-to-diagnose `verificationFailed` a
        /// silent truncation would otherwise produce.
        case lineTooLong(length: Int, limit: Int)
        case failed(status: Int32)
    }

    /// Encodes a secret for the wire, base64 — see the type's doc comment for
    /// why (no length cap workaround exists; whitespace in the payload
    /// truncates in `security -i`'s own parser otherwise). Exposed so a
    /// caller that reads the RAW Keychain value back through a DIFFERENT
    /// path than this type's own `write` (e.g. `PulseOAuthStore.load`, via
    /// `KeychainReader`) can decode it the same way, without re-deriving the
    /// wire format in a second place.
    static func encode(_ secret: String) -> String {
        Data(secret.utf8).base64EncodedString()
    }

    /// The inverse of `encode`. Returns nil — never crashes, never throws —
    /// on anything that isn't valid base64 of valid UTF-8, which is exactly
    /// what a legacy or truncated item (written before this fix, or
    /// corrupted some other way) looks like. A caller (`PulseOAuthStore`)
    /// treats nil the same as "item not found": a bad decode is not this
    /// account's fault and must not crash or wedge anything, only make the
    /// grant read as absent until the next successful write (`-U`) replaces
    /// it, which needs no separate delete step — `add-generic-password -U`
    /// overwrites an existing item's value unconditionally, garbage or not
    /// (verified live, see `scripts/verify-oauth-rotation.sh`).
    static func decode(_ encoded: String) -> String? {
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Guarantees a continuation is resumed exactly once across the racing
    /// termination handler and timeout watchdog. Same pattern as
    /// `KeychainReader.OnceBox`, duplicated rather than shared: the two types
    /// have no other coupling and a shared base would be one more file for a
    /// six-line lock.
    private final class OnceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if finished { return false }
            finished = true
            return true
        }
    }

    /// Creates or updates (`-U`) the generic-password item identified by
    /// `service`/`account` with `secret`, then reads it back and compares —
    /// the only signal the write actually landed (see the type's doc
    /// comment). Never appears in `arguments`, a log line, or the thrown
    /// error — only on the stdin pipe and in the read-back comparison, which
    /// never leaves this process.
    func write(service: String, account: String, secret: String, timeout: TimeInterval = 30) async throws {
        try await runAdd(service: service, account: account, secret: secret, timeout: timeout)

        let reader = KeychainReader()
        let storedEncoded = try? await reader.readGenericPassword(service: service, account: account, timeout: timeout)
        // Decoded on both sides of the comparison intentionally — comparing
        // the raw encoded strings would pass even if `encode`/`decode` had
        // drifted from each other (e.g. one base64 variant vs another), which
        // is exactly the kind of bug this read-back exists to catch.
        guard let storedEncoded, let stored = Self.decode(storedEncoded), stored == secret else {
            throw Failure.verificationFailed
        }
    }

    /// Deletes the generic-password item for `service`/`account`, needed by
    /// `PulseOAuthStore` to make a dead grant (B1: `400 invalid_grant`) not
    /// just in-memory-refused but actually gone — so a re-sign-in is never
    /// shadowed by a stale item under the same uuid, and a relaunch reads
    /// "no grant" without needing to remember anything. An already-absent
    /// item (`errSecItemNotFound`, status 44) is treated as success: deleting
    /// something that is already gone achieved exactly what was asked.
    func delete(service: String, account: String, timeout: TimeInterval = 15) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = OnceBox()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["delete-generic-password", "-s", service, "-a", account]
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            process.terminationHandler = { finished in
                guard box.claim() else { return }
                switch finished.terminationStatus {
                case 0, 44:
                    continuation.resume()
                default:
                    continuation.resume(throwing: Failure.failed(status: finished.terminationStatus))
                }
            }

            do {
                try process.run()
            } catch {
                if box.claim() { continuation.resume(throwing: error) }
                return
            }

            let watched = process
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard watched.isRunning else { return }
                watched.terminate()
                if box.claim() {
                    continuation.resume(throwing: Failure.failed(status: -1))
                }
            }
        }
    }

    /// Runs `add-generic-password -U` through `security -i` (interactive
    /// mode), sending the whole command — including the base64-encoded
    /// secret — on stdin rather than argv, and never as two separate typed
    /// copies (there is nothing to mismatch in this mode). See the type's
    /// doc comment for why: the two-copy stdin-PROMPT mode (`-w` with no
    /// trailing value) this replaced silently capped every value at 128
    /// bytes.
    /// Measured safety threshold for the WHOLE composed `security -i`
    /// command line — see the type's doc comment for the two measurements
    /// (short vs. 105-characters-longer service name) this rests on. Kept
    /// below the observed ~4,032/~3,924-byte truncation points, not at the
    /// wall itself: a few bytes of drift in exactly how `security -i`
    /// buffers its input is cheaper to lose as headroom than to rediscover
    /// as a silent truncation. Codex's own payload (access + refresh tokens
    /// plus a short derived account id, no id_token — see
    /// `CodexOAuthStore`'s doc comment) base64-encodes to roughly 2,600
    /// bytes against this ~4,000-byte budget: about 65% used, real headroom
    /// left for the service/account names to grow before this threshold
    /// would ever fire in production.
    static let maxCommandLineLength = 4000

    private func runAdd(service: String, account: String, secret: String, timeout: TimeInterval) async throws {
        let command = "add-generic-password -U -a \(account) -s \(service) -w \(Self.encode(secret))\n"
        guard command.utf8.count <= Self.maxCommandLineLength else {
            throw Failure.lineTooLong(length: command.utf8.count, limit: Self.maxCommandLineLength)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = OnceBox()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["-i"]
            let stdin = Pipe()
            process.standardInput = stdin
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            process.terminationHandler = { finished in
                guard box.claim() else { return }
                // A non-zero status here is real (e.g. the binary itself
                // failed to launch the keychain subsystem). `-i` exits 0 when
                // stdin (this one command, then EOF) is consumed cleanly.
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: Failure.failed(status: finished.terminationStatus))
                }
            }

            do {
                try process.run()
            } catch {
                if box.claim() { continuation.resume(throwing: error) }
                return
            }

            let handle = stdin.fileHandleForWriting
            handle.write(Data(command.utf8))
            // Closing stdin (EOF) ends the interactive session — no explicit
            // `quit` command needed, and `quit` is not a recognized command
            // in this mode anyway (measured: "unknown command \"quit\"").
            try? handle.close()

            let watched = process
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard watched.isRunning else { return }
                watched.terminate()
                if box.claim() {
                    continuation.resume(throwing: Failure.failed(status: -1))
                }
            }
        }
    }
}
