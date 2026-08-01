// Twin of Sync/SessionCoordinator.swift — fencing, lease, single-slot outbox.
// Shared-secret model: one Firebase account for the whole home, singleton
// session doc at users/{uid}/sync/session. Devices attach on boot; nobody
// "creates" or "joins" a session. Ownership (which device plays audio) is
// still epoch-fenced exactly as before:
//  1. Fenced writes: every owner write asserts epoch + ownerDeviceID in a txn.
//  2. Ownership changes online-only (transactions fail offline).
//  3. No stale replay: latest-state outbox, discarded on demotion.
import {
  Firestore, DocumentReference, doc, getDoc, setDoc, onSnapshot,
  runTransaction, updateDoc, deleteField, Unsubscribe,
} from "firebase/firestore";
import {
  SessionState, PlaybackState, DEVICE_ID, FENCED, sameId, leaseExpired,
} from "./protocol";
import { serverClock } from "./serverClock";

export type Role = "none" | "owner" | "follower";

const IDLE_SESSION = (): Omit<SessionState, "playback"> & { playback: PlaybackState } => ({
  epoch: 1,
  ownerDeviceID: "",           // idle — first play() on any device takes over
  leaseMs: 0,
  playback: { playing: false, pos: 0, anchor: 0, rate: 1000, dur: 0, rev: 0 },
  queue: [],
  queueVersion: 1,
  updatedBy: DEVICE_ID,
});

export class SessionCoordinator {
  role: Role = "none";
  myEpoch = 0;
  remote?: SessionState;
  online = true;
  uid = "";
  /** Offline preview: no auth, no Firestore — session state lives in memory. */
  demo = false;

  onDeposed?: () => void;
  /** Every parsed snapshot, echoes included. `isEcho` = authored by this
   *  device. After a relaunch the first snapshot is often our own last write —
   *  filtering it out starved the join-resync ping and the queue mirror
   *  ("connect and now playing never loads"). Loop-sensitive consumers use
   *  the flag. */
  onRemote?: (s: SessionState, isEcho: boolean) => void;
  onChange?: () => void;

  private unsub?: Unsubscribe;
  private leaseTimer?: ReturnType<typeof setInterval>;
  private clockTimer?: ReturnType<typeof setInterval>;
  private outbox?: PlaybackState;
  private retryTimer?: ReturnType<typeof setTimeout>;
  private retryDelay = 2000;
  private listenRetryTimer?: ReturnType<typeof setTimeout>;
  private listenRetryDelay = 2000;
  private staleChecked = false;
  private staleReleaseInFlight = false;

  constructor(readonly db: Firestore) {}

  get ref(): DocumentReference | undefined {
    return this.uid ? doc(this.db, "users", this.uid, "sync", "session") : undefined;
  }

  // ── Lifecycle: attach is the whole story now ──────────────────────────

  /** Offline preview — this device is the owner of an in-memory session. */
  attachDemo() {
    this.demo = true;
    this.role = "owner";
    this.myEpoch = 1;
    this.remote = { ...IDLE_SESSION(), ownerDeviceID: DEVICE_ID };
    this.onChange?.();
  }

  async attach(uid: string) {
    this.uid = uid;
    const ref = this.ref!;
    // Lazily create the singleton. Plain read-then-write is fine: a racing
    // second device's setDoc writes the identical idle doc.
    if (!(await getDoc(ref)).exists()) await setDoc(ref, IDLE_SESSION());
    await serverClock.prime(this.db, uid);
    this.role = "follower";
    this.myEpoch = 0;

    this.listen(ref);

    // 5 min, matching SessionCoordinator.swift's clockTimer. Each tick is a
    // forced Firestore write + server read on every connected device; device
    // clocks don't drift anywhere near the ~750 ms the engine tolerates on a
    // 60 s cycle, so the extra 4× of traffic bought nothing (sync-audit-4 L17).
    this.clockTimer = setInterval(() => {
      if (this.uid) serverClock.sample(this.db, this.uid).catch(() => {});
    }, 300_000);
    this.onChange?.();
  }

