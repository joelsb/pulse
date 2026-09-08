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
/// **`-w` with no trailing value prompts for the password on stdin, twice** —
/// add, then confirm, the same shape as `passwd`.
///
/// **The exit status cannot tell you whether it worked.** Measured
/// 2026-09-08: `security add-generic-password -U -w` exits **0** whether the
/// two stdin copies matched or not. On a mismatch it prints "Passwords do not
/// match" straight to the controlling tty — invisible to a piped `Process`,
/// which has none — and silently creates the item with an **empty**
/// password (`security find-generic-password -w` then returns `""`, also
/// exit 0). A caller trusting the termination status alone would read a
/// corrupted write as a success. The only reliable check is a **read-back**:
/// write, then read the same service/account and compare to what was sent.
/// This is exactly the Keychain equivalent of the pending→verify→promote
/// pattern the OAuth rotation ADR uses for the network side of the same
/// problem — trust nothing that answered 200/0 until it also answers what
/// you asked it.
struct KeychainWriter: Sendable {
    enum Failure: Error, Equatable {
        /// The read-back after the write didn't match what was sent — the two
        /// stdin copies disagreed (see the type's doc comment) or something
        /// else clobbered the item between the write and the check.
        case verificationFailed
        case failed(status: Int32)
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
        let stored = try? await reader.readGenericPassword(service: service, account: account, timeout: timeout)
        guard stored == secret else {
            throw Failure.verificationFailed
        }
    }

    private func runAdd(service: String, account: String, secret: String, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = OnceBox()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["add-generic-password", "-U", "-s", service, "-a", account, "-w"]
            let stdin = Pipe()
            process.standardInput = stdin
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            process.terminationHandler = { finished in
                guard box.claim() else { return }
                // A non-zero status here is real (e.g. the binary itself
                // failed to launch the keychain subsystem); a stdin-copy
                // mismatch does NOT produce one — that is caught by the
                // caller's read-back, not here.
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

            // Sent TWICE — the add/confirm prompt, not a retry. See the
            // type's doc comment for the measured mismatch behaviour.
            let line = Data("\(secret)\n".utf8)
            let handle = stdin.fileHandleForWriting
            handle.write(line)
            handle.write(line)
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
