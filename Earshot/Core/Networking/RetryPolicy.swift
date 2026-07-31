import Foundation

/// A pure description of when and how the network layer retries.
///
/// It carries no networking itself: it only classifies whether a failure is
/// transient (worth retrying) and produces the backoff delay before each
/// attempt. ``HTTPClient`` drives the loop. Keeping it pure makes the retry
/// rules unit-testable without touching the network and lets tests inject a
/// zero-delay policy so the suite never actually sleeps.
///
/// Concurrency: a plain value type with only `Sendable` stored properties, so
/// it crosses actor boundaries freely.
struct RetryPolicy: Sendable {
    /// Total number of attempts (the first try plus retries). `1` disables
    /// retrying entirely.
    let maxAttempts: Int

    /// Delay before each *retry*, indexed by retry number (0 = before the 2nd
    /// attempt). The default is 1s then 2s, matching the issue's schedule.
    let backoff: [TimeInterval]

    /// The shipping policy: 3 attempts with 1s then 2s backoff.
    static let standard = RetryPolicy(maxAttempts: 3, backoff: [1, 2])

    /// A policy that retries the same number of times but never sleeps. Used by
    /// tests so retry behaviour is exercised without real delays.
    static let immediate = RetryPolicy(maxAttempts: 3, backoff: [0, 0])

    /// The delay to wait before the attempt numbered `attempt` (1-based). The
    /// first attempt has no delay; retries clamp to the last backoff value if
    /// `maxAttempts` exceeds the schedule length.
    func delay(beforeAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        guard !backoff.isEmpty else { return 0 }
        let index = min(attempt - 2, backoff.count - 1)
        return backoff[index]
    }

    /// Whether another attempt should be made: the error must be transient and
    /// there must be attempts left.
    func shouldRetry(_ error: Error, afterAttempt attempt: Int) -> Bool {
        guard attempt < maxAttempts else { return false }
        return Self.isTransient(error)
    }

    /// Classifies an error as transient (safe to retry) or not.
    ///
    /// Transient: HTTP 5xx, and the connectivity `URLError`s that commonly
    /// clear on a second try (timed out, connection lost, cannot connect to
    /// host, not connected, DNS lookup failed). Everything else — HTTP 4xx,
    /// bad URLs, decoding/parse failures, cancellation — is treated as
    /// permanent and is never retried.
    static func isTransient(_ error: Error) -> Bool {
        if let http = error as? HTTPError {
            switch http {
            case .server(let status):
                return (500...599).contains(status)
            case .badURL:
                return false
            case .transport:
                // Plain transport messages carry no code; fall through to the
                // URLError inspection below in case one is wrapped.
                break
            }
        }

        if let urlError = error as? URLError {
            return transientURLErrorCodes.contains(urlError.code)
        }

        return false
    }

    /// The `URLError` codes Earshot considers worth retrying.
    static let transientURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .networkConnectionLost,
        .cannotConnectToHost,
        .notConnectedToInternet,
        .dnsLookupFailed,
    ]
}
