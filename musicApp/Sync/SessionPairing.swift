import Foundation
import FirebaseFirestore

/// Device linking via short-lived 6-digit codes.
///
/// Anonymous auth means iPhone and iPad have unrelated UIDs — a session can't
/// live under one user's subtree. Pairing bridges the gap: owner mints a code
/// mapping → sessionID; the second device redeems it (single-use, 5 min TTL)
/// and adds itself to `members`.
final class SessionPairing {

    private let db: Firestore
    private static let ttlMs: Double = 5 * 60 * 1000

    init(db: Firestore) { self.db = db }

    /// Create-if-absent inside a transaction; collision → retry with a new code.
    /// 6 digits = 1M codespace; with minutes-long TTLs collisions are ~never,
    /// but the txn makes a collision impossible to silently hijack.
    func createCode(sessionID: String, uid: String) async throws -> String {
        for _ in 0..<5 {
            let code = String(format: "%06d", Int.random(in: 0...999_999))
            let ref = db.collection("pairCodes").document(code)
            do {
                try await db.txn { txn in
                    let snap = try txn.getDocument(ref)
                    if snap.exists { throw SyncError.codeCollision }
                    txn.setData([
                        "sid": sessionID,
                        "uid": uid,
                        "at": FieldValue.serverTimestamp(),
                    ], forDocument: ref)
                }
                return code
            } catch SyncError.codeCollision {
                continue
            }
        }
        throw SyncError.codeCollision
    }

    /// Redeem = read + TTL check + delete, atomically. Returns the sessionID;
    /// caller then does the membership arrayUnion (rules permit exactly that).
    func redeem(code: String) async throws -> String {
        let ref = db.collection("pairCodes").document(code)
        return try await db.txn { txn in
            let snap = try txn.getDocument(ref)
            guard snap.exists,
                  let sid = snap.get("sid") as? String,
                  let ts = snap.get("at") as? Timestamp else {
                throw SyncError.badCode
            }
            let ageMs = Double(ServerClock.shared.nowMs)
                - (Double(ts.seconds) * 1000 + Double(ts.nanoseconds) / 1_000_000)
            // ServerClock may be unsynced pre-join (offset 0) — device clock is
            // fine for a 5-minute window.
            guard ageMs < Self.ttlMs || !ServerClock.shared.isSynced else {
                txn.deleteDocument(ref)
                throw SyncError.badCode
            }
            txn.deleteDocument(ref)   // single-use
            return sid
        }
    }
}
