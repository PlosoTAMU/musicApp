// Sync audit-3: connection-order + reconciliation invariants across the
// wire-contract types that both iOS and desktop share (protocol.ts is the
// twin of SyncModels.swift). Every assertion here also documents an
// invariant iOS is expected to honor — a failure here means the desktop
// side of the contract is broken; a suspected-iOS failure would need a
// separate GUI check on device.
import { rebase } from "../src/queueSync";
import {
  SessionState, TrackRef, sessionIdle, positionAt, leaseExpired,
  handoffActive, DEVICE_ID, LEASE_TTL_MS, HANDOFF_WINDOW_MS,
} from "../src/protocol";

let n = 0;
function eq(name: string, got: unknown, want: unknown) {
  n++;
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) throw new Error(`${name}: got ${g}, want ${w}`);
}

const ref = (id: string): TrackRef => ({ id, name: id, folder: "F" });
const ids = (q: TrackRef[] | null) => q?.map(t => t.id) ?? null;

const session = (opts: Partial<SessionState> = {}): SessionState => ({
  epoch: 1, ownerDeviceID: "", leaseMs: 0,
  playback: { playing: false, pos: 0, anchor: 0, rate: 1000, dur: 0, rev: 0 },
  queue: [], queueVersion: 0, updatedBy: "T",
  ...opts,
});

// ─────────────────────────────────────────────────────────────────────────
// Connection-order semantics — the states a device sees at attach() time
// ─────────────────────────────────────────────────────────────────────────

// Scenario A: cold start, singleton doc doesn't exist yet.
// attach() lazy-writes IDLE_SESSION. sessionIdle must be true.
eq("cold start doc is idle", sessionIdle(session()), true);

// Scenario B: another device is already the owner and playing something.
// The joining device becomes follower and mirrors the state — NOT idle.
const remoteOwnerPlaying = session({
  ownerDeviceID: "OTHER", leaseMs: 1_000_000,
  playback: { track: ref("X"), playing: true, pos: 0, anchor: 1_000_000, rate: 1000, dur: 180000, rev: 5 },
});
eq("owner+track playing → not idle", sessionIdle(remoteOwnerPlaying), false);

// Scenario C: another device WAS the owner but drained the queue and stopped.
// playback.track is nil → sessionIdle so a queue-add starts playback.
const remoteOwnerDrained = session({ ownerDeviceID: "OTHER", leaseMs: 1_000_000 });
eq("owner but no track → idle (queue-add starts)", sessionIdle(remoteOwnerDrained), true);

// Scenario D: previous session left ownerDeviceID = SELF but this session
// just started (relaunch after crash). remote reports SELF as owner but
// role is follower until first play. sessionIdle uses ownerDeviceID only;
// SELF-ownership without a track behaves like idle. This is the "zombie
// owner" case — the invariant here confirms queue-add will start local
// playback normally, but the isRemoteControlled UI in ContentView.swift:44
// STILL treats non-empty ownerDeviceID as "remote-controlled" without
// checking if it's SELF. Recorded as F1 in the audit findings.
const zombieSelfOwner = session({ ownerDeviceID: DEVICE_ID, leaseMs: 1_000 });
eq("zombie SELF-owner without track → idle", sessionIdle(zombieSelfOwner), true);

// ─────────────────────────────────────────────────────────────────────────
// Lease expiry — followers should be able to reason about staleness
// ─────────────────────────────────────────────────────────────────────────

eq("fresh lease is not expired",
  leaseExpired(session({ leaseMs: 100_000 }), 100_000 + LEASE_TTL_MS - 1), false);
eq("expired lease is expired",
  leaseExpired(session({ leaseMs: 100_000 }), 100_000 + LEASE_TTL_MS + 1), true);
eq("exact-TTL boundary — not expired (owner just wrote it)",
  leaseExpired(session({ leaseMs: 100_000 }), 100_000 + LEASE_TTL_MS), false);

// ─────────────────────────────────────────────────────────────────────────
// Handoff beacon — cross-device Bluetooth continuity
// ─────────────────────────────────────────────────────────────────────────

