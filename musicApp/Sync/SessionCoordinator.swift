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

    var sessionRef: DocumentReference? {
        uid.isEmpty ? nil : db.collection("users").document(uid)
            .collection("sync").document("session")
    }

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    // MARK: - Lifecycle: attach is the whole story (shared-secret singleton)

    func attach(uid: String) async throws {
        self.uid = uid
        guard let ref = sessionRef else { return }
        // Lazily create the singleton. Plain read-then-write is fine: a racing
        // second device's setData writes the identical idle doc.
        if try await !ref.getDocument().exists {
            try await ref.setData(SessionState.idleDict())
        }
        try await ServerClock.shared.prime(db: db, uid: uid)
        role = .follower
        listen()
    }

    func detach() {
        listener?.remove(); listener = nil
        stopLease()
        clockTimer?.invalidate(); clockTimer = nil
        retryTask?.cancel(); retryTask = nil
        outbox = nil
        uid = ""
        role = .none
        remote = nil
    }

    // MARK: - Snapshot listener (deposed detection + anti-echo + connectivity)

    private func listen() {
        guard let ref = sessionRef else { return }
        listener?.remove()
        listener = ref.addSnapshotListener(includeMetadataChanges: true) { [weak self] snap, _ in
            guard let self, let snap else { return }
            Task { @MainActor in self.handleSnapshot(snap) }
        }
        // Presence + clock refresh: 60s keeps skew bounded and marks us alive.
        clockTimer?.invalidate()   // re-attach must not stack timers
        clockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { [weak self] in
                guard let self else { return }
                let uid = await self.uid
                guard !uid.isEmpty else { return }
                try? await ServerClock.shared.sample(db: self.db, uid: uid)
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
        let now = ServerClock.shared.nowMs

        let pre: SessionState = try await db.txn { txn in
            let snap = try txn.getDocument(ref)
            guard let cur = SessionState(snap: snap) else { throw SyncError.corrupt }
            txn.updateData([
                "epoch": cur.epoch + 1,
                "ownerDeviceID": dev,
                "leaseMs": now,
                "playback.rev": 0,          // rev is per-epoch; (epoch, rev) still totally ordered
                "updatedBy": dev,
                "handoff": FieldValue.delete(),  // takeover consumes any pending handoff
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

    // MARK: - Bluetooth handoff beacon

    /// Owner's headphones disconnected → advertise a 60 s handoff window.
    /// Plain (non-transactional) write on purpose: this fires in the chaos of a
    /// route change and must be fast; a stale beacon self-expires via atMs.
    func postHandoff() async {
        guard role.isOwner, let ref = sessionRef else { return }
        try? await ref.updateData([
            "handoff": ["by": SyncDevice.id, "atMs": ServerClock.shared.nowMs],
            "updatedBy": SyncDevice.id,
        ])
    }

    /// Headphones came back to THIS device (or handoff otherwise resolved).
    func clearHandoff() async {
        guard let ref = sessionRef else { return }
        try? await ref.updateData(["handoff": FieldValue.delete()])
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
