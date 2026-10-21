import Foundation

/// Shared utilities for wrapping blocking CoreGraphics calls.
enum CGHelpers {

    // MARK: - Display-configuration transactions

    /// Serial queue for the blocking WindowServer work handed to `runWithTimeout`.
    ///
    /// `CGBeginDisplayConfiguration` → `CGCompleteDisplayConfiguration` is a single
    /// WindowServer transaction. Two of them in flight at once can interleave and leave the
    /// display in a state that matches neither the UI nor the request, so every operation
    /// runs on this one serial queue: a new transaction waits for the previous one to return
    /// even when that previous one already timed out on the caller's side.
    ///
    /// The timeout still works — the caller is never blocked forever — it just no longer
    /// abandons a live transaction. If a WindowServer call really is wedged, the queue stays
    /// busy until it returns: refusing to start a second transaction is the point.
    private static let transactionQueue = DispatchQueue(
        label: "com.jseook11.cghelpers.transaction",
        qos: .userInitiated
    )

    /// Guards `outstandingTransactions`.
    private static let transactionStateLock = NSLock()

    /// Operations handed to `transactionQueue` that have not returned yet. This deliberately
    /// includes operations whose caller already timed out — those are exactly the ones that
    /// must keep the next transaction from starting.
    private nonisolated(unsafe) static var outstandingTransactions = 0

    /// True while a display-configuration transaction is still outstanding: running on the
    /// serial transaction queue, or queued behind one that is. A caller that would otherwise
    /// retry must not start a second transaction while this is true.
    static var isTransactionInFlight: Bool {
        transactionStateLock.lock()
        defer { transactionStateLock.unlock() }
        return outstandingTransactions > 0
    }

    /// Runs a blocking operation on a background thread with a timeout.
    ///
    /// The operation is dispatched to the serial `transactionQueue`. If it
    /// completes within `seconds`, its return value is forwarded. If the
    /// deadline fires first, `fallback` is returned instead — but the operation
    /// keeps running and keeps holding the serial queue, so the next operation
    /// cannot start a second transaction behind its back (see `isTransactionInFlight`).
    ///
    /// This is useful for any CoreGraphics / WindowServer IPC call that can
    /// hang indefinitely (e.g. `CGCompleteDisplayConfiguration`,
    /// `CGVirtualDisplay.apply(_:)`).
    ///
    /// - Parameters:
    ///   - seconds:   Maximum time to wait before returning `fallback`.
    ///   - fallback:  Value returned on timeout.
    ///   - operation: The blocking work to execute off-thread.
    /// - Returns: The operation's result, or `fallback` on timeout.
    static func runWithTimeout<T: Sendable>(
        seconds: Double,
        fallback: T,
        operation: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { cont in
            let lock = NSLock()
            var didResume = false

            beginTransaction()
            transactionQueue.async {
                defer { endTransaction() }
                let result = operation()
                lock.lock()
                guard !didResume else { lock.unlock(); return }
                didResume = true
                lock.unlock()
                cont.resume(returning: result)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                lock.lock()
                guard !didResume else { lock.unlock(); return }
                didResume = true
                lock.unlock()
#if DEBUG
                print("[CGHelpers] runWithTimeout: timed out after \(seconds)s — returning fallback")
#endif
                cont.resume(returning: fallback)
            }
        }
    }

    // MARK: - In-flight bookkeeping

    private static func beginTransaction() {
        transactionStateLock.lock()
        outstandingTransactions += 1
        transactionStateLock.unlock()
    }

    private static func endTransaction() {
        transactionStateLock.lock()
        outstandingTransactions -= 1
        transactionStateLock.unlock()
    }
}