const withHandoff = (by: string, atMs: number) => session({
  ownerDeviceID: "OTHER",
  handoff: { by, atMs },
});
eq("no handoff → not active", handoffActive(session(), 100_000), false);
eq("handoff from OTHER within window → active",
  handoffActive(withHandoff("OTHER", 100_000), 100_000 + 1_000), true);
eq("handoff from SELF is never active (own beacon)",
  handoffActive(withHandoff(DEVICE_ID, 100_000), 100_000 + 1_000), false);
eq("stale handoff (beyond window) → not active",
  handoffActive(withHandoff("OTHER", 100_000), 100_000 + HANDOFF_WINDOW_MS + 1), false);

// ─────────────────────────────────────────────────────────────────────────
// Extrapolation — followers compute position without streaming
// ─────────────────────────────────────────────────────────────────────────

const paused = { playing: false, pos: 30000, anchor: 100_000, rate: 1000, dur: 180000, rev: 1 };
eq("paused: position frozen at pos regardless of clock",
  positionAt(paused, 999_999_999), 30000);

const playing1x = { playing: true, pos: 30000, anchor: 100_000, rate: 1000, dur: 180000, rev: 1 };
eq("1× rate: elapsed ms adds directly to pos",
  positionAt(playing1x, 100_000 + 5000), 30000 + 5000);

const playing2x = { playing: true, pos: 30000, anchor: 100_000, rate: 2000, dur: 180000, rev: 1 };
eq("2× rate: elapsed doubles",
  positionAt(playing2x, 100_000 + 5000), 30000 + 10000);

const playingHalf = { playing: true, pos: 30000, anchor: 100_000, rate: 500, dur: 180000, rev: 1 };
eq("0.5× rate: elapsed halves",
  positionAt(playingHalf, 100_000 + 10000), 30000 + 5000);

eq("clock rolled backwards clamps elapsed to 0 (never rewinds pos)",
  positionAt(playing1x, 100_000 - 1000), 30000);

// ─────────────────────────────────────────────────────────────────────────
// Reconciliation — takeover races via rebase (queue is shared)
// ─────────────────────────────────────────────────────────────────────────

// Two devices concurrently insert. Rebase by anchor id, not index — both
// survive because iOS anchors on `afterID`, not position.
eq("concurrent insert at head is idempotent by anchor",
  ids(rebase({ kind: "insert", ref: ref("A"), afterId: null }, [ref("B"), ref("C")])),
  ["A", "B", "C"]);

// If a device is offline and its queue basis is stale, replayAll is
// discarded by QueueSync (versionBasis check), but a single insert with
// an anchor that vanished should append (anchor gone → append).
eq("insert whose anchor was removed → append tail",
  ids(rebase({ kind: "insert", ref: ref("N"), afterId: "GONE" }, [ref("A"), ref("B")])),
  ["A", "B", "N"]);

// consumeHead is CAS: only pops if the head is what the owner played.
// A follower's insert that landed FIRST protects against a stale pop.
eq("consumeHead CAS: mismatched head → no-op",
  rebase({ kind: "consumeHead", expected: "A" }, [ref("Z"), ref("A")]), null);
eq("consumeHead CAS: matching head → pop",
  ids(rebase({ kind: "consumeHead", expected: "A" }, [ref("A"), ref("B")])),
  ["B"]);

// Move rebase: moving a row that no longer exists is a no-op (the concurrent
// deletion wins — no ghost row resurrects).
eq("move on vanished id → no-op",
  rebase({ kind: "move", id: "GONE", afterId: null }, [ref("A"), ref("B")]),
  null);

// ─────────────────────────────────────────────────────────────────────────
// Ownership handover — playback state preservation across takeover
// ─────────────────────────────────────────────────────────────────────────

