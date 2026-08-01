# Sync audit 4 — iOS ↔ desktop consistency sweep

2026-08-01. Full walkthrough of the sync surface on `main` after merging
`arpi/audit-3`: session/ownership, command bus, queue, library replication,
playlists, settings, server clock, Bluetooth handoff.

**24 findings.** 7 blockers (user-visible breakage or data loss), 10 medium,
7 low/parity. All fixed. Severity prefixes match the commit messages.

Environment constraint (unchanged from audit-3): this box has no Swift
toolchain and no display server. The TS half is gated by `tsc --noEmit`,
`npm run bundle` and `npm run test:logic`; the Swift half is verified by
line-by-line review against its TS twin, with the shared algorithms pinned by
executable specs in `desktop/tests/`. GUI verification is the user's pass —
see `smoke-test.md`.

---

## The merge

`main` and `arpi/audit-3` had diverged (5 commits each side, 4 files / 8
conflicting hunks) and in two places fixed the *same* bug in *opposite*
directions. Resolutions:

- **Zombie self-owner — release, not reclaim.** main's `releaseStaleOwnership`
  wins; audit-3's F2 reclaim dropped. A reclaim publishes nothing, so the
  phantom `playing: true` with a dead anchor survives on every other device,
  and on desktop a coordinator-internal `takeOver()` bypasses
  `engine.becomeCommandTarget()` — the app would own a session it isn't
  listening to. Release composes with `reconcileLocalPlayback`, which claims
  the seat once local audio actually plays.
- **Echo policy — main's signature, audit-3's gate.** `onRemote(state, isEcho)`
  is kept (echoes must reach the mirror and the join-resync ping; filtering
  them caused "connect and now playing never loads"), with F5's `isOnline`
  gate added so cached frames don't paint hours-old state.

`didHandleInitialSnapshot` (both ends) and `LibraryReplicator.localDownloads`
became dead and were removed.

The merge also carried a **latent build break**: audit-3 used
`AuthErrorCode.emailAlreadyInUse.rawValue`, which does not compile against the
pinned Firebase 12.14.0 — the type became a struct in Firebase 10+, and the Int
lives on the nested `Code` enum.

---

## B — blockers

**B1. Zombie self-owner wedged the UI in remote-mode against itself.**
`isRemoteControlled` / `remoteActive` were true whenever role was follower and
`ownerDeviceID` was non-empty — including when it equalled SELF. The
stale-release latch was set *before* the transaction, so one transient failure
left the device permanently believing another device owned playback, with every
transport tap writing command docs nobody drains. Latch now closes only on a
committed write (or on FENCED, which proves the point is moot).

**B2. An expired-lease owner left both apps inert.** Nothing cleared the seat
when the owner died. iOS gated nothing on the lease, so taps were silent no-ops
forever; desktop gated only the optimistic mirror patch, and `next`/`prev` not
even that. `sessionIdle` ignored the lease too, so a queue-add on desktop parked
behind a track nobody would finish. Fixed with audit-3's F3 clear (both ends,
every online snapshot), a lease term in `sessionIdle`, a shared
`liveRemoteOwner` predicate, dropped commands when no live owner exists, and a
dead-owner affordance on iOS to match desktop's.

**B3. Desktop→iOS playlists arrived empty; the first iOS edit destroyed them.**
`PlaylistSync.applyRemote` kept only each entry's `id`, discarding the
`name`/`yt` the doc carries so entries can be resolved — the class docstring
promised a resolution chain the code never ran. Desktop ids are
sha1-of-absolute-path and match no iOS `Download.id`, so playlists rendered as a
name and a count with nothing in them. Any local edit then re-uploaded those
entries as `{id, name: ""}` with `yt` dropped, after which **desktop** couldn't
resolve them either. `PlaylistSync` now keeps the cloud `tracks` array verbatim,
resolves through the shared chain, and round-trips unresolved entries untouched.

**B4. iOS Bluetooth handoff could hijack a track it can't play.**
`takeOverHere` bumped the epoch *first*, so an unresolvable track deposed the
real owner, played nothing, and published `track: nil`. The Now Playing pill
guards this; `RouteHandoffMonitor` did not. Now refuses before the bump.

**B5. One unplayable track at the queue head jammed iOS forever.** Ghosts are
filtered out of `player.queue`, so `next()` popped the first *resolvable* track
while the CAS compared against the remote head — the ghost — and missed;
`mergeGhosts` then re-pinned it at index 0. New `consumeHeadRun` intent op
(both ends) pops the ghost run plus the started track in one all-or-nothing CAS.