  detach() {
    this.unsub?.(); this.unsub = undefined;
    if (this.leaseTimer) clearInterval(this.leaseTimer);
    if (this.clockTimer) clearInterval(this.clockTimer);
    if (this.retryTimer) clearTimeout(this.retryTimer);
    if (this.listenRetryTimer) clearTimeout(this.listenRetryTimer);
    this.outbox = undefined;
    this.role = "none"; this.myEpoch = 0; this.remote = undefined; this.uid = "";
    this.demo = false;
    this.staleChecked = false;
    this.staleReleaseInFlight = false;
    this.onChange?.();
  }

  /** Clear ownership a dead previous run of THIS device left behind. Fenced on
   *  the observed epoch — any concurrent takeover (ours or another device's)
   *  bumps it and this becomes a no-op.
   *
   *  FENCED means the world moved on, so there is nothing left to release and
   *  the latch closes. Any other error is transient (offline, contention):
   *  leave the latch open so the next fresh snapshot retries. Twin of
   *  SessionCoordinator.swift's releaseStaleOwnership. */
  private async releaseStaleOwnership(epoch: number) {
    const ref = this.ref;
    if (!ref) { this.staleReleaseInFlight = false; return; }
    try {
      await runTransaction(this.db, async txn => {
        const snap = await txn.get(ref);
        const cur = snap.data() as SessionState | undefined;
        if (!cur || cur.epoch !== epoch || !sameId(cur.ownerDeviceID, DEVICE_ID))
          throw FENCED;
        txn.update(ref, {
          ownerDeviceID: "", "playback.playing": false, updatedBy: DEVICE_ID,
        });
      });
      this.staleChecked = true;
      console.log("[sync] released stale self-ownership (crashed previous run)");
    } catch (e) {
      if (e === FENCED) this.staleChecked = true;   // superseded — nothing to do
      else console.log("[sync] stale-ownership release failed, will retry", e);
    } finally {
      this.staleReleaseInFlight = false;
    }
  }

