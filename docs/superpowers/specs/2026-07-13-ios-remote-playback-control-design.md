# iOS Remote Playback Control — Design

**Date:** 2026-07-13
**Goal:** Any device can pause/play/skip/seek the session regardless of which
device owns playback, from both desktop and iOS, with a clearly visible way to
switch playback to the device in hand. Desktop already behaves this way; this
work brings iOS to parity.

## Background

The sync backend fully supports remote control today:

- `CommandBus` is the follower → owner control channel (command docs in
  Firestore; owner applies them to its local player and republishes fenced
  state).
- `PlaybackSyncEngine` exposes `requestPlay/requestPause/requestNext/
  requestPrevious/requestSeek(ms:)` which run locally when owner and send
  command docs when follower, plus `takeOverHere()` for fenced handover and a
  `@Published mirror: PlaybackState?` of the remote session.
- Desktop (`desktop/src/ui.ts`) already wires its transport buttons through
  this bridge, patches the mirror optimistically so controls feel instant, and
  shows a "Play Here" button with a role chip.

The iOS UI does none of this:

- `NowPlayingView` blurs the whole screen when another device owns playback
  and locks it behind a "Playing on your other device / Play Here" overlay
  (`ContentView.swift:711-716`, `remoteLockOverlay`).
- `MiniPlayerBar` renders only when the *local* player has a track
  (`ContentView.swift:125`); a follower never gets a local `currentTrack`, so
  while another device plays, the phone shows no playback UI at all.

## Scope

iOS-only UI work plus small additions to `PlaybackSyncEngine`. No protocol
changes, no desktop changes, no `AudioPlayerManager` changes. Device names are
out of scope (the session doc has only device UUIDs); the UI says "another
device".

## Design

### Remote mode predicate

Remote mode is active when `coordinator.role == .follower` and
`coordinator.remote?.ownerDeviceID` is non-empty — the same predicate
`NowPlayingView.isRemoteControlled` uses today. It moves to a computed
`isRemoteControlled` on `PlaybackSyncEngine` so every view shares one
definition. When the device is solo (`role == .none`) or owner, all behavior
below is unchanged from today.

### Engine additions (`PlaybackSyncEngine`)

1. **`@Published private(set) var mirrorTrack: Track?`** — the mirror's
   `TrackRef` resolved against the local library, set in `handleRemote`
   alongside `mirror`. Gives views artwork/file paths without exposing the
   private resolver. Unresolvable (ghost) → `nil`; views fall back to the
   ref's `name` and placeholder art.
2. **Optimistic mirror patching** in `route(_:)` on the follower path,
   mirroring desktop's `toggleCmd`/`seekCmd`:
   - `.play` / `.pause`: set `mirror.isPlaying`, re-anchor
     (`positionMs = extrapolated now`, `anchorMs = ServerClock.shared.nowMs`).
   - `.seek(ms)`: set `positionMs = ms`, re-anchor.
   - `.next` / `.previous`: no patch (target track unknown until the owner's
     authoritative snapshot arrives).
   The next authoritative snapshot overwrites the mirror wholesale (the
   coordinator replaces `remote` on every snapshot), so no rollback logic is
   needed. This removes the 0.7–2 s Firestore round trip from perceived
   latency.
3. **Remote position for display** is computed on demand via the existing
   `PlaybackState.positionMs(atServerMs:)`; views tick it with a
   `TimelineView` only while visible. No timer runs when nothing shows it.

### MiniPlayerBar (`ContentView.swift`)

- Visibility becomes `audioPlayer.currentTrack != nil ||
  engine.isRemoteControlled` so the phone always surfaces what is playing in
  the house. `UpNextMiniBar` stays inside the same condition; the follower's
  local queue is already mirrored, so it shows the correct next track.
