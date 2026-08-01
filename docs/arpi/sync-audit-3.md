# Sync Audit 3 — iOS ↔ desktop reconciliation, connection-order & freeze

Run under ARPI on 2026-07-22 after the user reported: "iPhone will simply
freeze" during syncing, and "no matter how the phone and laptop connect
to each other, order or otherwise, everything works as expected."

Scope: every path in `musicApp/Sync/*.swift` and `desktop/src/{coordinator,
queueSync,commandBus,serverClock,settingsSync}.ts`, plus their observers
in `AudioPlayerManager.swift`, `PlaybackSyncEngine.swift`, and `engine.ts`.
Environment constraint (2026-07-14, still current): no display server on
this dev box, so all findings are static + logic-gated; GUI verification
is a per-item smoke checklist for the user's machine.

Logic gate: `desktop/tests/syncAudit-connection.test.ts` (23/23 PASS)
exercises sessionIdle, leaseExpired, handoffActive, positionAt, and
rebase across the connection-order scenarios documented below. The wire
contract is shared with iOS byte-for-byte; a break there breaks both
ends. Existing gates (phaseA-queue 13/13, phaseC-downloads 18/18) still
pass — nothing in the wire types was touched.

## Method

1. Read every file in `musicApp/Sync/` (12 files, 2131 lines) and every
   sync module on desktop (10 files, 1249 lines).
2. Traced every observer/publisher chain that fires during a snapshot
   and every state transition (`role`, `player.$isPlaying`, `player.$queue`,
   `player.$playbackSpeed`) to look for reentrancy, echo loops, and
   MainActor-blocking work.
3. Cross-referenced against the two prior audits (`desktop-parity-findings.md`,
   `desktop-parity-audit-2.md`) — this audit is orthogonal (sync
   correctness, not feature parity) so overlaps are small.

## Connection-order matrix — the questions this audit is answering

The user framed it as "no matter how they connect, it should work." The
paths any device can take, from cold:

| # | Order                                                     | Expected                             | Actual (see findings) |
|---|-----------------------------------------------------------|--------------------------------------|-----------------------|
| 1 | Fresh install, no other device connected                  | Idle singleton created, follower     | ✅                    |
| 2 | Fresh install, other device already owner+playing         | Follower shows mirror, no auto-play  | ✅                    |
| 3 | Both devices connect within the same second               | Race on setData — identical idle doc | ✅                    |
| 4 | Device A owner, then A killed mid-play                    | A relaunches as follower             | **F1, F2**            |
| 5 | Device A owner, killed. Device B never took over.         | Session doc has A as owner, lease expired | **F3**            |
| 6 | iOS follower, user taps play locally                      | Implicit takeover, epoch bumped      | ✅ (F4: race window)  |
| 7 | Owner offline mid-song, other device connects             | Follower sees mirror from cache      | ✅ (F5: stale mirror) |
| 8 | Bluetooth handoff (headphones move A→B)                   | B auto-takeover, forcePlay=true      | ✅                    |
| 9 | Simultaneous first-launch on two devices with same secret | Both signIn or one createUser wins   | **F6**                |
| 10| One device offline, edits queue, reconnects               | Replay unless queueVersion moved     | ✅                    |
| 11| Owner writes speed/bass/reverb, follower on OTHER track   | Follower's OTHER track gets values   | **F7 (critical)**     |
| 12| Rapid remote snapshots (settings + queue + playback)      | Serialize on MainActor               | **F8 (freeze)**       |

## Findings, ranked by user-impact severity

### F1 — `isRemoteControlled` mislabels zombie SELF-owner as remote-controlled *(HIGH)*

**File:** `musicApp/Sync/PlaybackSyncEngine.swift:44-47`

```swift
var isRemoteControlled: Bool {
    coordinator.role == .follower &&
    !(coordinator.remote?.ownerDeviceID.isEmpty ?? true)
}
```

**Failure scenario:** iPhone is owner, force-quit (task-killed, low
memory) without a clean detach. Session doc still shows
`ownerDeviceID = SELF_DEVICE_ID`. On relaunch, `attach()` sets
`role = .follower`. Snapshot arrives with SELF as owner. UI computes
`isRemoteControlled = true` → `ContentView.swift:134` shows the mini
player only if there's a mirror or currentTrack; and every "Play Here"
banner/route in `NowPlayingView` treats the follower as being controlled
by a "remote" device that is actually itself. User cannot resume the
saved session by any UI affordance except tapping a library row (which
does an implicit takeover).

