import Foundation
import FirebaseFirestore

/// NTP-style server clock estimation over Firestore.
///
/// Why: `progress_ms` extrapolation (`pos = positionMs + (serverNow − anchorMs) × rate`)
/// only works if every device shares a time basis. Device wall clocks drift by seconds;
/// Firestore serverTimestamp gives us a common reference. We measure
/// `offset = serverMs − midpoint(send, recv)` and keep the median of recent samples —
/// median is robust against RTT spikes (cell network, backgrounding).
///
/// Note: the server stamps during the WRITE commit, so the NTP midpoint must span
/// send → write-ack only. The follow-up read merely fetches the stamped value; letting
/// its latency into the midpoint would bias every sample low by ~½–1 RTT — a systematic
/// error the median cannot remove. Mirror any change here in desktop/src/serverClock.ts.
final class ServerClock {
    static let shared = ServerClock()

    private var samples: [Double] = []
    private let lock = NSLock()
    private(set) var offsetMs: Double = 0   // serverNow ≈ localNow + offsetMs

    var isSynced: Bool { lock.withLock { !samples.isEmpty } }

    static var localNowMs: Double { Date().timeIntervalSince1970 * 1000 }

    var nowMs: Int { Int(Self.localNowMs + lock.withLock { offsetMs }) }

    func ingest(serverMs: Double, sendLocalMs: Double, ackLocalMs: Double) {
        lock.withLock {
            samples.append(serverMs - (sendLocalMs + ackLocalMs) / 2)
            if samples.count > 9 { samples.removeFirst(samples.count - 9) }
            offsetMs = samples.sorted()[samples.count / 2]
        }
    }

    /// One sample: write serverTimestamp to our presence doc, bracket the WRITE with
    /// local timestamps, then read the stamped value back. The read's own latency must
    /// stay out of the midpoint — the stamp was assigned within [send, ack].
    /// Presence doc doubles as liveness signal for the session.
    func sample(db: Firestore, uid: String) async throws {
        let ref = db.collection("users").document(uid)
            .collection("sync").document("presence_\(SyncDevice.id)")
        let send = Self.localNowMs
        try await ref.setData(["at": FieldValue.serverTimestamp()])
        let ack = Self.localNowMs
        let snap = try await ref.getDocument(source: .server)
        guard let ts = snap.get("at") as? Timestamp else { return }
        ingest(serverMs: Double(ts.seconds) * 1000 + Double(ts.nanoseconds) / 1_000_000,
               sendLocalMs: send, ackLocalMs: ack)
    }

    /// Block until the median has real support — anchors written with offset 0
    /// would poison every follower's extrapolation, and a lone sample leaves the
    /// median hostage to one RTT spike until the periodic resampler catches up.
    /// Three sequential samples (~3 round trips, no sleeps on success) give it a
    /// meaningful window immediately. Throws only if no sample landed at all.
    func prime(db: Firestore, uid: String) async throws {
        guard !isSynced else { return }
        var taken = 0
        var lastError: Error?
        for attempt in 0..<5 {
            do {
                try await sample(db: db, uid: uid)
                taken += 1
                if taken == 3 { return }
            } catch {
                lastError = error
                if attempt < 4 {
                    try await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
        if taken == 0, let error = lastError { throw error }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
