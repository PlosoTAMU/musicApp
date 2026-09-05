// Sync audit 5 — seat lifecycle invariants shared by both ends (protocol.ts is
// the twin of SyncModels.swift / SessionCoordinator.swift). Pins:
//   S2  frozenPlayback: the record a peer writes when it clears a dead owner's
//       seat, or an owner writes when it releases voluntarily.
//   S3  seatClearedUnderOwner: "our epoch, not our device" = cleared, not taken.
import {
  SessionState, PlaybackState, TrackRef, DEVICE_ID, LEASE_TTL_MS,
  frozenPlayback, seatClearedUnderOwner, positionAt, sessionIdle, liveRemoteOwner,
} from "../src/protocol";

let n = 0;
function eq(name: string, got: unknown, want: unknown) {
  n++;
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) throw new Error(`${name}: got ${g}, want ${w}`);
}

const ref = (id: string): TrackRef => ({ id, name: id, folder: "F" });
const session = (opts: Partial<SessionState> = {}): SessionState => ({
  epoch: 7, ownerDeviceID: "OTHER", leaseMs: 0,
  playback: { playing: false, pos: 0, anchor: 0, rate: 1000, dur: 0, rev: 0 },
  queue: [], queueVersion: 0, updatedBy: "T",
  ...opts,
});

// ── S2: frozenPlayback ────────────────────────────────────────────────────

// Owner published pos=30 s at anchor=100 s, heartbeated at 110 s, then died.
// A peer clears the seat at 170 s (lease long expired).
const LEASE = 110_000, CLEAR_AT = 170_000;
const live: PlaybackState = {
  track: ref("X"), playing: true, pos: 30_000, anchor: 100_000, rate: 1000, dur: 180_000, rev: 9,
};
const frozen = frozenPlayback(live, LEASE, CLEAR_AT);

eq("frozen: paused", frozen.playing, false);
eq("frozen: position = where the owner was at its LAST HEARTBEAT (30 s + 10 s), not extrapolated to the clear instant",
  frozen.pos, 40_000);
eq("frozen: anchor is the clear instant", frozen.anchor, CLEAR_AT);
eq("frozen: track/rate/dur/loop carried through",
  [frozen.track?.id, frozen.rate, frozen.dur], ["X", 1000, 180_000]);

// The whole point: followers must NOT see the track at its end. Before S2 the
// cleared doc kept playing:true and a stale anchor, so positionAt clamped to dur.
eq("REGRESSION: un-frozen cleared record extrapolates to the END of the track",
  positionAt(live, CLEAR_AT + 120_000), 180_000);
eq("frozen record stays put no matter how late it is read",
  positionAt(frozen, CLEAR_AT + 60_000), 40_000);
eq("frozen record stays put even a day later", positionAt(frozen, CLEAR_AT + 86_400_000), 40_000);

// Anchor newer than the lease (publish landed after the last heartbeat): no
// negative elapsed — freeze at pos.
const publishedAfterLease: PlaybackState = { ...live, anchor: LEASE + 5_000, pos: 50_000 };
eq("frozen: anchor after leaseMs → pos unchanged (elapsed clamps to 0)",
  frozenPlayback(publishedAfterLease, LEASE, CLEAR_AT).pos, 50_000);

// Already paused → position is exactly what was published.
const paused: PlaybackState = { ...live, playing: false, pos: 12_345 };
eq("frozen: paused owner keeps its exact position",
  frozenPlayback(paused, LEASE, CLEAR_AT).pos, 12_345);

// Rate feeds the extrapolation up to the heartbeat.
const fast: PlaybackState = { ...live, rate: 2000 };
eq("frozen: 2× rate doubles the run-up to the heartbeat", frozenPlayback(fast, LEASE, CLEAR_AT).pos, 50_000);

// Never past the end of the track.
const nearEnd: PlaybackState = { ...live, pos: 175_000 };
eq("frozen: clamps to dur", frozenPlayback(nearEnd, LEASE, CLEAR_AT).pos, 180_000);

// Empty session (no track) freezes harmlessly.
const empty: PlaybackState = { playing: false, pos: 0, anchor: 0, rate: 1000, dur: 0, rev: 0 };
eq("frozen: empty playback stays empty", frozenPlayback(empty, 0, CLEAR_AT).pos, 0);

// After the clear the session must read idle to every predicate that gates
// queue-adds / command routing, and the frozen state must be PAUSED so an
// auto-takeover from any transport press does startPaused = !playing = true
// for "pause"/"seek", and resumes from the frozen spot for "play".
const cleared = session({ ownerDeviceID: "", leaseMs: CLEAR_AT, playback: frozen });
eq("cleared session: idle", sessionIdle(cleared, CLEAR_AT + 1), true);
eq("cleared session: no live remote owner", liveRemoteOwner(cleared, CLEAR_AT + 1), false);
eq("cleared session: takeover continuity lands on the frozen position",
  positionAt(cleared.playback, CLEAR_AT + 30_000), 40_000);

// ── S3: seatClearedUnderOwner ─────────────────────────────────────────────
// Local state: we are owner at epoch 7.
const MY_EPOCH = 7;

eq("cleared: same epoch, empty seat → cleared under us",
  seatClearedUnderOwner(session({ epoch: 7, ownerDeviceID: "" }), MY_EPOCH), true);
eq("not cleared: same epoch, we hold the seat (normal snapshot)",
  seatClearedUnderOwner(session({ epoch: 7, ownerDeviceID: DEVICE_ID }), MY_EPOCH), false);
eq("not cleared: device id compare is case-insensitive",
  seatClearedUnderOwner(session({ epoch: 7, ownerDeviceID: DEVICE_ID.toLowerCase() }), MY_EPOCH), false);
eq("not cleared (taken): epoch bumped by a takeover — the epoch check handles that path",
  seatClearedUnderOwner(session({ epoch: 8, ownerDeviceID: "OTHER" }), MY_EPOCH), false);
eq("not cleared: a PRE-takeover snapshot (older epoch, other owner) must never demote a fresh owner",
  seatClearedUnderOwner(session({ epoch: 6, ownerDeviceID: "OTHER" }), MY_EPOCH), false);
eq("not cleared: pre-takeover idle snapshot at the older epoch",
  seatClearedUnderOwner(session({ epoch: 6, ownerDeviceID: "" }), MY_EPOCH), false);
eq("not cleared: same epoch but ANOTHER device in the seat (unreachable today) — never 'keep playing'",
  seatClearedUnderOwner(session({ epoch: 7, ownerDeviceID: "OTHER" }), MY_EPOCH), false);

// The engine's decision on top of the gate: reclaim only while audio is
// actually playing here; otherwise stay a follower with the audio untouched.
const reclaimDecision = (cleared: boolean, localPlaying: boolean): "reclaim" | "follow" | "none" =>
  !cleared ? "none" : localPlaying ? "reclaim" : "follow";
eq("engine: cleared + still playing → reclaim (never pause the music the user is hearing)",
  reclaimDecision(true, true), "reclaim");
eq("engine: cleared + paused → drop to follower silently",
  reclaimDecision(true, false), "follow");
eq("engine: not cleared → nothing", reclaimDecision(false, true), "none");

// The lease expiry the peers apply before they clear is unchanged.
eq("F3 precondition: clear only after LEASE_TTL_MS",
  liveRemoteOwner(session({ leaseMs: 100_000 }), 100_000 + LEASE_TTL_MS + 1), false);

console.log(`syncAudit5-seat: ${n}/${n} PASS`);