// A follower takes over mid-song. positionAt on the pre-takeover state
// gives the extrapolated position at handover time — the new owner MUST
// use this, not the raw pos (which is stale by anchor→now).
const preTakeoverPlaying = {
  playing: true, pos: 45000, anchor: 500_000, rate: 1000, dur: 180000, rev: 12,
};
eq("takeover continuity: extrapolate at handover instant",
  positionAt(preTakeoverPlaying, 500_000 + 3_000), 48000);

// Paused handover: forcePlay is false; new owner plays startPaused=true.
// Extrapolation for a paused state is fixed at pos; the invariant is that
// the position DOES NOT change during a paused handover.
const preTakeoverPaused = {
  playing: false, pos: 45000, anchor: 500_000, rate: 1000, dur: 180000, rev: 12,
};
eq("paused takeover: pos preserved across the handover instant",
  positionAt(preTakeoverPaused, 500_000 + 3_000), 45000);

// ─────────────────────────────────────────────────────────────────────────
// Phase-3 predicates — F2 (zombie SELF-owner reclaim) + F3 (expired-seat clear)
// ─────────────────────────────────────────────────────────────────────────

type Role = "none" | "owner" | "follower";

// The coordinator gate: reclaim on the first fresh snapshot if the doc
// still names SELF as owner and we're a follower (attached role).
const shouldReclaim = (s: SessionState, role: Role, firstFresh: boolean): boolean =>
  firstFresh && role === "follower" && s.ownerDeviceID === DEVICE_ID;

// Should fenced-clear when: not owner locally, doc names a NON-SELF owner,
// and that owner's lease has expired.
const shouldClearExpired = (s: SessionState, role: Role, nowMs: number): boolean =>
  role !== "owner"
  && !!s.ownerDeviceID
  && s.ownerDeviceID !== DEVICE_ID
  && leaseExpired(s, nowMs);

// F2 — zombie SELF-owner cases
eq("F2: attach as follower, doc names SELF, first fresh snapshot → reclaim",
  shouldReclaim(session({ ownerDeviceID: DEVICE_ID, leaseMs: 1_000 }),
                "follower", true), true);
eq("F2: subsequent snapshot after reclaim is not first-fresh → no re-reclaim",
  shouldReclaim(session({ ownerDeviceID: DEVICE_ID, leaseMs: 1_000 }),
                "follower", false), false);
eq("F2: SELF is already owner locally → no reclaim (takeover already done)",
  shouldReclaim(session({ ownerDeviceID: DEVICE_ID, leaseMs: 1_000 }),
                "owner", true), false);
eq("F2: doc names OTHER as owner → no reclaim",
  shouldReclaim(session({ ownerDeviceID: "OTHER", leaseMs: 1_000 }),
                "follower", true), false);
eq("F2: doc is idle → no reclaim (nothing to reclaim)",
  shouldReclaim(session({ ownerDeviceID: "" }), "follower", true), false);

// F3 — expired-seat cases
eq("F3: OTHER owns, lease expired → clear",
  shouldClearExpired(session({ ownerDeviceID: "OTHER", leaseMs: 100_000 }),
                     "follower", 100_000 + LEASE_TTL_MS + 1), true);
eq("F3: OTHER owns, lease fresh → do not clear",
  shouldClearExpired(session({ ownerDeviceID: "OTHER", leaseMs: 100_000 }),
                     "follower", 100_000 + 1_000), false);
eq("F3: idle session → nothing to clear",
  shouldClearExpired(session({ ownerDeviceID: "" }),
                     "follower", 100_000 + LEASE_TTL_MS + 1), false);
eq("F3: SELF is the owner locally (owner role) → do not clear our own seat",
  shouldClearExpired(session({ ownerDeviceID: DEVICE_ID, leaseMs: 100_000 }),
                     "owner", 100_000 + LEASE_TTL_MS + 1), false);
eq("F3: SELF-owned session doc but we're follower (zombie) → F2 handles this, not F3",
  shouldClearExpired(session({ ownerDeviceID: DEVICE_ID, leaseMs: 100_000 }),
                     "follower", 100_000 + LEASE_TTL_MS + 1), false);

console.log(`syncAudit-connection: ${n}/${n} PASS`);