**Fix:** guard by `remote?.ownerDeviceID != SyncDevice.id`. Same fix on
desktop `engine.ts` if there's an equivalent computed elsewhere (there
isn't today — desktop UI uses `coord.role === "follower"` directly).

### F2 — Zombie-owner never auto-demotes; requires user action to reclaim playback *(HIGH)*

**File:** `musicApp/Sync/SessionCoordinator.swift:63-74` (`attach`)

The self-ownership check in F1 has a companion missing action: after a
crash/kill, the coordinator should reclaim (or demote) its own zombie
ownership at `attach` time. Today it doesn't — role always begins
`.follower`, and no takeOver is issued until the user taps play. Same
device is both the recorded owner AND behaves like a follower.

**Fix:** at the end of `attach`, if the snapshot's `ownerDeviceID ==
SyncDevice.id`, either:
  (a) issue a takeOver() to bump the epoch and re-establish authority
      (owner-continuity path — desirable for "resume where I left off"), OR
  (b) clear ownerDeviceID via a fenced compare-and-set (release the seat).

(a) is the parity-preserving choice — iOS was the owner, iOS remains the
owner. Add a small note in NOTES.md: "Owner-continuity on relaunch
means the epoch bumps once per app start, which is safe (epoch is
per-owner change; monotonic, and deposes any accidental doppelganger)."

### F3 — No lease-expired auto-demote; followers stare at a mirror of a dead owner *(MED)*

**File:** `musicApp/Sync/SessionCoordinator.swift:135-154` (`handleSnapshot`),
`desktop/src/coordinator.ts:104-129` (twin `listen`).

`leaseExpired` exists in both wire types and is checked in
`ContentView.swift:1016` to decide whether to show the "Play Here"
button in the Now Playing rail. But **no code path actually clears
ownerDeviceID** when a lease expires. If the owner device dies without
detaching (crash, low battery, killed by iOS), the session doc stays
with `ownerDeviceID = dead-device`, `leaseMs = last-heartbeat` forever.
Followers still see a mirror, but there is no owner keeping it alive.
Any queue edit still applies (queue is shared), but "Play Here" is the
only recovery route.

**Failure scenario:** iPhone owner crashes. Desktop is follower. Desktop
user does not know the iPhone is dead; the desktop mini-bar shows
"Playing on iPhone" (or equivalent mirror UI) indefinitely, or at least
until the user notices the lease is expired.

**Fix:** on any follower, if the incoming snapshot has
`state.leaseExpired`, surface a UI banner ("Playback owner is
unreachable — resume here?") and offer a fenced takeOver. Alternatively,
auto-clear the seat: any follower may do a fenced `ownerDeviceID = ""`
write when it sees `leaseExpired && !isFromCache`. First follower to
land the write wins; the rest see the cleared state as an idle session.
Desktop can do this from `engine.ts` on the online→snapshot path; iOS
from `PlaybackSyncEngine.handleRemote`.

### F4 — Implicit takeover race can cause 500 ms–2 s of double audio *(MED — behavior gap)*

**File:** `musicApp/Sync/PlaybackSyncEngine.swift:155-174` +
`AudioPlayerManager.swift:660-832` (`play`).

When a follower taps a library row, `AudioPlayerManager.play(track)`
starts audio LOCALLY *before* the `player.$isPlaying` observer sees the
flip and dispatches `claimSessionForLocalPlayback`. That Task runs a
fenced Firestore transaction to bump epoch. Between "play" and "txn
ack" (0.5–2 s on cellular), BOTH devices are producing audio.

**Fix (partial — the pattern):** don't touch the local audio node until
the takeover transaction has returned. Split `play(track)` into a
"prepare-but-don't-start" call (opens the file, wires the graph,
preloads the buffer) and a "kick" call that just does `player.play()`.
The takeover Task fires the kick on success. On failure, the prepared
state is torn down — the tap becomes a no-op with an error toast.

This is a bigger refactor than the others and may not be worth it if
the user tolerates the brief overlap; classify as MED and defer unless
users complain about it specifically.

### F5 — Follower shows mirror from cache but reports itself online *(LOW)*

**File:** `musicApp/Sync/SessionCoordinator.swift:135-154`.

When a follower's Firestore listener returns from cache
(`snap.metadata.isFromCache == true`), we set `isOnline = false` — good.
But the cached state's `remote?.updatedBy` may still be some other
device from a previous run, and `state.updatedBy != SyncDevice.id`
passes, so `onRemoteState` fires with **stale data**. The UI may show
"paused at 0:15 on iPhone" from three hours ago until the server
snapshot arrives.

**Fix:** guard `onRemoteState` on `isOnline`, or paint a "reconnecting"
banner while `!isOnline`. Both are cheap.

### F6 — First-boot race on secret: signIn/createUser interleaving *(LOW)*

**File:** `musicApp/Sync/SyncSessionManager.swift:77-97`,
`desktop/src/firebase.ts:67-83` (twin).

Both devices launch the app with the same never-used-before secret.
Device A: signIn fails (user not found) → createUser succeeds. Device B
(within the sub-second window): signIn fails (user not yet propagated
across Firebase Auth's caches, sometimes) → createUser fails with
`auth/email-already-in-use`. iOS throws `SyncError.corrupt` — surfaces
as "Could not connect". User must retry.

**Fix:** on `email-already-in-use` in the createUser fallback, retry
signIn once (short delay, e.g. 500 ms). Symmetric on desktop where
`authError` already maps this to a user-facing message.

### F7 — SettingsSync overwrites the follower's current track's saved settings *(HIGH — silent data loss)*

**File:** `musicApp/Sync/SettingsSync.swift:79-97` + didSet chain in
`AudioPlayerManager.swift:40-73`.

`applyRemote` unconditionally writes `player.playbackSpeed`,
`player.bassBoost`, `player.reverbAmount` when a remote settings doc
arrives. Each assignment fires didSet → `saveCurrentTrackSettings()`
which persists the current track's per-track memory to disk.

**Failure scenario:**
1. Device A (owner) plays *Track α* with speed=1.5, bass=+5.
2. SettingsSync pushes {speed:1.5, bass:5, reverb:0}.
3. Device B is a follower and is *browsing* — no track playing, or
   preparing *Track β* which has its own saved settings speed=2.0.
4. Snap arrives on B → applyRemote → `player.playbackSpeed = 1.5`.
5. didSet → `saveCurrentTrackSettings()`. If Track β is
   `currentTrack`, β's TrackSettings on disk is now speed=1.5.
6. Track α's settings on device B (if it has one) are unchanged, but β
   is now corrupted with A's α-derived values.

Comment in `SettingsSync.swift:17-20` acknowledges this is intentional:
"it syncs 'whichever effective settings are currently audible'". But
the didSet path saves those into whichever track is *currently loaded*
on the follower — which may not be what's playing on the owner. The
persistence step is unwanted here.

**Fix:** during `applyRemote`, suppress the per-track save. Options:
  (a) set an `isApplyingRemoteSettings = true` flag; `saveCurrentTrackSettings`
      early-returns while set.
  (b) apply the values without going through @Published: mutate the
      underlying stored properties directly and manually call the
      `applyX()` methods to update the audio graph.
  (a) is smaller and matches the pattern in
  `PlaybackSyncEngine.swift:57-60` (`lastAppliedQueueIDs`).

### F8 — MainActor stall on remote snapshots: O(N × M) library resolution *(HIGH — the likely freeze)*

**Files:**
  - `musicApp/Sync/PlaybackSyncEngine.swift:108-122` (`handleRemote`)
  - `musicApp/Sync/SyncModels.swift:116-123` (`LibraryTrackResolver.resolve`)
  - `musicApp/ContentView.swift:34-45` (library closure)

The library closure at `ContentView.swift:36-44` maps
`downloads.downloads` into fresh `Track` structs on **every call**:
```swift
library: {
    downloads.downloads.map {
        Track(id: $0.id, name: $0.name, url: $0.url, ...)
    }
}
```

`LibraryTrackResolver.resolve` invokes `library()` once per
`resolve()` call. In `handleRemote`, we call it:
  - once for `mirrorTrack`
  - once per queue item for `resolvedPairs`

For a 100-track queue against a 500-track library, that's ~101 calls
returning ~500-element arrays each = 50,500 `Track` constructions
(each opens a `URL`, computes a `folderName`, etc.), followed by
50,500 linear scans through those arrays for `first(where: id ==)` +
fallbacks. **Every remote snapshot** re-does this work on MainActor.

With `includeMetadataChanges: true` on the session listener, EVERY
local write fires a snapshot. `SettingsSync` + `QueueSync` +
`PlaybackSyncEngine` publishes generate 5–15 snapshots per second
during active edits. That is where the iPhone freezes.

**Fix:** two parts.

1. **Cache the library snapshot on the resolver.** Take the array
   once per resolve() call at minimum; ideally, take it once per
   *snapshot* — pass the current library as a parameter into
   `handleRemote`, not a closure that regenerates it. On iOS, the
   easiest patch is:
   ```swift
   func resolve(_ ref: TrackRef) -> Track? {
       // Existing per-call rebuild — replace by cached
   }
   ```
   Change `LibraryTrackResolver` to hold a `let library: [Track]`
   snapshot and be recreated when downloads change.

2. **Build a keyed index** — a `[UUID: Track]` (and `[String: Track]`
   for yt id) once per library update. Resolve becomes O(1) per queue
   item. For 100 items, 100 dictionary lookups replaces 50k linear
   scans. Effectively removes this stall path from MainActor entirely.

The MainThreadWatchdog in `MainThreadWatchdog.swift:44` triggers on
>100 ms stalls. That threshold will fire on any handleRemote that hits
this path with a queue >20 items and library >200 tracks. Cross-checked
against `PerformanceMonitor.shared.recordStateChange` on `currentTrack`
(`AudioPlayerManager.swift:24-26`) — the same monitor should be
recording these stalls, and the user can enable DEBUG to confirm on
device.

### F9 — LibraryReplicator `pumpDownloads` recursion + O(N²) dedupe scan *(MED — same stall class)*

**File:** `musicApp/Sync/LibraryReplicator.swift:131-146`.

`pumpDownloads` recurses synchronously when it skips a queued item
(`hasLocally`, deleted, no-yt). Each recursion does another linear
`meta.values.first(where:)` (O(all cloud meta)) and another
`localDownloads.contains { normalize == normalize }` (O(local × string
normalize)). At first-sync on a 500-track library where every doc is
already local, that's ~500 recursive calls each doing a 500-item scan
= 250k operations, all on MainActor.

**Fix:**
  - Replace `meta.values.first(where:)` with a secondary index
    `[yt: docId]` maintained inside `handleSnapshot`.
  - Convert `pumpDownloads` from recursion to a `while` loop.
  - `localDownloads` name-index for the normalized-name fallback.

Same shape of fix as F8. Both are on the same critical path when the
user connects a fresh device against an already-populated home library.

### F10 — `SessionCoordinator.postHandoff` writes without fencing *(LOW)*

**File:** `musicApp/Sync/SessionCoordinator.swift:238-244`.

`postHandoff` guards on client-side `role.isOwner` but writes with a
plain `updateData`. A demoted (fenced) owner that has not yet processed
its snapshot could post a handoff beacon that overwrites the new
owner's state. `updatedBy` protects `onRemoteState` filtering but the
`handoff` field itself is overwritten.

**Fix:** either wrap `postHandoff` in a fenced transaction (matches
`renewLease`), OR accept the write and note that the impact is a
60 s stale beacon that self-expires. Given the comment ("plain
non-transactional write on purpose: fires in the chaos of a route
change and must be fast") — leave as is but document. Recorded here
for completeness, not scheduled for action.

### F11 — `handleLocalQueueChange` silently drops user edits during rapid track changes *(LOW)*

**File:** `musicApp/Sync/PlaybackSyncEngine.swift:235-259`.

`suppressConsumePublish` is set by `handleLocalTrackChange` and
reset by the queue observer. Because `player.$queue` uses
`.debounce(300ms)`, a queue mutation during the debounce window is
coalesced with the `suppress`-triggered fire. When the debounce
finally fires, `suppress=true` is checked *first*, so the user's
manual edit is dropped.

**Failure scenario:** track auto-advances (fires `consumeHead`, sets
`suppress=true`). Within 300 ms the user drags a queue item to
reorder. Debounce fires → `suppress=true` → return. The reorder is
lost from the shared queue (though the local UI reflects it until
the next remote snapshot overwrites).

**Fix:** compare the observed queue to the pre-consume queue instead
of a flag. If they differ by more than the head being popped, the
delta is user intent — publish `.replaceAll` for it. Simpler: pop the
suppression only if the observed queue equals `cur_remote.queue`
after the CAS (no other changes).

### F12 — CommandBus doesn't dedupe or idempotency-check *(LOW)*

**File:** `musicApp/Sync/CommandBus.swift:59-83`.

Two rapid `pause` taps from a follower create two docs. Both are
delivered to the owner. Owner applies pause twice — harmless (idempotent
transport), but a rapid pause→play→pause could interleave with the
owner's own local mutations, and the second pause overrides a resume.

**Fix:** for `pause`/`play` (idempotent), no-op. For `next`/`prev`
(non-idempotent), add a client-side debounce on the follower's
`route()` at the CommandBus.send site. 200 ms is enough.

## Prioritized fix plan (ARPI phased)

Every phase ships static (`tsc --noEmit`) + logic-gate green + a smoke
checklist for the user (added to `docs/arpi/smoke-test.md`). Phases are
independent and each is a pushable commit.

**Phase 1 — The freeze (F8 + F9):** biggest user-facing win. Rewrite
`LibraryTrackResolver` around a keyed index rebuilt only on library
change; refactor `LibraryReplicator.pumpDownloads` into a while loop
with `[yt: docId]` and normalized-name secondary indexes. Add a Swift
XCTest (iOS side has no logic-test harness today — write a first one
for `LibraryTrackResolver.resolve`, or extend a new
`desktop/tests/syncAudit-*.test.ts` for the parallel desktop resolver
in `player.ts`).

**Phase 2 — Settings sync corruption (F7):** add `isApplyingRemoteSettings`
flag on iOS `SettingsSync`; `saveCurrentTrackSettings` in
`AudioPlayerManager` early-returns while set. Verify via a
`saveTrackSettingsToDisk`-mocked unit test if a test target exists;
otherwise smoke on device (checklist: play α with speed=1.5 on desktop,
verify β on iPhone keeps its own speed after α's sync-pushed values
land).

**Phase 3 — Zombie owner + auto-demote (F1 + F2 + F3):**
  - F1: fix `isRemoteControlled` self-check.
  - F2: at end of `attach`, if snapshot's ownerDeviceID == SELF, call
    `takeOver()` to bump epoch (owner continuity).
  - F3: on any follower with `leaseExpired && isOnline`, offer a
    "Take Over" affordance in the mini bar (or auto-clear the seat via
    fenced `ownerDeviceID = ""` write from the first-to-notice follower).

**Phase 4 — Rapid connection races (F4 + F6 + F11 + F12):**
  - F4: prepare-then-kick refactor of `AudioPlayerManager.play`.
  - F6: retry signIn once on `email-already-in-use`.
  - F11: fix suppress-drop bug in queue observer.
  - F12: debounce command sends on follower.

**Phase 5 — Cosmetics + documentation (F5 + F10):**
  - F5: "Reconnecting" banner while `!isOnline`.
  - F10: comment `postHandoff` as intentional non-fenced; no code change.

## Verification strategy

Environment reminder: no display server here; every phase gates statically.

- **Static gate:** `xcodebuild -project musicApp.xcodeproj -scheme
  musicApp -destination generic/platform=iOS build` for iOS, `npx tsc
  --noEmit && npm run bundle` for desktop.
- **Logic gate:** `desktop/tests/*.test.ts` via `npm run test:logic`.
  Phase 1 requires adding an equivalent test file for the resolver
  (`syncAudit-resolver.test.ts`) that verifies the keyed-lookup
  correctness against the linear-scan fallback chain.
- **Live Firestore gate:** where feasible, each phase's smoke checklist
  includes a "read the doc back after action X" step to confirm the
  wire payload matches what the code intends to write.
- **Freeze gate (F8):** enable DEBUG so `MainThreadWatchdog` prints
  stall counts. Run a scenario with `library ≥ 200`, `queue ≥ 30`, and
  a burst of remote writes (settings slider drag on the other device).
  Watchdog count MUST not grow during the burst.

## Continuity notes

- All wire-contract types unchanged. This audit does not require a
  schema migration.
- Prior audits' findings and phase results (P1–P5, audit-2 A–E) are
  code-complete on `main`; this audit is on top of that state.
- `NOTES.md` should get a `DECISIONS` entry per phase as it merges,
  keeping the state file the canonical resume point.
