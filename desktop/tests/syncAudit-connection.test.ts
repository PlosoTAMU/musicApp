// Sync audit-3: connection-order + reconciliation invariants across the
// wire-contract types that both iOS and desktop share (protocol.ts is the
// twin of SyncModels.swift). Every assertion here also documents an
// invariant iOS is expected to honor — a failure here means the desktop
// side of the contract is broken; a suspected-iOS failure would need a
// separate GUI check on device.
import { rebase } from "../src/queueSync";
import {
  SessionState, TrackRef, sessionIdle, positionAt, leaseExpired, liveRemoteOwner,
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

// A fixed "now" so lease terms are explicit rather than wall-clock dependent.
const NOW = 1_000_000;

// Scenario A: cold start, singleton doc doesn't exist yet.
// attach() lazy-writes IDLE_SESSION. sessionIdle must be true.
eq("cold start doc is idle", sessionIdle(session(), NOW), true);

// Scenario B: another device is already the owner and playing something.
// The joining device becomes follower and mirrors the state — NOT idle.
const remoteOwnerPlaying = session({
  ownerDeviceID: "OTHER", leaseMs: NOW - 1_000,
  playback: { track: ref("X"), playing: true, pos: 0, anchor: NOW, rate: 1000, dur: 180000, rev: 5 },
});
eq("owner+track playing → not idle", sessionIdle(remoteOwnerPlaying, NOW), false);

// Scenario C: another device WAS the owner but drained the queue and stopped.
// playback.track is nil → sessionIdle so a queue-add starts playback.
const remoteOwnerDrained = session({ ownerDeviceID: "OTHER", leaseMs: NOW - 1_000 });
eq("owner but no track → idle (queue-add starts)", sessionIdle(remoteOwnerDrained, NOW), true);

// Scenario D: previous session left ownerDeviceID = SELF but this session
// just started (relaunch after crash). remote reports SELF as owner but role
// is follower until the release lands. sessionIdle keys off ownerDeviceID +
// track, so SELF-ownership without a track behaves like idle and a queue-add
// starts local playback normally. The UI half of this — isRemoteControlled
// treating SELF as "the remote" — is fixed separately (F1 / sync-audit-4 B1).
const zombieSelfOwner = session({ ownerDeviceID: DEVICE_ID, leaseMs: NOW - 1_000 });
eq("zombie SELF-owner without track → idle", sessionIdle(zombieSelfOwner, NOW), true);

// Scenario E (sync-audit-4 B2): the owner died mid-track. Nothing drains the
// command bus, so the session must read idle — otherwise a queue-add here
// parks behind a track nobody will ever finish.
const deadOwnerMidTrack = session({
  ownerDeviceID: "OTHER", leaseMs: NOW - LEASE_TTL_MS - 1,
  playback: { track: ref("X"), playing: true, pos: 0, anchor: NOW, rate: 1000, dur: 180000, rev: 5 },
});
eq("dead owner mid-track → idle", sessionIdle(deadOwnerMidTrack, NOW), true);
eq("dead owner mid-track → no live remote owner",
  liveRemoteOwner(deadOwnerMidTrack, NOW), false);
eq("live owner mid-track → live remote owner",
  liveRemoteOwner(remoteOwnerPlaying, NOW), true);

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

// consumeHeadRun (sync-audit-4 B5): the owner advanced past leading entries it
// couldn't resolve. Same CAS discipline as consumeHead, over the whole run —
// without it a single unplayable head made every later advance's CAS miss and
// the queue could never drain past it.
eq("consumeHeadRun: exact run at the head → pop all of it",
  ids(rebase({ kind: "consumeHeadRun", expected: ["G1", "G2", "A"] },
             [ref("G1"), ref("G2"), ref("A"), ref("B")])),
  ["B"]);
eq("consumeHeadRun: single-element run behaves like consumeHead",
  ids(rebase({ kind: "consumeHeadRun", expected: ["A"] }, [ref("A"), ref("B")])),
  ["B"]);
eq("consumeHeadRun: a follower inserted INSIDE the run → all-or-nothing no-op",
  rebase({ kind: "consumeHeadRun", expected: ["G1", "G2", "A"] },
         [ref("G1"), ref("NEW"), ref("G2"), ref("A")]),
  null);
eq("consumeHeadRun: a follower inserted BEFORE the run → no-op",
  rebase({ kind: "consumeHeadRun", expected: ["G1", "A"] },
         [ref("NEW"), ref("G1"), ref("A")]),
  null);
eq("consumeHeadRun: queue shorter than the run → no-op",
  rebase({ kind: "consumeHeadRun", expected: ["G1", "G2", "A"] },
         [ref("G1"), ref("G2")]),
  null);
eq("consumeHeadRun: empty run → no-op",
  rebase({ kind: "consumeHeadRun", expected: [] }, [ref("A")]), null);
eq("consumeHeadRun: draining an all-ghost tail empties the queue",
  ids(rebase({ kind: "consumeHeadRun", expected: ["G1", "G2"] },
             [ref("G1"), ref("G2")])),
  []);
eq("consumeHeadRun: id comparison is case-insensitive (sameId)",
  ids(rebase({ kind: "consumeHeadRun", expected: ["g1", "a"] },
             [ref("G1"), ref("A"), ref("B")])),
  ["B"]);

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
// Ownership reconciliation — stale SELF release + F3 (expired-seat clear)
//
// Note on the merge of arpi/audit-3: F2 originally *reclaimed* the seat when
// the doc still named SELF. That was dropped in favour of main's *release*
// (ownerDeviceID = "", playback.playing = false) — a reclaim publishes
// nothing, so the phantom "playing" survives on every other device, and on
// desktop a coordinator-internal takeOver() skips becomeCommandTarget(),
// leaving the app owning a session it isn't listening to. The engine's own
// reconcileLocalPlayback claims the seat once local audio really plays.
// ─────────────────────────────────────────────────────────────────────────

type Role = "none" | "owner" | "follower";

// The coordinator gate: release SELF-ownership left by a dead previous run,
// once, on the first server-confirmed (non-cache) snapshot.
const shouldReleaseStaleSelf = (
  s: SessionState, role: Role, fromCache: boolean, staleChecked: boolean,
): boolean =>
  !fromCache && !staleChecked
  && s.ownerDeviceID.toLowerCase() === DEVICE_ID.toLowerCase()
  && role !== "owner";

// Should fenced-clear when: not owner locally, doc names a NON-SELF owner,
// and that owner's lease has expired.
const shouldClearExpired = (s: SessionState, role: Role, nowMs: number): boolean =>
  role !== "owner"
  && !!s.ownerDeviceID
  && s.ownerDeviceID.toLowerCase() !== DEVICE_ID.toLowerCase()
  && leaseExpired(s, nowMs);

// Stale SELF-ownership release
eq("release: attach as follower, doc names SELF, fresh snapshot → release",
  shouldReleaseStaleSelf(session({ ownerDeviceID: DEVICE_ID, leaseMs: 1_000 }),
                         "follower", false, false), true);
eq("release: cached snapshot says nothing about liveness → skip",
  shouldReleaseStaleSelf(session({ ownerDeviceID: DEVICE_ID, leaseMs: 1_000 }),
                         "follower", true, false), false);
eq("release: already checked this attach → no repeat",
  shouldReleaseStaleSelf(session({ ownerDeviceID: DEVICE_ID, leaseMs: 1_000 }),
                         "follower", false, true), false);
eq("release: SELF is already owner locally → nothing stale",
  shouldReleaseStaleSelf(session({ ownerDeviceID: DEVICE_ID, leaseMs: 1_000 }),
                         "owner", false, false), false);
eq("release: doc names OTHER as owner → not ours to release",
  shouldReleaseStaleSelf(session({ ownerDeviceID: "OTHER", leaseMs: 1_000 }),
                         "follower", false, false), false);
eq("release: doc is idle → nothing to release",
  shouldReleaseStaleSelf(session({ ownerDeviceID: "" }),
                         "follower", false, false), false);
eq("release: device id compare is case-insensitive (sameId)",
  shouldReleaseStaleSelf(session({ ownerDeviceID: DEVICE_ID.toLowerCase(), leaseMs: 1 }),
                         "follower", false, false), true);

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
eq("F3: SELF-owned doc while follower (zombie) → release handles it, not F3",
  shouldClearExpired(session({ ownerDeviceID: DEVICE_ID, leaseMs: 100_000 }),
                     "follower", 100_000 + LEASE_TTL_MS + 1), false);
eq("F3: runs on every online snapshot, not just the first — an owner can die mid-session",
  shouldClearExpired(session({ ownerDeviceID: "OTHER", leaseMs: 100_000 }),
                     "follower", 100_000 + LEASE_TTL_MS * 10), true);

console.log(`syncAudit-connection: ${n}/${n} PASS`);
