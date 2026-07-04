// Twin of Sync/QueueSync.swift — intent ops rebased by trackID, CAS consumeHead,
// version-basis guard for offline replaceAll replays.
import { Firestore, DocumentReference, runTransaction } from "firebase/firestore";
import { QueueOp, TrackRef, SessionState, DEVICE_ID, QUEUE_STALE, sameId } from "./protocol";

export class QueueSync {
  private pendingReplace?: { queue: TrackRef[]; basis: number };

  constructor(
    private db: Firestore,
    private ref: () => DocumentReference | undefined,
  ) {}

  onOnline() { this.flushPending(); }

  /** `isReplay` comes only from flushPending — inferring it from pendingReplace
   *  made a LIVE edit inherit replay semantics while an offline replay sat
   *  buffered, so it could be discarded as stale. */
  async apply(op: QueueOp, basisVersion: number, isReplay = false) {
    const ref = this.ref();
    if (!ref) return;
    try {
      await runTransaction(this.db, async txn => {
        const snap = await txn.get(ref);
        const cur = snap.data() as SessionState | undefined;
        if (!cur) throw new Error("corrupt");
        if (op.kind === "replaceAll" && isReplay && cur.queueVersion !== basisVersion)
          throw QUEUE_STALE;
        const rebased = rebase(op, cur.queue);
        if (!rebased) return;                                  // no-op
        txn.update(ref, {
          queue: rebased, queueVersion: cur.queueVersion + 1, updatedBy: DEVICE_ID,
        });
      });
      this.pendingReplace = undefined;
    } catch (e) {
      if (e === QUEUE_STALE) {
        this.pendingReplace = undefined;                       // remote is newer intent
        console.log("[queueSync] offline replay discarded (stale basis)");
      } else if (op.kind === "replaceAll") {
        this.pendingReplace = { queue: op.queue, basis: basisVersion };
      }
      // lost single ops offline are user-recoverable; wrong bulk replays are not
    }
  }

  private flushPending() {
    const p = this.pendingReplace;
    if (p) void this.apply({ kind: "replaceAll", queue: p.queue }, p.basis, true);
  }
}

/** Pure — unit-testable without Firestore. null = no-op. */
export function rebase(op: QueueOp, queue: TrackRef[]): TrackRef[] | null {
  const idx = (id: string) => queue.findIndex(t => sameId(t.id, id));
  const insertAt = (afterId: string | null, q: TrackRef[]) => {
    if (afterId === null) return 0;
    const i = q.findIndex(t => sameId(t.id, afterId));
    return i < 0 ? q.length : i + 1;                           // anchor gone → append
  };
  switch (op.kind) {
    case "insert": {
      const q = [...queue];
      q.splice(insertAt(op.afterId, q), 0, op.ref);
      return q;
    }
    case "remove": {
      const i = idx(op.id);
      if (i < 0) return null;
      const q = [...queue]; q.splice(i, 1); return q;
    }
    case "move": {
      const i = idx(op.id);
      if (i < 0) return null;
      const q = [...queue];
      const [item] = q.splice(i, 1);
      q.splice(insertAt(op.afterId, q), 0, item);
      return q;
    }
    case "consumeHead":
      // CAS: only pop if the head is what the owner actually played.
      return queue[0] && sameId(queue[0].id, op.expected) ? queue.slice(1) : null;
    case "replaceAll":
      return op.queue;
  }
}
