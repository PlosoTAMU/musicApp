// Phase A logic gate — queue-based playlist semantics (audit-2 items 1–3):
// bulk append order, inject-front dedupe, and the idle-start guard.
import { rebase } from "../src/queueSync";
import { sessionIdle, SessionState, TrackRef } from "../src/protocol";

let n = 0;
function eq(name: string, got: unknown, want: unknown) {
  n++;
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) throw new Error(`${name}: got ${g}, want ${w}`);
}

const ref = (id: string): TrackRef => ({ id, name: id, folder: "F" });
const ids = (q: TrackRef[] | null) => q?.map(t => t.id) ?? null;

// ── append: bulk enqueue keeps order, after existing rows ──────────────────
eq("append order", ids(rebase({ kind: "append", refs: [ref("C"), ref("D")] },
  [ref("A"), ref("B")])), ["A", "B", "C", "D"]);
eq("append to empty", ids(rebase({ kind: "append", refs: [ref("A")] }, [])), ["A"]);
eq("append nothing is a no-op", rebase({ kind: "append", refs: [] }, [ref("A")]), null);

// ── injectFront: remove the set wherever it sits, plant refs at the head ───
// First tap queued P1..P3 behind X/Y; second tap plays P1 now and the rest
// (P2, P3) land at the front — X and Y stay, order preserved.
eq("injectFront dedupe + order",
  ids(rebase({ kind: "injectFront", refs: [ref("P2"), ref("P3")],
    removeIds: ["P1", "P2", "P3"] },
    [ref("X"), ref("P1"), ref("P2"), ref("P3"), ref("Y")])),
  ["P2", "P3", "X", "Y"]);
eq("injectFront id match is case-insensitive",
  ids(rebase({ kind: "injectFront", refs: [ref("b")], removeIds: ["a", "b"] },
    [ref("A"), ref("B"), ref("C")])),
  ["b", "C"]);
eq("injectFront into empty queue",
  ids(rebase({ kind: "injectFront", refs: [ref("P2")], removeIds: ["P1", "P2"] }, [])),
  ["P2"]);
eq("injectFront single-track playlist (no remainder)",
  ids(rebase({ kind: "injectFront", refs: [], removeIds: ["P1"] },
    [ref("P1"), ref("X")])),
  ["X"]);

// ── regression: existing ops unchanged ─────────────────────────────────────
eq("insert afterId=null still prepends",
  ids(rebase({ kind: "insert", ref: ref("N"), afterId: null }, [ref("A")])), ["N", "A"]);
eq("consumeHead CAS still guards",
  rebase({ kind: "consumeHead", expected: "B" }, [ref("A"), ref("B")]), null);

// ── sessionIdle: the idle-start guard ──────────────────────────────────────
const session = (owner: string, track?: TrackRef): SessionState => ({
  epoch: 1, ownerDeviceID: owner, leaseMs: 0,
  playback: { track, playing: false, pos: 0, anchor: 0, rate: 1000, dur: 0, rev: 0 },
  queue: [], queueVersion: 0, updatedBy: "T",
});
eq("no session → idle", sessionIdle(undefined), true);
eq("no owner → idle", sessionIdle(session("")), true);
eq("owner but no track (drained) → idle", sessionIdle(session("DEV")), true);
eq("owner with a track (even paused) → NOT idle",
  sessionIdle(session("DEV", ref("A"))), false);

console.log(`phaseA-queue: ${n}/${n} PASS`);
