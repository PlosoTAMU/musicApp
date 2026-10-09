// Sync audit 6 — invariants shared by both ends (protocol.ts / libraryMeta.ts
// are the twins of SyncModels.swift / LibraryReplicator.swift). Pins:
//   nameKey          the cross-device name comparison (SyncNames.key)
//   canonicalByYt    which doc speaks for a yt when duplicates exist
//   transferPending / outgoingTransfer   the "play on other device" beacon
//   knownDurationMs  follower duration fallback after a dur-0 publish
import {
  SessionState, PlaybackState, TrackMeta, DEVICE_ID, HANDOFF_WINDOW_MS,
  nameKey, transferPending, outgoingTransfer, handoffActive, knownDurationMs,
} from "../src/protocol";
import { canonicalByYt, duplicateDocIds, metaAtMs, tombstoneByYt } from "../src/libraryMeta";
import { resolve, LocalTrack } from "../src/player";

let n = 0;
function eq(name: string, got: unknown, want: unknown) {
  n++;
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) throw new Error(`${name}: got ${g}, want ${w}`);
}

// ── nameKey: the exact cases that used to miss and cause a re-download ────
// (Swift SyncNames.key must produce byte-identical output for these inputs.)
eq("nameKey: Windows-sanitized '_' vs the original '?'", nameKey("What_ Song"), nameKey("What? Song"));
eq("nameKey: iOS neutralizeName turned '_' into a space", nameKey("Song_Name"), nameKey("Song Name"));
eq("nameKey: iOS deleted '*', desktop wrote '_' for it", nameKey("A*B"), nameKey("A_B"));
eq("nameKey: iOS deleted '#' and '~'", nameKey("Track #1 ~ mix"), nameKey("Track 1  mix"));
eq("nameKey: case + trailing spaces", nameKey("  Hello World "), "helloworld");
eq("nameKey: unicode letters survive", nameKey("Café Déjà Vu"), "cafédéjàvu");
eq("nameKey: digits survive", nameKey("Song 2 (Remix)"), "song2remix");
eq("nameKey: nothing left ⇒ empty (callers must not match on it)", nameKey("???"), "");

// resolve's last rung uses nameKey but must not match on an empty key.
const lib: LocalTrack[] = [
  { id: "A", name: "???", folder: "F", path: "/a" },
  { id: "B", name: "Song_Name", folder: "F", path: "/b" },
];
eq("resolve: neutralized name reaches the on-disk underscore name",
  resolve({ id: "X", name: "Song Name", folder: "G" }, lib)?.id, "B");
eq("resolve: empty key never matches another empty-key track",
  resolve({ id: "Y", name: "!!!", folder: "G" }, lib)?.id, undefined);

// ── canonicalByYt ─────────────────────────────────────────────────────────
const ts = (ms: number) => ({ toMillis: () => ms });
const meta = (yt: string | undefined, extra: Partial<TrackMeta> = {}): TrackMeta =>
  ({ name: "n", folder: "", ext: "m4a", by: "D", ...(yt ? { yt } : {}), ...extra });

eq("metaAtMs: absent ⇒ 0", metaAtMs(meta("a")), 0);
eq("metaAtMs: pending server timestamp (null) ⇒ 0", metaAtMs(meta("a", { metaAt: null })), 0);
eq("metaAtMs: Timestamp ⇒ millis", metaAtMs(meta("a", { metaAt: ts(5) })), 5);

const docs: [string, TrackMeta][] = [
  ["PHONE-UUID", meta("yt1", { metaAt: ts(100) })],     // older edit
  ["DESK-PATHID", meta("yt1", { metaAt: ts(200) })],    // newer edit → canonical
  ["TOMB", meta("yt1", { deleted: true, metaAt: ts(999) })], // tombstones never win
  ["ONLY", meta("yt2")],
  ["NOYT", meta(undefined)],
  ["DEAD", meta("yt3", { deleted: true })],
];
const canon = canonicalByYt(docs);
eq("canonical: most recently edited live doc wins", canon.get("yt1"), "DESK-PATHID");
eq("canonical: a lone live doc is canonical", canon.get("yt2"), "ONLY");
eq("canonical: a yt with only tombstones is ABSENT (⇒ deletion applies)", canon.has("yt3"), false);
eq("canonical: yt-less docs are ignored", canon.size, 2);
eq("duplicates: the older live twin, never tombstones or yt-less docs",
  duplicateDocIds(docs, canon), ["PHONE-UUID"]);