**B6. Remote settings corrupted the local per-track effects memory.**
(audit-3 F7, arrived with the merge.) Each `didSet` calls
`saveCurrentTrackSettings()`, so applying another device's values wrote them
into whichever track was loaded here.

**B7. Consecutive ghosts got reversed on every edit.** Found while porting the
algorithm for B3. Both ghost-merge sites inserted each ghost at `anchor + 1`,
pushing the previously placed sibling right — so two unplayable tracks sitting
next to each other in the shared queue swapped places on every local queue edit.
Fixed with a per-anchor placement cursor, pinned by
`desktop/tests/syncAudit-ghostmerge.test.ts`.

---

## M — medium

| # | Finding |
|---|---|
| M7 | iOS resolver had 4 rungs to desktop's 5 — no normalized-name fallback, so any title with `? : / \ * " < > \|` resolved on desktop and ghosted on iOS. Added, verbatim twin of `player.ts`'s `norm`. |
| M8 | `handleSnapshot`'s "already queued?" check linear-scanned a queue that grows with the initial batch — O(n²) on MainActor, the same freeze shape F9 targeted. Membership Set added. |
| M9 | `uploadedIDs` was globally keyed, so switching homes on iOS never re-mirrored the library. Now per-uid with legacy adoption. `forgetHome` also left the library/playlist/settings listeners on the old uid; desktop's never signed out and kept the replicator shadow. |
| M10 | `effectsBypass` was outside the settings contract, so a bypassed device published values it wasn't hearing and the other device played them — contradicting `PlaybackState.rate`, which *is* bypass-adjusted. Added as an optional field. |
| M11 | Every iOS queue change published `replaceAll` (LWW), erasing a desktop insert that landed in the 300 ms debounce. New `QueueIntent` vocabulary → rebasable ops, matching desktop. |
| M12 | iOS retried `createUser` after *any* sign-in error and collapsed everything into "could not connect". Now mirrors desktop's error-code discrimination and message set. |
| M13 | iOS published `ghostQueue` and no view read it, so tracks the phone lacks vanished from Up Next. New "Not On This Device Yet" section. |
| M14 | Cached snapshots painted stale state (audit-3 F5, via the merge). |
| M15 | Follower double-tap skipped two tracks (audit-3 F12, via the merge). |
| M16 | Consume-echo suppression swallowed a real user edit (audit-3 F11, via the merge). |

## L — low / parity

| # | Finding |
|---|---|
| L17 | Clock resample cadence: desktop 60 s → 300 s, matching iOS's considered value. |
| L18 | Desktop `serverClock.prime()` swallowed every failure and connected with `offsetMs = 0`. Now throws, like Swift's always has. |
| L19 | Device-id comparison mixed `sameId` with strict `!==` in the fencing checks and `handoffActive`. Unified. |
| L20 | `engine.ts` ignored the `isEcho` flag, so the two ends disagreed about what an echo means. |
| L21 | `postHandoff`'s non-fenced write is deliberate (audit-3 F10) — rationale documented on both ends. No code change. |
| L22 | CommandBus purged the whole initial batch, eating a `playTrack` a follower sent in the same instant a takeover landed. Cutoff is now a timestamp. |
| L23 | iOS `next()` under loop seeked to 0 without resuming; desktop resumed. |

---

## Known residuals

- **All-ghost queue on iOS.** If *every* entry in the shared queue is
  unresolvable here, `next()` sees an empty local queue and stops without
  consuming anything, so the entries stay. Desktop drains them. Not fixed:
  distinguishing "advance that found nothing" from "playback stopped for any
  other reason" needs state the engine doesn't have, and the queue is only
  stale, not corrupted. The B5 fix covers every case where at least one entry
  is playable.
- **Multi-row queue drags** on iOS still publish `replaceAll` rather than a
  move intent — one drag, several anchors. Rare, and LWW is defensible for a
  bulk reorder.
- **`(name, folder)` never matches cross-platform**: iOS reports
  "YouTube Downloads", desktop reports the parent directory. Documented rather
  than changed — `yt` is the real cross-device key and folder authority is
  deliberately desktop's.

## Wire-contract changes

Only one, and it is additive: `bypass?: boolean` on
`users/{uid}/sync/settings`. Absent = pre-M10 writer, read as `false`, which is
exactly how those values were already being applied — old and new clients
interoperate.

Queue ops (`consumeHeadRun`, `removeMany`, `append`, `injectFront`) are
CLIENT-LOCAL intents, rebased inside the transaction and never serialized, so
extending that union does not touch the wire format.
