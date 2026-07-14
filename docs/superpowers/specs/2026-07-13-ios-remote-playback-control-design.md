# Sync Completeness: Remote Control, Metadata Sync, Download Quality — Design

**Date:** 2026-07-13
**Goal:** Four workstreams toward "every device is an equal citizen of the
home session":

1. **iOS remote playback control** — pause/play/skip/seek from any device
   regardless of which one owns playback, with a clearly visible way to
   switch playback to the device in hand. Desktop already behaves this way;
   this brings iOS to parity.
2. **Desktop download quality** — desktop YouTube downloads prioritize
   quality; iOS keeps its space-saving format.
3. **Track metadata sync** — renames, crop settings, folder assignment, and
   deletions propagate to every device ("all parts of the music" sync).
4. **Lyric offset freshness** — the already-synced lyric nudge offset is
   re-read from the cloud when opening lyrics.

# Part 1 — iOS Remote Playback Control

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

## Scope (Part 1)

iOS-only UI work plus small additions to `PlaybackSyncEngine`. No session-doc
protocol changes, no desktop changes, no `AudioPlayerManager` changes. Device
names are out of scope (the session doc has only device UUIDs); the UI says
"another device".

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

## Edge cases (Part 1)

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

# Part 2 — Desktop Download Quality

## Background

Replication is **link-sync**: no audio bytes move between devices — each
device runs its own yt-dlp download from the shared YouTube id
(`LibraryReplicator.swift` header, `replicator.ts`). So each platform's
format choice is independent.

- iOS requests `'140/bestaudio[ext=m4a]/bestaudio/best'`
  (`EmbeddedPython.swift:490`) — format 140 is 128 kbps AAC m4a, chosen
  deliberately for space and reliability. **Unchanged.**
- Desktop requests `bestaudio[ext=m4a]/bestaudio` (`download.ts:84`) — the
  m4a preference effectively pins it to the same 128 kbps AAC even though
  the desktop has no space constraint.

## Design

Desktop's yt-dlp format selector becomes plain **`bestaudio`** — yt-dlp then
picks the highest-bitrate audio stream YouTube serves (typically ~160 kbps
VBR Opus in webm). Chromium and the desktop scanner already handle
opus/webm natively (stated in `download.ts`'s own header comment; no ffmpeg
dependency needed).

Non-goals: no re-download sweep of existing 128 kbps files (new downloads
only); no iOS change.

# Part 3 — Track Metadata Sync (rename, crop, folder, deletion)

## Background

The per-track cloud doc under `users/{uid}/library/{docId}` is currently
**write-once**: `{name, folder, ext, yt, by, at}` created when a track is
first mirrored, never updated (`LibraryReplicator.upload`, `replicator.ts`).
Consequences today:

- Renames don't propagate (iOS `renameDownload` touches only the local file,
  record, and thumbnail).
- Crop settings (`Download.cropStartTime/cropEndTime` — pure metadata, the
  audio file is untouched) exist only on iOS and never leave the device.
  Desktop has no crop concept at all; its lyrics are documented to "run
  early by cropStart" on cropped tracks (`ui.ts:600`).
- iOS uploads `folder: ""` while desktop uploads its real subdirectory —
  folder info is asymmetric and never reconciled.
- Deletions don't propagate; docs are never removed.

## Design

### The library doc becomes the durable, mutable metadata record

New/changed fields, all optional for backward compatibility with existing
docs:

- `name` — now mutable.
- `folder` — now mutable, with **desktop as the folder authority**: only
  desktop (where folders are real subdirectories the user rearranges) ever
  writes it; iOS consumes it for display grouping and never writes it. (If
  iOS pushed its literal "YouTube Downloads" folder as authoritative, every
  desktop file would get physically moved into that subdirectory.)
- `cropStartMs`, `cropEndMs` — integers, absent = uncropped.
- `deleted` — tombstone flag (see deletion semantics).
- `metaAt` (server timestamp) + `metaBy` (device id) — stamped on every
  metadata write. Last-writer-wins; a device ignores incoming changes it
  authored (`metaBy == self`), the same echo-suppression pattern
  `SettingsSync` uses.

Identity keys on the **YouTube id**. Tracks without one never replicate
today and stay device-local — metadata sync simply doesn't apply to them.
Idempotent re-applies (rename to the same name, same crop values) are
harmless no-ops.

### Up-sync (local change → doc merge-update)

- **iOS**: rename (`DownloadManager.renameDownload`), crop save
  (`CropSongSheet` persistence), and deletion finalization each
  merge-update the matching cloud doc (matched by yt id). The replicator
  keeps its existing add-only pump for new tracks; metadata updates are a
  separate, targeted merge write.
