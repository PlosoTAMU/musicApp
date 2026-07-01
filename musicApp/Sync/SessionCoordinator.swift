import Foundation
import Combine
import FirebaseFirestore

enum SyncRole: Equatable {
    case none
    case owner(epoch: Int)
    case follower

    var isOwner: Bool { if case .owner = self { return true }; return false }
}

/// Ownership + fencing core.
///
/// Invariants this class enforces:
///  1. **Fencing:** every owner write is a transaction asserting
///     `remote.epoch == myEpoch && remote.ownerDeviceID == me`. A deposed
///     ("zombie") owner physically cannot clobber the new owner's state.
///  2. **Ownership changes only happen online.** Takeover is a transaction;
///     transactions fail offline. So two devices can never both believe they
///     won a takeover.
///  3. **No stale replay.** Firestore's built-in offline write queue is
///     deliberately bypassed for session writes (transactions skip it). An
///     offline owner keeps state in a single-slot outbox — only the *latest*
///     state flushes on reconnect, and only if the epoch still belongs to us.
@MainActor
final class SessionCoordinator: ObservableObject {

    @Published private(set) var role: SyncRole = .none
    @Published private(set) var remote: SessionState?
    @Published private(set) var isOnline = true

    let db: Firestore
    private(set) var sessionID: String?
    private(set) var uid: String = ""

    /// Fired when we discover another device took over — engine must pause local audio.
    var onDeposed: (() -> Void)?
    /// Fired for remote states authored by *other* devices (anti-echo already applied).
    var onRemoteState: ((SessionState) -> Void)?

    private var listener: ListenerRegistration?
    private var leaseTimer: Timer?
    private var clockTimer: Timer?

    // Single-slot outbox: latest-state-wins, never a replay log.
    private var outbox: PlaybackState?
    private var retryTask: Task<Void, Never>?
    private var retryDelay: TimeInterval = 2

    private var sessionRef: DocumentReference? {
        sessionID.map { db.collection("sessions").document($0) }
    }

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    // MARK: - Lifecycle

    func createSession(uid: String, playback: PlaybackState, queue: [TrackRef]) async throws -> String {
        self.uid = uid
        let sid = UUID().uuidString.lowercased()
        try await db.collection("sessions").document(sid)
            .setData(SessionState.freshDict(ownerUID: uid, playback: playback, queue: queue))
        sessionID = sid
        try await ServerClock.shared.prime(db: db, sessionID: sid, uid: uid)
        role = .owner(epoch: 1)
        attach()
        startLease()
        return sid
    }

    func joinSession(_ sid: String, uid: String) async throws {
        self.uid = uid
        sessionID = sid
        // Blind arrayUnion — security rules allow a non-member's only write to be
        // "add exactly myself to members". Reading before membership is denied.
        try await db.collection("sessions").document(sid)
            .updateData(["members": FieldValue.arrayUnion([uid])])
        try await ServerClock.shared.prime(db: db, sessionID: sid, uid: uid)
        role = .follower
        attach()
    }

    func leave() {
        listener?.remove(); listener = nil
        stopLease()
        clockTimer?.invalidate(); clockTimer = nil
        retryTask?.cancel(); retryTask = nil
        outbox = nil
        sessionID = nil
        role = .none
        remote = nil
    }

    // MARK: - Snapshot listener (deposed detection + anti-echo + connectivity)

