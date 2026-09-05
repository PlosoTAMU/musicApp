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
    /// Fired when the seat was CLEARED under us (a peer ran the expired-lease
    /// clear while we were unreachable — suspend, network blip), not TAKEN.
    /// Role has already dropped to follower WITHOUT touching audio; the engine
    /// decides whether to reclaim (still playing) or stay a follower
    /// (sync-audit-5 S3).
    var onSeatCleared: (() -> Void)?
    /// Fired for EVERY parsed snapshot. `isEcho` = authored by this device.
    /// Display (mirror) and join-resync must see echoes too — after a relaunch
    /// the first snapshot often carries our own last write, and filtering it
    /// out left the mirror empty forever ("now playing never loads").
    /// Loop-sensitive consumers (queue apply) skip echoes themselves.
    var onSessionState: ((SessionState, _ isEcho: Bool) -> Void)?

    private var listener: ListenerRegistration?
    private var leaseTimer: Timer?
    private var clockTimer: Timer?
    private var listenRetryTask: Task<Void, Never>?
    private var listenRetryDelay: TimeInterval = 2

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
        listenRetryTask?.cancel(); listenRetryTask = nil
        outbox = nil
        uid = ""
        role = .none
        remote = nil
        checkedStaleSelfOwnership = false
        staleReleaseInFlight = false
    }

    // MARK: - Snapshot listener (deposed detection + anti-echo + connectivity)

    private func listen() {
        guard let ref = sessionRef else { return }
        listener?.remove()
        listener = ref.addSnapshotListener(includeMetadataChanges: true) { [weak self] snap, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in self.handleListenError(error) }
                return
            }
            guard let snap else { return }
            Task { @MainActor in self.handleSnapshot(snap) }
        }
        // Clock refresh: keeps skew bounded (engine tolerates ~750ms; device
        // clocks don't drift anywhere near that fast on this cycle). 5 min
        // instead of 60s — this fires for every connected device, foreground
        // or backgrounded (audio background mode keeps it alive), and each
        // tick is a forced Firestore write + server read.
        clockTimer?.invalidate()   // re-attach must not stack timers
        clockTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { [weak self] in
                guard let self else { return }
                let uid = await self.uid
                guard !uid.isEmpty else { return }
                try? await ServerClock.shared.sample(db: self.db, uid: uid)
            }
        }
    }

    /// Terminal listen error (the SDK gave up retrying internally, e.g. a
    /// stream reset it can't recover) → mark offline and re-subscribe from
    /// scratch with backoff, so a wedged listener can't leave the app
    /// permanently "offline" until restart.
    private func handleListenError(_ error: Error) {
        print("👑→👤 [Sync] listener error (\(error.localizedDescription)) — will re-subscribe")
        isOnline = false
        listenRetryTask?.cancel()
        let delay = listenRetryDelay
        listenRetryDelay = min(listenRetryDelay * 2, 30)
        listenRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.listen()
        }
    }

    private func handleSnapshot(_ snap: DocumentSnapshot) {
        listenRetryDelay = 2
        let wasOnline = isOnline
        isOnline = !snap.metadata.isFromCache
        if !wasOnline && isOnline { flushOutbox() }   // reconnect → reconcile

        guard let state = SessionState(snap: snap) else { return }
        remote = state

        // Deposed: someone bumped the epoch past ours. Demote BEFORE surfacing
        // state so the engine treats the snapshot as a follower would.
        if case .owner(let mine) = role, state.epoch > mine {
            demote(reason: "epoch \(state.epoch) > \(mine)")
        } else if case .owner(let mine) = role, !snap.metadata.isFromCache,
                  state.epoch == mine, state.ownerDeviceID.isEmpty {
            // Our epoch, but the seat is empty: a peer's expired-lease clear
            // ran while we were unreachable. Not a takeover — nothing else
            // owns the audio — so don't pause it; let the engine reclaim if it
            // is still playing. Without this the owner kept playing as a
            // zombie until renewLease fenced (≤20 s) and then paused for no
            // visible reason (sync-audit-5 S3). Twin of coordinator.ts.
            seatCleared(reason: "snapshot")
        }

        // Crashed-owner recovery: the doc still names THIS device as owner but
        // we booted as a follower — a previous process died mid-reign. Left
        // alone, every device (including us) sees a dead owner "playing"
        // forever. Release once, on the first server-confirmed snapshot only
        // (a cache frame could be stale, and a takeover we start later must
        // never be undone — the txn is fenced on the epoch we saw here).
        //
        // NOTE (merge of arpi/audit-3): audit-3's F2 proposed *reclaiming* the
        // seat here instead. Release wins — a reclaim publishes nothing, so the
        // phantom `playing: true` with a dead anchor survives on every other
        // device, and the engine's own reconcileLocalPlayback already claims the
        // session the moment local audio really plays.
        //
        // The latch is set only when the release TRANSACTION SUCCEEDS (or when
        // there was nothing to release). Latching before the write meant one
        // transient failure — offline blip, contention — wedged the device in a
        // fake "remote controlled by itself" mode for the rest of the process
        // (sync-audit-4 B1). `staleReleaseInFlight` keeps the retry from firing
        // a second transaction while the first is still open.
        if !snap.metadata.isFromCache, !checkedStaleSelfOwnership,
           !staleReleaseInFlight {
            if state.ownerDeviceID == SyncDevice.id, !role.isOwner {
                staleReleaseInFlight = true
                let epoch = state.epoch
                Task { await self.releaseStaleOwnership(epoch: epoch) }
            } else {
                checkedStaleSelfOwnership = true   // nothing stale to release
            }
        }

        // F3 (sync-audit-3.md) — a DIFFERENT device owns the seat but hasn't
        // heartbeated in > leaseTTLMs. Fenced-CAS ownerDeviceID back to "" so
        // the session reads idle again and whoever plays next takes it cleanly.
        // Runs on every online snapshot, not just the first: an owner can die
        // at any point in the session. Skipped until the ServerClock has real
        // samples — wall-clock skew alone must not nuke a live owner's seat.
        // Races between followers are safe: the txn re-checks the expected
        // owner AND expired-lease at commit, so only the first wins.
        if isOnline, !role.isOwner,
           !state.ownerDeviceID.isEmpty,
           state.ownerDeviceID != SyncDevice.id,
           ServerClock.shared.isSynced,
           state.leaseExpired {
            let expectedOwner = state.ownerDeviceID
            Task { [weak self] in await self?.clearExpiredOwnership(from: expectedOwner) }
        }

        // Skip cached snapshots (sync-audit-3.md F5) — Firestore re-fires the
        // last known doc while offline, and treating those as live paints the
        // mirror UI with possibly hours-old "playing on <device>" state.
        // `remote` above keeps the last online value, so views reading it
        // directly still see the last known session; only the engine's
        // mirror/queue/ghost apply path is gated. Echoes still pass through
        // (with isEcho set): after a relaunch the first frame is usually our
        // own last write, and it must still populate the mirror.
        if isOnline {
            onSessionState?(state, state.updatedBy == SyncDevice.id)
        }
    }

    // MARK: - Stale self-ownership release

    private var checkedStaleSelfOwnership = false
    private var staleReleaseInFlight = false

    /// Fenced on the observed epoch: if anything (another device, or our own
    /// takeover racing this task) bumped the epoch meanwhile, this aborts.
    ///
    /// `SyncError.fenced` means the world moved on — someone else owns the seat
    /// now, so there is nothing left to release and the latch closes. Any other
    /// error is transient (offline, contention): leave the latch open so the
    /// next fresh snapshot retries.
    private func releaseStaleOwnership(epoch: Int) async {
        defer { staleReleaseInFlight = false }
        guard !role.isOwner, let ref = sessionRef else {
            checkedStaleSelfOwnership = true
            return
        }
        let dev = SyncDevice.id
        do {
            try await db.txn { txn in
                let snap = try txn.getDocument(ref)
                guard let cur = SessionState(snap: snap),
                      cur.epoch == epoch, cur.ownerDeviceID == dev else {
                    throw SyncError.fenced
                }
                txn.updateData([
                    "ownerDeviceID": "",
                    "playback.playing": false,
                    "updatedBy": dev,
                ], forDocument: ref)
            }
            checkedStaleSelfOwnership = true
            print("👑→👤 [Sync] Released stale self-ownership (crashed previous run)")
        } catch is SyncError {
            // Superseded: someone took over between the snapshot and the txn.
            checkedStaleSelfOwnership = true
        } catch {
            // Transient (offline / contention) — retry on the next fresh snapshot.
            print("👑→👤 [Sync] Stale-ownership release failed, will retry: \(error)")
        }
    }

    /// Fenced-CAS clear of a stale owner. No-op unless the doc still names the
    /// expected dead owner and its lease is still expired at commit time.
    private func clearExpiredOwnership(from expectedOwner: String) async {
        guard let ref = sessionRef else { return }
        let dev = SyncDevice.id
        let now = ServerClock.shared.nowMs
        do {
            try await db.txn { txn in
                let snap = try txn.getDocument(ref)
                guard let cur = SessionState(snap: snap),
                      cur.ownerDeviceID == expectedOwner,
                      cur.leaseExpired else { return }
                // The owner is dead, so nothing is playing: freeze the record
                // where it was last known alive. Leaving `playing: true`
                // behind made every follower extrapolate to the end of the
                // track and the next "Play Here" start there (sync-audit-5
                // S2). Twin of coordinator.ts clearExpiredOwnership.
                var frozen = cur.playback.frozen(atLeaseMs: cur.leaseMs, nowMs: now)
                frozen.rev = cur.playback.rev + 1
                txn.updateData([
                    "ownerDeviceID": "",
                    "leaseMs": now,
                    "playback": frozen.dict,
                    "updatedBy": dev,
                ], forDocument: ref)
            }
        } catch {
            // Best-effort: another follower may have cleared it first, or the
            // owner heartbeated between our snapshot and the txn.
        }
    }

    /// Voluntary release — this device is about to stop heartbeating (iOS is
    /// suspending a PAUSED owner) and still holds the seat. Empties the seat
    /// and writes the final paused state at the current position, so the
    /// other devices read "paused · Play Here to continue" immediately instead
    /// of a phantom owner for leaseTTLMs (sync-audit-5 S8). Fenced: a takeover
    /// that landed meanwhile wins and this is a no-op. Role drops to follower
    /// first so nothing else publishes into the reign we are giving up. Twin
    /// of coordinator.ts releaseSeat.
    func releaseSeat(final: PlaybackState) async {
        guard case .owner(let myEpoch) = role, let ref = sessionRef else { return }
        let dev = SyncDevice.id
        let now = ServerClock.shared.nowMs
        dropOwnership()
        let st: PlaybackState = {
            var s = final
            s.isPlaying = false
            s.anchorMs = now
            return s
        }()
        do {
            try await db.txn { txn in
                let snap = try txn.getDocument(ref)
                guard let cur = SessionState(snap: snap),
                      cur.epoch == myEpoch, cur.ownerDeviceID == dev else { return }
                var out = st
                out.rev = cur.playback.rev + 1
                txn.updateData([
                    "ownerDeviceID": "",
                    "leaseMs": now,
                    "playback": out.dict,
                    "updatedBy": dev,
                ], forDocument: ref)
            }
            print("👑→👤 [Sync] Released seat (paused owner going to background)")
        } catch {
            // We already dropped to follower but the doc may still name us at
            // a live lease. Re-arm the crashed-owner self-release so the next
            // fresh snapshot clears it instead of waiting for a peer's F3.
            print("👑→👤 [Sync] Seat release failed: \(error)")
            checkedStaleSelfOwnership = false
        }
    }

    /// Why a fenced owner write failed: the seat was CLEARED at our epoch (a
    /// peer's expired-lease clear — reclaimable) vs. TAKEN (epoch bumped, or
    /// someone else in the seat — yield). Twin of coordinator.ts fenceError.
    nonisolated private static func fenceError(_ cur: SessionState, myEpoch: Int) -> SyncError {
        cur.epoch == myEpoch && cur.ownerDeviceID.isEmpty ? .seatCleared : .fenced
    }

    // MARK: - Takeover (fenced ownership transfer)

    /// Returns the *pre-takeover* state so the caller can start local playback at
    /// the extrapolated position — this is the handover continuity guarantee.
    ///
    /// `onlyIfIdle`: refuse (`.seatTaken`) when any other device holds the
    /// seat. Used by the reclaim-after-clear path — a device that legitimately
    /// took over while we were away must not be deposed by our return.
    func takeOver(onlyIfIdle: Bool = false) async throws -> SessionState {
        guard let ref = sessionRef else { throw SyncError.noSession }
        let dev = SyncDevice.id
        let now = ServerClock.shared.nowMs

        let pre: SessionState = try await db.txn { txn in
            let snap = try txn.getDocument(ref)
            guard let cur = SessionState(snap: snap) else { throw SyncError.corrupt }
            if onlyIfIdle, !cur.ownerDeviceID.isEmpty, cur.ownerDeviceID != dev {
                throw SyncError.seatTaken
            }
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
                guard let cur = SessionState(snap: snap) else { throw SyncError.fenced }
                guard cur.epoch == myEpoch, cur.ownerDeviceID == dev else {
                    throw Self.fenceError(cur, myEpoch: myEpoch)
                }
                var st = state
                st.rev = cur.playback.rev + 1
                txn.updateData(["playback": st.dict, "updatedBy": dev], forDocument: ref)
            }
            outbox = nil
            retryDelay = 2
        } catch SyncError.seatCleared {
            seatCleared(reason: "fenced write")
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
    ///
    /// Plain (non-transactional) write on purpose: this fires in the chaos of
    /// a route change and must be fast; a stale beacon self-expires via atMs.
    /// The client-side `role.isOwner` guard is best-effort — a demoted zombie
    /// owner could still land the write (sync-audit-3.md F10). Impact is
    /// bounded to a 60 s stale beacon that self-expires via handoffActive's
    /// timestamp check; another handoff would overwrite it. Intentional
    /// tradeoff: speed at the route-change instant beats absolute correctness
    /// of a beacon field that already carries expiration semantics.
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
                guard let cur = SessionState(snap: snap) else { throw SyncError.fenced }
                guard cur.epoch == myEpoch, cur.ownerDeviceID == dev else {
                    throw Self.fenceError(cur, myEpoch: myEpoch)
                }
                txn.updateData(["leaseMs": now], forDocument: ref)
            }
        } catch SyncError.seatCleared {
            seatCleared(reason: "fenced lease")
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
        dropOwnership()
        onDeposed?()
    }

    /// Seat cleared, not taken: drop to follower WITHOUT the deposed pause —
    /// no other device holds the audio. The engine reclaims if still playing.
    private func seatCleared(reason: String) {
        guard role.isOwner else { return }
        print("👑→👤 [Sync] Seat cleared while unreachable (\(reason))")
        dropOwnership()
        onSeatCleared?()
    }

    private func dropOwnership() {
        role = .follower
        stopLease()
        retryTask?.cancel()
        outbox = nil          // our buffered state belongs to a reign that ended — discard, never replay
    }
}
