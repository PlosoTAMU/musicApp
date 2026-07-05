# Full sync coverage: bidirectional downloads + effects settings

## Context

Pairing/connection between the iOS app (Pulsor) and the Electron desktop
companion already works. Transport controls, queue ops, playlists, lyrics,
and Bluetooth handoff are fully bidirectional and require no changes
(verified by tracing both codebases — see gap analysis below). Two real
gaps remain before "connect and everything syncs, including new songs" is
true.

## Gap analysis (verified against current code)

Not gaps (already bidirectional, no work needed):
- Transport (play/pause/next/prev/seek) — `commandBus.ts` / `CommandBus.swift`.
- Queue insert/remove/move/reorder — any screen that mutates
  `AudioPlayerManager.queue` (iOS) or the local player queue (desktop)
  auto-publishes via the existing Combine/observer pipeline
  (`PlaybackSyncEngine.swift:178-182`, `engine.ts`). iOS `QueueView` needs
  no new wiring.
- Playlists — `PlaylistSync.swift` / `playlists.ts`, full LWW parity.
- Lyrics + offset — shared Firestore doc, both read/write.
- Bluetooth handoff — `RouteHandoff.swift` / `coordinator.ts` handoff beacon.

Real gaps:
1. **Library down-sync is one-directional.** Desktop's `Replicator`
   (`replicator.ts`) both downloads cloud tracks it lacks (via yt-dlp) and
   uploads local-only tracks. iOS's `LibraryReplicator.swift` only
   uploads — no listener notices a desktop-only track and pulls it down.
   iOS already has the download primitive needed:
   `DownloadManager.startBackgroundDownload(url:videoID:source:title:)`
   works headlessly, no UI required.
2. **Effects settings never sync.** Speed, bass boost (dB), and reverb
   exist as sliders on both apps with compatible units/ranges but are
   persisted only to local storage (`fx.v1` on desktop,
   `AudioPlayerManager`'s per-track `TrackSettings` on iOS). Neither
   pushes to the other device.
   - Volume is explicitly out of scope — it's a hardware/per-device
     concern; syncing it would fight the physical volume controls on
     whichever device didn't initiate the change.
   - iOS-only controls with no desktop equivalent (pitch shift, effects
     bypass toggle) stay local — there's nothing on desktop to sync them
     into.

## Design

### A — iOS library down-sync

Extend `LibraryReplicator.swift` to mirror `replicator.ts`'s two-way
pattern:
- Add a Firestore snapshot listener on `users/{uid}/library` (same
  collection the upload side already writes to).
- Maintain an in-memory `meta: [String: TrackMeta]` cache (doc id → cloud
  metadata), same shape as `replicator.ts`'s `meta` map.
- On each snapshot: for any doc with a `yt` id not already present locally
  (matched by videoID first, then normalized name — reuse
  `DownloadManager.findDuplicateByVideoID`), enqueue it in a serial
  download queue.
- Pump the download queue one at a time via
  `DownloadManager.startBackgroundDownload(url: "https://www.youtube.com/watch?v=<yt>", videoID: yt, source: .youtube, title: name)`.
  Retry up to 3 attempts on failure (mirrors `replicator.ts:82-91`), then
  drop until the next snapshot.
- Fix the upload side's dedupe: before mirroring a local-only download,
  check the cloud `meta` cache for a matching `yt`/normalized-name entry
  first (mirrors `replicator.ts`'s `inCloud()`) — otherwise a down-synced
  track (which gets a new local UUID) would immediately re-upload as a
  duplicate doc.
- No changes to `SyncSessionManager` needed — `connect()` already calls
  `replicator?.activate(uid:)`, so down-sync starts automatically the
  moment both devices are connected.

### B — Shared effects settings

New doc: `users/{uid}/sync/settings`
```
{ speed: number, bassDb: number, reverbPct: number,
  updatedBy: string, at: serverTimestamp }
```
LWW by `at`, same pattern as the playlist/session docs. `updatedBy`
filters out same-device echo (same technique as `coordinator.ts`'s
`updatedBy` check).

- Desktop: new `desktop/src/settingsSync.ts`. `bindFx` for speed/bass/
  reverb also writes the doc (debounced ~300ms while dragging). A
  snapshot listener updates `fx.speed/bass/reverb` + slider DOM + calls
  `applyFx()` when a remote change arrives with a different `updatedBy`.
- iOS: new `Sync/SettingsSync.swift`, constructed alongside
  `LibraryReplicator`/`PlaylistSync` in `SyncSessionManager`, activated in
  `connect()`. Observes `player.$playbackSpeed`, `$bassBoost`,
  `$reverbAmount` (debounced) to publish; a snapshot listener applies
  incoming values back onto those same `@Published` properties, guarded
  against echoing its own last-published values.
- Values pushed as-is (both apps already use the same units: speed as a
  multiplier, bass in dB, reverb as 0-100%); receiving side clamps to its
  own slider's min/max on apply.

### Testing

Manual, two real clients (desktop + phone), after each workstream:
- A: download a song on desktop only → confirm it appears downloaded on
  phone without touching the phone. Repeat in reverse. Confirm no
  duplicate library entries appear on either side.
- B: drag speed/bass/reverb slider on one device while connected →
  confirm the other device's slider and actual playback effect move to
  match within ~1s. Confirm dragging on device A while device B is
  mid-drag doesn't fight (last write wins, no oscillation).

## Out of scope
- Volume sync (hardware-local).
- Syncing iOS pitch shift / effects-bypass toggle (no desktop equivalent).
- A push/priority "download this now" signal — sync stays passive/eventual,
  matching the existing playlist/queue model.
