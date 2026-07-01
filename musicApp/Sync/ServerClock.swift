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
/// Note: our sample spans TWO round trips (write-ack, then server read), which widens
/// the uncertainty window vs classic NTP. The median over 9 samples absorbs this;
/// empirical accuracy is well under the 750 ms drift threshold the engine tolerates.
final class ServerClock {
    static let shared = ServerClock()

    private var samples: [Double] = []
    private let lock = NSLock()
    private(set) var offsetMs: Double = 0   // serverNow ≈ localNow + offsetMs

    var isSynced: Bool { lock.withLock { !samples.isEmpty } }

    static var localNowMs: Double { Date().timeIntervalSince1970 * 1000 }

    var nowMs: Int { Int(Self.localNowMs + lock.withLock { offsetMs }) }

    func ingest(serverMs: Double, sendLocalMs: Double, recvLocalMs: Double) {
        lock.withLock {
            samples.append(serverMs - (sendLocalMs + recvLocalMs) / 2)
            if samples.count > 9 { samples.removeFirst(samples.count - 9) }
            offsetMs = samples.sorted()[samples.count / 2]
        }
    }

    /// One sample: write serverTimestamp to our presence doc, read it back from server.
    /// Presence doc doubles as liveness signal for the session.
    func sample(db: Firestore, sessionID: String, uid: String) async throws {
        let ref = db.collection("sessions").document(sessionID)
            .collection("presence").document(SyncDevice.id)
        let send = Self.localNowMs
        try await ref.setData(["at": FieldValue.serverTimestamp(), "uid": uid])
        let snap = try await ref.getDocument(source: .server)
        let recv = Self.localNowMs
        guard let ts = snap.get("at") as? Timestamp else { return }
        ingest(serverMs: Double(ts.seconds) * 1000 + Double(ts.nanoseconds) / 1_000_000,
               sendLocalMs: send, recvLocalMs: recv)
    }

    /// Block until at least one sample exists — anchors written with offset 0
    /// would poison every follower's extrapolation.
    func prime(db: Firestore, sessionID: String, uid: String) async throws {
        guard !isSynced else { return }
        for attempt in 0..<3 {
            do { try await sample(db: db, sessionID: sessionID, uid: uid); return }
            catch where attempt < 2 {
                try await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1)))
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