// Tie on metaAt → smaller docId, on BOTH ends (Swift compares Strings the same way).
const tie = canonicalByYt([["B", meta("y", { metaAt: ts(1) })], ["A", meta("y", { metaAt: ts(1) })]]);
eq("canonical: tie breaks to the smaller docId", tie.get("y"), "A");
const legacy = canonicalByYt([["Z", meta("y")], ["M", meta("y")]]);
eq("canonical: two legacy docs (no metaAt) tie → smaller docId", legacy.get("y"), "M");

const tombs: [string, TrackMeta][] = [
  ["LIVE", meta("yt-del", { metaAt: ts(50) })],
  ["OLD-TOMB", meta("yt-del", { deleted: true, metaAt: ts(100) })],
  ["NEW-TOMB", meta("yt-del", { deleted: true, metaAt: ts(200) })],
  ["TIE-B", meta("yt-tie", { deleted: true, metaAt: ts(1) })],
  ["TIE-A", meta("yt-tie", { deleted: true, metaAt: ts(1) })],
];
const tomb = tombstoneByYt(tombs);
eq("tombstoneByYt: newest deleted doc wins even when a live doc also exists",
  tomb.get("yt-del"), "NEW-TOMB");
eq("tombstoneByYt: tie breaks to smaller docId", tomb.get("yt-tie"), "TIE-A");
eq("tombstoneByYt: live-only yt is absent", tomb.has("yt2"), false);

// ── transfer beacon ───────────────────────────────────────────────────────
const NOW = 1_000_000;
const session = (opts: Partial<SessionState> = {}): SessionState => ({
  epoch: 3, ownerDeviceID: "OTHER", leaseMs: NOW,
  playback: { playing: true, pos: 0, anchor: NOW, rate: 1000, dur: 0, rev: 0 },
  queue: [], queueVersion: 0, updatedBy: "OTHER",
  ...opts,
});

const bt = session({ handoff: { by: "OTHER", atMs: NOW - 1000 } });
eq("Bluetooth beacon (no transfer flag) still counts as handoffActive", handoffActive(bt, NOW), true);
eq("…but is NOT a transfer request", transferPending(bt, NOW), false);

const tr = session({ handoff: { by: "OTHER", atMs: NOW - 1000, transfer: true } });
eq("transfer beacon from another device ⇒ pending", transferPending(tr, NOW), true);
eq("transfer beacon is not ours", outgoingTransfer(tr, NOW), false);
eq("transfer beacon expires with the handoff window",
  transferPending(tr, NOW + HANDOFF_WINDOW_MS), false);

const mine = session({ ownerDeviceID: DEVICE_ID,
  handoff: { by: DEVICE_ID, atMs: NOW - 1000, transfer: true } });
eq("our own transfer beacon is never 'pending' for us", transferPending(mine, NOW), false);
eq("our own transfer beacon is 'outgoing' until claimed", outgoingTransfer(mine, NOW), true);
eq("outgoing: claimed (handoff deleted) ⇒ false", outgoingTransfer(session(), NOW), false);
eq("outgoing: undefined session ⇒ false", outgoingTransfer(undefined, NOW), false);
eq("outgoing: our Bluetooth beacon is not a transfer",
  outgoingTransfer(session({ handoff: { by: DEVICE_ID, atMs: NOW } }), NOW), false);

// ── knownDurationMs ───────────────────────────────────────────────────────
const known = new Map<string, number>([["abc", 180_000]]);
const pb = (dur: number, id = "ABC"): PlaybackState =>
  ({ track: { id, name: "t", folder: "f" }, playing: true, pos: 0, anchor: NOW, rate: 1000, dur, rev: 0 });
eq("dur > 0 is used as published", knownDurationMs(pb(200_000), known), 200_000);
eq("dur 0 falls back to the last known length of the SAME track (id case-insensitive)",
  knownDurationMs(pb(0), known), 180_000);
eq("dur 0 for an unknown track stays 0", knownDurationMs(pb(0, "zzz"), known), 0);
eq("no playback ⇒ 0", knownDurationMs(undefined, known), 0);
eq("no track ⇒ 0", knownDurationMs({ ...pb(0), track: undefined }, known), 0);

console.log(`audit6-sync: ${n} assertions passed`);