- **Desktop**: the scanner detects a file rename or subdirectory move as
  "same yt id, different name/folder" → merge-update the doc. A file
  deleted locally → tombstone the doc. Desktop has no crop UI; it only
  consumes crop metadata.

### Down-sync (doc change → local apply)

- **iOS**: `name` change → existing `renameDownload` path (file + record +
  thumbnail, preserving record identity); `cropStartMs/EndMs` → set on the
  matching `Download` and persist (and live-apply to the current `Track` if
  it's playing/queued); `folder` → stored on the `Download` and used for
  display grouping only — iOS never physically moves files (imports live in
  security-scoped external folders it cannot move); `deleted` → remove the
  local file and record outright (no `pendingDeletion` undo grace — the
  grace period already happened on the deleting device).
- **Desktop**: `name` change → rename the file on disk, keeping the
  `"<title> [<videoId>].<ext>"` tag convention so identity survives;
  `folder` change → move the file to that subdirectory (creating it if
  needed); `crop` → hold in the meta cache and honor in playback (below);
  `deleted` → delete the file.

### Desktop crop-aware playback (new capability)

Syncing crop to a player that ignores it would be pointless, so desktop's
player honors crop bounds: playback starts at `cropStartMs`, auto-advances
at `cropEndMs`, and the UI (and published session `dur`, which is already
defined as "cropped track length ms" in `protocol.ts`) reflects the cropped
duration. Bonus: desktop lyrics compensate by `cropStartMs` automatically,
fixing the documented "lines run early" behavior instead of relying on the
manual nudge.

### Deletion semantics — revivable tombstone ("allow redownload")

- Finalized deletion flips the doc to `deleted: true` (+ `metaAt/metaBy`)
  rather than removing it, so devices offline at the time apply the
  deletion when they reconnect.
- Replicators skip tombstoned docs in auto-fetch (down-queue) and never
  re-mirror a locally-absent track over a tombstone (no resurrection).
- **Re-download revives**: when a device manually downloads a video whose
  yt id matches a tombstoned doc, the mirror step updates that doc in place
  (`deleted: false`, fresh name/meta) instead of creating a duplicate doc.
  Nothing permanently blocks getting a song back.

## Edge cases (Part 3)

- **Concurrent edits** (rename on phone while desktop renames the same
  track): LWW by `metaAt`; the loser's file gets renamed again to the
  winner's value on the next snapshot. Acceptable for a home library.
- **Rename of a currently-playing track**: the local record/file rename
  must not interrupt playback (iOS `renameDownload` already handles the
  playing-track case at `DownloadManager.swift:962`; desktop should skip
  the disk rename until the track isn't the loaded file, applying it on
  the next scan).
- **Delete of the currently-playing track on another device**: local apply
  stops playback of that track and advances the queue.
- **Legacy docs** (no `metaAt`): treated as older than any stamped write;
  first metadata edit upgrades them.

# Part 4 — Lyric Offset Freshness

Lyric nudge offsets **already sync on both platforms** (verified: iOS
`LyricsService.nudgeOffset` merge-writes `offsetMs` to
`users/{uid}/library/{key}/lyrics/current` and desktop `nudgeLyrics` →
`lyricsStore.setOffset` writes the same doc; both read it on fetch). The
one gap: both sides prefer their disk/memory-cached lyrics doc, so a nudge
made on device A doesn't reach device B if B already has a cached copy.

Fix: when opening lyrics for a track, re-read `offsetMs` from the cloud doc
(cheap single-field get, best-effort offline) and prefer it over the cached
value on both platforms.

# Testing / verification

No test target exists and iOS cannot build in this environment. Verification
is a careful static review plus this manual matrix on a real pair:

**Part 1 — remote control**

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

**Part 2 — download quality**

7. Desktop download of a known video yields the opus/webm (or highest-abr)
   stream, not 128 kbps m4a; file plays on desktop; iOS still downloads 140.

**Part 3 — metadata sync**

8. Rename on phone → desktop file renamed (yt tag intact) within seconds;
   rename on desktop (file manager) → phone shows new title.
9. Crop on phone → desktop playback of that track starts/ends at the crop
   bounds, duration displays cropped, lyrics align without manual nudge.
10. Move a file between desktop subfolders → phone regroups it under the
    new folder name (display only; no iOS files move).
11. Delete on one device → gone everywhere (including a device that was
    offline during the delete); re-download of the same video succeeds and
    replicates again.
12. Two devices rename the same track near-simultaneously → both converge
    on one name, no duplicate docs.

**Part 4 — lyric offsets**

13. Nudge lyrics on desktop, open the same track's lyrics on phone (which
    had them cached) → phone uses the new offset.