  /** (Re)subscribes the session listener. On a terminal listen error (the SDK
   *  gives up retrying internally — e.g. a stream reset it can't recover),
   *  mark offline and resubscribe from scratch with backoff, so a wedged
   *  listener can't leave the app permanently "offline" until restart. */
  private listen(ref: DocumentReference) {
    this.unsub?.();
    this.unsub = onSnapshot(ref, { includeMetadataChanges: true }, snap => {
      this.listenRetryDelay = 2000;
      const wasOnline = this.online;
      this.online = !snap.metadata.fromCache;
      if (!wasOnline && this.online) this.flushOutbox();

      const state = snap.data() as SessionState | undefined;
      if (state) {
        this.remote = state;
        if (this.role === "owner" && state.epoch > this.myEpoch) {
          this.demote(`epoch ${state.epoch} > ${this.myEpoch}`);
        }
        // Crashed-owner recovery: doc names THIS device as owner but we booted
        // as a follower — a previous process died mid-reign. Release once, on
        // the first server-confirmed snapshot (fenced on the epoch seen here,
        // so a takeover we start meanwhile can never be undone).
        //
        // NOTE (merge of arpi/audit-3): audit-3's F2 proposed *reclaiming* the
        // seat here. Release wins — a reclaim from inside the coordinator never
        // calls engine.becomeCommandTarget(), so the app would own the session
        // while listening to no commands, and it publishes nothing, leaving the
        // phantom `playing: true` alive on every other device.
        //
        // The latch is set only when the release TRANSACTION SUCCEEDS (or when
        // there was nothing to release). Latching before the write meant one
        // transient failure wedged the app in a fake "remote controlled by
        // itself" mode for the rest of the process (sync-audit-4 B1).
        if (!snap.metadata.fromCache && !this.staleChecked
            && !this.staleReleaseInFlight) {
          if (sameId(state.ownerDeviceID, DEVICE_ID) && this.role !== "owner") {
            this.staleReleaseInFlight = true;
            void this.releaseStaleOwnership(state.epoch);
          } else {
            this.staleChecked = true;   // nothing stale to release
          }
        }

        // F3 (sync-audit-3.md) — a DIFFERENT device owns the seat but hasn't
        // heartbeated in > LEASE_TTL_MS. Fenced-CAS ownerDeviceID back to ""
        // so the next play() on any device takes it cleanly. Every online
        // snapshot, not just the first: an owner can die mid-session. Skipped
        // until the ServerClock has real samples — wall-clock skew alone must
        // not nuke a live owner's seat. Twin of SessionCoordinator.swift.
        if (this.online && this.role !== "owner"
            && state.ownerDeviceID
            && !sameId(state.ownerDeviceID, DEVICE_ID)
            && serverClock.isSynced
            && leaseExpired(state, serverClock.nowMs)) {
          void this.clearExpiredOwnership(ref, state.ownerDeviceID);
        }

        // Skip cached snapshots so onRemote doesn't paint the UI with hours-
        // old state after a network hiccup (sync-audit-3.md F5). `remote` above
        // keeps the last online value, so consumers reading it directly still
        // see the last known session. Echoes still pass through (isEcho set) —
        // after a relaunch the first frame is usually our own last write and it
        // must still populate the mirror.
        if (this.online) this.onRemote?.(state, state.updatedBy === DEVICE_ID);
      }
      this.onChange?.();
    }, err => {
      console.log(`[sync] listener error (${err.code}) — will re-subscribe`);
      this.online = false;
      this.onChange?.();
      if (this.listenRetryTimer) clearTimeout(this.listenRetryTimer);
      const d = this.listenRetryDelay;
      this.listenRetryDelay = Math.min(this.listenRetryDelay * 2, 30_000);
      this.listenRetryTimer = setTimeout(() => { if (this.uid) this.listen(ref); }, d);
    });
  }

  // ── Takeover (returns pre-takeover state for handover continuity) ─────

  async takeOver(): Promise<SessionState> {
    if (this.demo) { this.role = "owner"; return this.remote!; }
    const ref = this.ref;
    if (!ref) throw new Error("not connected");
    const now = serverClock.nowMs;
    const pre = await runTransaction(this.db, async txn => {
      const snap = await txn.get(ref);
      const cur = snap.data() as SessionState | undefined;
      if (!cur) throw new Error("corrupt session");
      txn.update(ref, {
        epoch: cur.epoch + 1, ownerDeviceID: DEVICE_ID,
        leaseMs: now, "playback.rev": 0, updatedBy: DEVICE_ID,
        handoff: deleteField(), // takeover consumes any pending handoff
      });
      return cur;
    });
    this.role = "owner"; this.myEpoch = pre.epoch + 1;
    this.outbox = undefined;
    this.startLease();
    this.onChange?.();
    return pre;
  }

  // ── Fenced publish + outbox ────────────────────────────────────────────

  async publishPlayback(state: PlaybackState) {
    if (this.demo) {
      if (this.remote) {
        this.remote.playback = { ...state, rev: this.remote.playback.rev + 1 };
        this.remote.updatedBy = DEVICE_ID;
        this.onChange?.();
      }
      return;
    }
    const ref = this.ref;
    if (this.role !== "owner" || !ref) return;
    const epoch = this.myEpoch;
    try {
      await runTransaction(this.db, async txn => {
        const snap = await txn.get(ref);
        const cur = snap.data() as SessionState | undefined;
        if (!cur || cur.epoch !== epoch || !sameId(cur.ownerDeviceID, DEVICE_ID))
          throw FENCED;
        txn.update(ref, {
          playback: { ...state, rev: cur.playback.rev + 1 },
          updatedBy: DEVICE_ID,
        });
      });
      this.outbox = undefined; this.retryDelay = 2000;
    } catch (e) {
      if (e === FENCED) this.demote("fenced write");
      else { this.outbox = state; this.scheduleRetry(); }
    }
  }