- In remote mode:
  - Title/folder come from `mirror.track` (the `TrackRef`), artwork from
    `mirrorTrack` via the existing thumbnail path resolution.
  - Play/pause and next call `engine.requestPlay()/requestPause()/
    requestNext()`; the play/pause icon reflects `mirror.isPlaying`.
  - The progress hairline extrapolates from the mirror inside a
    `TimelineView`.
  - A small Theme-tinted glyph (`laptopcomputer.and.iphone`) marks the bar as
    showing a remote session.
- Tapping the bar opens Now Playing, as today.

### NowPlayingView (`ContentView.swift`)

- `remoteLockOverlay`, the blur, and the hit-testing lock are deleted.
- A single `displayTrack: Track?` — local `currentTrack` normally,
  `mirrorTrack` in remote mode — drives the title, artwork, background, and
  top-bar utilities (add-to-playlist, crop, rename). File-bound actions
  disable when `displayTrack` is `nil` (ghost).
- Transport in remote mode routes through `requestPlay/Pause/Next/Previous`;
  the play/pause icon reflects `mirror.isPlaying`. The seek slider keeps its
  existing drag-state pattern (`isSeeking`/`localSeekPosition`) and sends
  `requestSeek(ms:)` on release. Position/duration display from the mirror,
  ticked by `TimelineView`.
- **Switch pill**: in remote mode a full-width pill renders directly below
  the top bar (the row with the dismiss chevron and queue buttons), above the
  artwork: "Switch playback to this iPhone", with a "Switching…" busy state,
  calling `syncManager.playHere()`. A one-line caption above it reads
  "Playing on another device". Uses the existing `PillButtonStyle` (no stock
  controls, per Theme rules). On success the role flips to owner and the view
  reverts to local mode naturally.
- Volume bar and visualizer are hidden in remote mode (volume is not synced
  on any platform; there is no local audio to visualize —
  `startVisualization()` is skipped). Effects controls stay: speed/bass/
  reverb already sync via `SettingsSync`.

### Unchanged behavior (deliberate)

- Tapping a specific song anywhere (library rows, `QueueView` rows,
  `UpNextMiniBar`) plays it locally, which performs the existing implicit
  takeover (`claimSessionForLocalPlayback`) — twin of desktop
  `playLocal() → takeOver()`. Starting a song on a device means "play it
  here"; transport buttons mean "control wherever it plays".
- Queue editing already syncs bidirectionally with ghost preservation.
- Bluetooth route handoff (`RouteHandoffMonitor`) is untouched.

## Edge cases

- **Ghost current track** (owner playing a track this phone hasn't replicated
  yet): title shows from the `TrackRef`, placeholder artwork; the switch pill
  is disabled with caption "Not in this device's library yet" —
  `takeOverHere()` would claim the session but produce silence.
- **Owner unreachable** (lease expired): commands would queue unanswered
  (and `CommandBus` drains commands older than 30 s without applying). Show a
  dim "Other device offline" line in place of the "Playing on another device"
  caption and keep the pill prominent — twin of desktop's `owner-dead` hint.
- **Command echo/staleness**: already handled by `CommandBus` (server-order
  apply, stale drain, self-command filtering); no new logic.
- **Double audio**: impossible from this work — remote mode never starts
  local audio; only the explicit pill or implicit song-tap takeover paths do,
  and both are pre-existing fenced paths.

## Testing / verification

No test target exists and iOS cannot build in this environment. Verification
is a careful static review plus this manual matrix on a real pair:

1. Desktop owns playback → phone mini bar appears with the playing track;
   play/pause/next/seek from phone land on desktop within ~2 s, phone UI
   updates instantly (optimistic patch).
2. Phone Now Playing shows live position; seek slider scrubs the desktop.
3. "Switch playback to this iPhone" continues audio on the phone at the
   extrapolated position; desktop flips to "Remote".
4. Reverse direction (desktop controls phone) still works.
5. Solo phone (no session / `role == .none`): mini bar, Now Playing, volume,
   visualizer all behave exactly as before.
6. Ghost track on phone → pill disabled with caption; controls still work.
