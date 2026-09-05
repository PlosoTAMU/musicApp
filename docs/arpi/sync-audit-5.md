# Sync audit 5 — "both apps open, control from either"

2026-09-05. Prompted by: "there are plenty of bugs with how the phone's music
syncs with the desktop — I should be able to have both apps up at once and
control playback from both seamlessly." Full re-read of the session /
ownership / command / queue / settings layers on both ends, then a walk
through the concrete two-device scenarios that sentence implies (start here,
control there, hand over, sleep/wake, background, quit).

**8 findings fixed** (4 blockers, 4 medium) plus 2 small parity items. Same
environment constraint as audits 3/4: no Swift toolchain, no display server.
TS half gated by `tsc --noEmit` + `npm run bundle` + `npm run test:logic`
(new `syncAudit5-seat.test.ts`, 25 assertions); Swift half by line-by-line
review against its TS twin plus an independent model review of every Swift
diff. GUI pass is the user's — `smoke-test.md` → "Sync audit 5".

---

## Blockers

**S1. Desktop published `dur: 0` on every track start.**
`LocalPlayer.play()` assigns `src` and the engine publishes synchronously,
before `loadedmetadata` — `el.duration` is still `NaN`. Followers got a
session with a real track and `dur: 0`: the phone's mini bar and Now Playing
showed 0:00 total, the progress hairline/slider were dead, and
`positionMs(atServerMs:)` stopped clamping. It healed only on the next
transition or the 30 s anchor refresh. Same for `takeOverHere`. Fix: the
element's `durationchange` → `LocalPlayer.onDuration` → the engine republishes
when it owns the seat (one extra write per track start).

**S2. Clearing a dead owner's seat left `playing: true` and a stale anchor.**
audit-3's F3 clear (both ends) reset only `ownerDeviceID`/`leaseMs`. Every
follower then extrapolated the frozen record forward and clamped it to the
END of the track; desktop drew a PAUSE icon and the EQ animation for an
ownerless session, and the first transport press auto-took-over at `dur`,
so the song ended instantly and skipped. iOS "Play Here" did the same. Fix:
`frozenPlayback` (TS) / `PlaybackState.frozen(atLeaseMs:nowMs:)` (Swift) —
paused, `pos = positionAt(pb, leaseMs)` (where the owner was at its last
heartbeat; erring early by ≤ one renewal replays a few seconds instead of
skipping them), fresh anchor, `rev + 1`. Pinned by the new test file.

**S3. An owner whose seat was cleared while unreachable got paused when it
came back — even when nobody had taken over.** Laptop sleep, a network blip,
or an iOS suspend long enough for the lease to lapse → a peer clears the
seat (F3, no epoch bump). The returning owner's snapshot handler only
demoted on `epoch > mine`, so it stayed "owner" locally, kept playing as a
zombie for up to 20 s, then `renewLease` fenced → `demote` → `onDeposed` →
**audio paused for no visible reason**. Fix, both ends:
- New gate `seatClearedUnderOwner` (our epoch, not our device in the seat)
  in the snapshot handler, plus the two fenced paths (`publishPlayback`,
  `renewLease`) now distinguish SEAT_CLEARED (same epoch, empty seat) from
  FENCED (taken). Cleared → `seatCleared()` → drop to follower WITHOUT the
  deposed pause → `onSeatCleared`.
- Engine: still playing ⇒ **reclaim** via `takeOver(onlyIfIdle: true)` —
  refuses (`SEAT_TAKEN` / `.seatTaken`) if any other device took the seat
  meanwhile, in which case we yield and pause (never double-play). Paused ⇒
  stay a follower silently; the session reads "paused at pos".
  On iOS the reclaim rides `claimSessionForLocalPlayback(onlyIfIdle:)`.

**S4. iOS Queue tab was blind in remote mode.** It rendered from the LOCAL
`currentTrack`/`previousQueue`. A phone that had never played locally saw
"No song playing" while the desktop was mid-queue; a phone that had been
deposed showed its stale local track as "Now Playing", and tapping that row
called `audioPlayer.resume()` — local audio, implicit claim, session
hijacked. Fix: QueueView mirrors `engine.$mirror` / `$mirrorTrack` and
recomputes `isRemoteControlled` on role/remote changes; effective
current/playing/previous come from the mirror in remote mode (history is
owner-local, so hidden), a ghost current track renders as a `GhostQueueRow`
instead of an empty section, the current-row tap routes through
`requestPause/requestPlay` via a new optional `onToggleCurrent` on
`QueueTrackRow`, and the strip reads "PLAYING ON ANOTHER DEVICE".

## Medium