  private flushOutbox() {
    if (this.outbox) void this.publishPlayback(this.outbox);
  }

  /** F3 fenced-CAS clear of a stale owner. No-op unless the doc still names
   *  the expected dead owner AND its lease is still expired at commit time —
   *  so races between followers all trying to clear the seat resolve safely:
   *  the first wins, the rest see updated state and no-op. */
  private async clearExpiredOwnership(ref: DocumentReference, expectedOwner: string) {
    try {
      await runTransaction(this.db, async txn => {
        const snap = await txn.get(ref);
        const cur = snap.data() as SessionState | undefined;
        if (!cur || cur.ownerDeviceID !== expectedOwner
            || !leaseExpired(cur, serverClock.nowMs)) return;
        txn.update(ref, {
          ownerDeviceID: "",
          leaseMs: serverClock.nowMs,
          updatedBy: DEVICE_ID,
        });
      });
    } catch { /* best-effort */ }
  }

  private scheduleRetry() {
    if (this.retryTimer) clearTimeout(this.retryTimer);
    const d = this.retryDelay;
    this.retryDelay = Math.min(this.retryDelay * 2, 30_000);
    this.retryTimer = setTimeout(() => this.flushOutbox(), d);
  }

  // ── Bluetooth handoff beacon ───────────────────────────────────────────

  /** Owner's audio output vanished → advertise a 60 s handoff window. Plain
   *  write on purpose — fires mid-route-change, must be fast; a stale beacon
   *  self-expires via atMs. Client-side role guard is best-effort; a demoted
   *  zombie owner could still land the write (sync-audit-3.md F10). Impact
   *  is bounded to a 60 s stale beacon; another handoff overwrites it.
   *  Intentional: speed here beats absolute correctness on a field that
   *  already carries expiration semantics. */
  async postHandoff() {
    const ref = this.ref;
    if (this.demo || this.role !== "owner" || !ref) return;
    await updateDoc(ref, {
      handoff: { by: DEVICE_ID, atMs: serverClock.nowMs },
      updatedBy: DEVICE_ID,
    }).catch(() => {});
  }

  /** Output came back to THIS device (or handoff otherwise resolved). */
  async clearHandoff() {
    const ref = this.ref;
    if (this.demo || !ref) return;
    await updateDoc(ref, { handoff: deleteField() }).catch(() => {});
  }

  // ── Lease ──────────────────────────────────────────────────────────────

  private startLease() {
    if (this.leaseTimer) clearInterval(this.leaseTimer);
    this.leaseTimer = setInterval(() => void this.renewLease(), 20_000);
  }

  private async renewLease() {
    const ref = this.ref;
    if (this.role !== "owner" || !ref) return;
    const epoch = this.myEpoch, now = serverClock.nowMs;
    try {
      await runTransaction(this.db, async txn => {
        const snap = await txn.get(ref);
        const cur = snap.data() as SessionState | undefined;
        if (!cur || cur.epoch !== epoch || !sameId(cur.ownerDeviceID, DEVICE_ID))
          throw FENCED;
        txn.update(ref, { leaseMs: now });
      });
    } catch (e) {
      if (e === FENCED) this.demote("fenced lease");
    }
  }

  private demote(reason: string) {
    if (this.role !== "owner") return;
    console.log(`[sync] deposed (${reason})`);
    this.role = "follower"; this.myEpoch = 0;
    if (this.leaseTimer) clearInterval(this.leaseTimer);
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.outbox = undefined;
    this.onDeposed?.();
    this.onChange?.();
  }
}
