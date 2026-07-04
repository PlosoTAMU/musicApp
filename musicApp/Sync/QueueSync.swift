import Foundation
import Combine
import FirebaseFirestore

/// Queue reconciliation.
///
/// Two write shapes:
///  - **Intent ops** (`insert`/`remove`/`move`/`consumeHead`): rebased inside a
///    transaction against the *current* remote queue, anchored by trackID — never
///    by index. Two devices editing concurrently both land; a stale index can't
///    delete the wrong row.
///  - **`replaceAll`**: LWW bulk write for observed local edits (drag-reorder,
///    clear). Live edits win unconditionally (they are the newest user intent);
///    *offline replays* carry the version basis they were built on and lose to
///    anything newer (`SyncError.queueStale`) — an offline device must not
///    resurrect a queue the rest of the session already moved past.
final class QueueSync {

    private let db: Firestore
    private let sessionRef: () -> DocumentReference?

    /// Single-slot offline outbox: (queue, version basis it was derived from).
    private var pendingReplace: (queue: [TrackRef], basis: Int)?
    private var bag = Set<AnyCancellable>()

    init(db: Firestore, sessionRef: @escaping () -> DocumentReference?,
         isOnline: AnyPublisher<Bool, Never>) {
        self.db = db
        self.sessionRef = sessionRef
        isOnline
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.flushPending() }
            .store(in: &bag)
    }

    // MARK: - Public API

    /// `isReplay` is passed explicitly by flushPending — inferring it from
    /// pendingReplace was a bug: a LIVE edit made while an offline replay sat
    /// buffered would inherit replay semantics and could be discarded as stale.
    func apply(_ op: QueueOp, basisVersion: Int, isReplay: Bool = false) async {
        guard let ref = sessionRef() else { return }
        let dev = SyncDevice.id
        do {
            try await db.txn { txn in
                let snap = try txn.getDocument(ref)
                guard let cur = SessionState(snap: snap) else { throw SyncError.corrupt }

                // Stale-replay guard applies only to bulk overwrites.
                if case .replaceAll = op, isReplay, cur.queueVersion != basisVersion {
                    throw SyncError.queueStale
                }
                guard let rebased = Self.rebase(op, onto: cur.queue) else { return } // no-op
                txn.updateData([
                    "queue": rebased.map(\.dict),
                    "queueVersion": cur.queueVersion + 1,
                    "updatedBy": dev,
                ], forDocument: ref)
            }
            pendingReplace = nil
        } catch SyncError.queueStale {
            pendingReplace = nil               // we lost — remote queue is newer intent
            print("🗑 [QueueSync] Offline queue replay discarded (stale basis)")
        } catch is SyncError {
            pendingReplace = nil
        } catch {
            // Offline / transient. Only bulk state is worth buffering; a lost
            // single op offline is recoverable by the user, a wrong bulk
            // overwrite on reconnect is not.
            if case .replaceAll(let q) = op {
                pendingReplace = (q, basisVersion)
            }
        }
    }

    private func flushPending() {
        guard let (q, basis) = pendingReplace else { return }
        Task { await apply(.replaceAll(q), basisVersion: basis, isReplay: true) }
    }

    // MARK: - Rebase (pure — unit-testable without Firestore)

    /// Returns nil when the op is a no-op against the current queue
    /// (target vanished, CAS failed). Anchors resolve by trackID.
    static func rebase(_ op: QueueOp, onto queue: [TrackRef]) -> [TrackRef]? {
        switch op {
        case .insert(let ref, let afterID):
            var q = queue
            q.insert(ref, at: insertionIndex(afterID: afterID, in: q))
            return q

        case .remove(let id):
            guard let idx = queue.firstIndex(where: { $0.id == id }) else { return nil }
            var q = queue
            q.remove(at: idx)
            return q

        case .move(let id, let afterID):
            guard let idx = queue.firstIndex(where: { $0.id == id }) else { return nil }
            var q = queue
            let item = q.remove(at: idx)
            q.insert(item, at: insertionIndex(afterID: afterID, in: q))
            return q

        case .consumeHead(let expected):
            // CAS: only pop if the head is still what the owner played.
            // If a follower reordered/inserted meanwhile, their edit survives.
            guard queue.first?.id == expected else { return nil }
            return Array(queue.dropFirst())

        case .replaceAll(let q):
            return q
        }
    }

    private static func insertionIndex(afterID: UUID?, in queue: [TrackRef]) -> Int {
        guard let afterID else { return 0 }                                   // nil = front
        guard let idx = queue.firstIndex(where: { $0.id == afterID }) else {
            return queue.count                                                // anchor gone → append
        }
        return idx + 1
    }
}