    private func attach() {
        guard let ref = sessionRef else { return }
        listener?.remove()
        listener = ref.addSnapshotListener(includeMetadataChanges: true) { [weak self] snap, _ in
            guard let self, let snap else { return }
            Task { @MainActor in self.handleSnapshot(snap) }
        }
        // Presence + clock refresh: 60s keeps skew bounded and marks us alive.
        clockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { [weak self] in
                guard let self, let sid = await self.sessionID else { return }
                try? await ServerClock.shared.sample(db: self.db, sessionID: sid, uid: await self.uid)
            }
        }
    }

    private func handleSnapshot(_ snap: DocumentSnapshot) {
        let wasOnline = isOnline
        isOnline = !snap.metadata.isFromCache
        if !wasOnline && isOnline { flushOutbox() }   // reconnect → reconcile

        guard let state = SessionState(snap: snap) else { return }
        remote = state

        // Deposed: someone bumped the epoch past ours. Demote BEFORE surfacing
        // state so the engine treats the snapshot as a follower would.
        if case .owner(let mine) = role, state.epoch > mine {
            demote(reason: "epoch \(state.epoch) > \(mine)")
        }

        // Anti-echo: never react to our own writes.
        if state.updatedBy != SyncDevice.id {
            onRemoteState?(state)
        }
    }

    // MARK: - Takeover (fenced ownership transfer)

    /// Returns the *pre-takeover* state so the caller can start local playback at
    /// the extrapolated position — this is the handover continuity guarantee.
    func takeOver() async throws -> SessionState {
        guard let ref = sessionRef else { throw SyncError.noSession }
        let dev = SyncDevice.id
        let myUID = uid
        let now = ServerClock.shared.nowMs

        let pre: SessionState = try await db.txn { txn in
            let snap = try txn.getDocument(ref)
            guard let cur = SessionState(snap: snap) else { throw SyncError.corrupt }
            txn.updateData([
                "epoch": cur.epoch + 1,
                "ownerDeviceID": dev,
                "ownerUID": myUID,
                "leaseMs": now,
                "playback.rev": 0,          // rev is per-epoch; (epoch, rev) still totally ordered
                "updatedBy": dev,
            ], forDocument: ref)
            return cur
        }

        role = .owner(epoch: pre.epoch + 1)
        outbox = nil                         // anything buffered belongs to a dead epoch
        startLease()
        return pre
    }

    // MARK: - Fenced playback publish

    /// `state.rev` is assigned inside the transaction (cur.rev + 1) so revisions
    /// stay monotonic even across retries.
    func publishPlayback(_ state: PlaybackState) async {
        guard case .owner(let myEpoch) = role, let ref = sessionRef else { return }
        let dev = SyncDevice.id

        do {
            try await db.txn { txn in
                let snap = try txn.getDocument(ref)
                guard let cur = SessionState(snap: snap),
                      cur.epoch == myEpoch, cur.ownerDeviceID == dev else {
                    throw SyncError.fenced
                }
                var st = state
                st.rev = cur.playback.rev + 1
                txn.updateData(["playback": st.dict, "updatedBy": dev], forDocument: ref)
            }
            outbox = nil
            retryDelay = 2
        } catch is SyncError {
            demote(reason: "fenced write")
        } catch {
            // Offline / transient: park the LATEST state and retry with backoff.
            // Older buffered states are overwritten — replaying history is the bug,
            // not the feature.
            outbox = state
            scheduleRetry()
        }
    }

    private func flushOutbox() {
        guard let pending = outbox else { return }
        Task { await publishPlayback(pending) }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.flushOutbox()
        }
    }

    // MARK: - Lease heartbeat

    private func startLease() {
        stopLease()
        leaseTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { await self?.renewLease() }
        }
    }

    private func stopLease() {
        leaseTimer?.invalidate(); leaseTimer = nil
    }

    private func renewLease() async {
        guard case .owner(let myEpoch) = role, let ref = sessionRef else { return }
        let dev = SyncDevice.id
        let now = ServerClock.shared.nowMs
        do {
            try await db.txn { txn in
                let snap = try txn.getDocument(ref)
                guard let cur = SessionState(snap: snap),
                      cur.epoch == myEpoch, cur.ownerDeviceID == dev else {
                    throw SyncError.fenced
                }
                txn.updateData(["leaseMs": now], forDocument: ref)
            }
        } catch is SyncError {
            demote(reason: "fenced lease")
        } catch {
            // Offline: lease will look expired to others — that's correct behavior.
            // Followers may take over; we'll discover it on reconnect and demote.
        }
    }

    // MARK: - Demotion

    private func demote(reason: String) {
        guard role.isOwner else { return }
        print("👑→👤 [Sync] Deposed (\(reason))")
        role = .follower
        stopLease()
        retryTask?.cancel()
        outbox = nil          // our buffered state lost the race — discard, never replay
        onDeposed?()
    }
}