**S5. iOS library/playlist rows compared against the local track.** In remote
mode the desktop's playing song wasn't highlighted in Downloads/Playlist
detail, and tapping it went through `play(track)` → `playTrack` command →
the owner RESTARTED the song instead of toggling pause (desktop has done the
toggle since audit-2 A). Fix: `DownloadsView`/`PlaylistDetailView` compute
an effective playing id (`mirrorTrack?.id` when remote) + playing flag, and
the current-row tap goes through a new `onToggleCurrent` closure on
`DownloadRow`/the playlist row (remote → request*, local → pause/resume).
`PlaylistsView`/`PlaylistDetailView` now receive `syncManager`. Bottom
insets account for the mini bar being visible in remote mode.

**S6. Desktop applied remote effects without re-anchoring, and wrote them
into per-track memory.** `settingsSync.onRemote → initFxSliders → applyFx()`
never called `engine.publish()`: when the desktop owned the audio and the
phone dragged speed, followers extrapolated at the OLD rate until the next
transition. And `applyFx` unconditionally did `trackFx.set(current, …)`, so
the phone's values overwrote the memory of whatever track was loaded on
desktop — the exact bug fixed on iOS as audit-3 F7 / audit-4 B6. Fix:
`applyingRemoteFx` guard around the apply (no `trackFx.set`), then
`engine.publish()` (no-op unless owner).

**S7. Quitting the desktop while owner left a phantom seat for 45 s.** The
phone showed "playing on your other device" → then the dead-owner banner,
until F3. Fix: `main.js` intercepts `close`, asks the renderer to
`engine.releaseForQuit()` (pause, stop commands, fenced
`coordinator.releaseSeat(final)` → owner "", paused at the current
position), waits ≤1.5 s for the ack, then `destroy()`s the window.

**S8. An iOS owner that was PAUSED and then backgrounded left the same
phantom.** iOS suspends a non-playing app within seconds; the lease lapsed
45 s later and only then did the desktop read idle. Fix:
`scenePhase == .background` → `SyncSessionManager.appDidEnterBackground()`
→ if owner && !playing → `coordinator.releaseSeat(final:)` inside a
`beginBackgroundTask`. A playing owner keeps running under background audio
and keeps the seat. Pressing play on the phone later re-claims through the
existing `isPlaying` path (fresh epoch). Companion UI: new
`engine.idleResumable` (no owner, paused track, nothing local) → the iOS
mini bar shows the track with "PAUSED · TAP TO CONTINUE HERE" → `playHere()`
(twin of desktop's banner, whose wording for an EMPTY seat is now "Paused —
X · Play Here to continue" instead of "stopped responding").

## Low / parity

**S12. iOS `previous()` didn't emit a queue intent.** Re-queuing the current
track at the head went through the debounced LWW `replaceAll`, the one path
audit-4 M11 was meant to retire. Now emits
`.injectFront([current], removing: [current.id])` (pull out wherever it sits,
plant at the head), the rebasable twin of desktop `goPrevious`'s insert.

**S13. iOS "play before connect" never claimed the session.** The `$role`
sink called `reconcileLocalPlayback()` synchronously, but `@Published` emits
in `willSet`, so inside the sink `coordinator.role` still read the OLD value
(`.none`) and reconcile's own guard bailed. A song started before the
auto-connect finished played on the phone with the session reading idle
until the next pause/resume. Fix: the sink now tracks the previous role via
`scan` and defers reconcile one turn — and ONLY for the `.none → .follower`
(attach) transition. `owner → follower` must never re-claim from there: a
just-deposed owner's `pause()` lands asynchronously, so a deferred reconcile
would have found `isPlaying == true` and stolen the seat back.

---

## Known residuals (deliberately not changed)

- **Lock-screen play on a deposed phone.** `MPNowPlayingInfo` keeps the stale
  local track; tapping play there runs `resume()` → local audio → implicit
  claim, so playback jumps to the phone. iOS can't keep a silent app alive as
  the "now playing" app, so true remote lock-screen control isn't available.
  Left as "starting audio here means play here" — same rule as tapping a
  song. Design call for the user.
- **`playTrack` to an owner that lacks the file** still plays nothing and the
  owner's re-publish silently corrects the sender's optimistic mirror.
  Replication normally closes this gap within seconds; no sender-side hint.
- **All-ghost queue on iOS** (audit-4 residual) unchanged.

## Wire-contract changes

None. `frozenPlayback` writes only fields that already exist
(`playback.playing/pos/anchor/rev`, `ownerDeviceID`, `leaseMs`);
`SEAT_CLEARED`/`SEAT_TAKEN` are client-local errors; `takeOver(onlyIfIdle:)`
changes a transaction precondition, not the document.
