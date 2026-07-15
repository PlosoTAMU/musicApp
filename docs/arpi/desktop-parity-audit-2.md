# Desktop ↔ iOS parity — second audit + plan

Audit date: 2026-07-14 (post ARPI P1–P5, `main` @ e1509f2). Sources re-read in
full: all `desktop/src/*.ts` + `index.html` + `main.js`, and the iOS surfaces
(`ContentView`, `AudioPlayerManager` complete, `DownloadsView`, `QueueView`,
`PlaylistsView`, `PlaylistDetailView`, `YouTubeDownloadView`, `AddToPlaylistSheet`,
`CreatePlaylistSheet`, `LyricsView`, `HomeSyncSheet`, `SwipeToQueueModifier`,
`DownloadManager` API + playlist pipeline).

**Verdict on round 1:** everything the P1–P5 plan claimed is genuinely in the
code — rename/delete-undo/info/redownload, crop editor + badge, pitch/bass/
per-track fx, shuffle, queue reorder + clear, playlist mgmt, full remote,
prev-history, playlist-URL downloads, lyrics retry, cap indicator, hints.
This round found a **second tier** of gaps: behavioral divergences that only
show up when you compare what the *live* iOS UI actually does (not what its
older code paths suggest), plus usability seams.

## Headline discovery

`AudioPlayerManager.loadPlaylist` — the playlist-mode wrap/interleave path the
desktop twinned in P3 — is **dead code on iOS**. No live UI calls it
(verified by grep: only `queuePlaylist`/`injectAtFrontOfQueue` are reachable,
from `PlaylistDetailView`). The finished product's real playlist behavior is
**queue-based**:

- Tap **Play** on a playlist → `queuePlaylist`: every track is appended to the
  **synced queue** *without interrupting* the current song.
- Within 2 s the button reads **"Play now?"** → second tap =
  `injectAtFrontOfQueue`: plays the first track immediately, rest go to the
  queue front. Same double-tap pattern for **Shuffle / "Shuffle now?"**.
- Nothing wraps at the end; the queue drains and playback stops.
- Because it rides the shared queue, **every device sees and can reorder the
  upcoming playlist tracks**.

Desktop's `playAll` instead interrupts immediately and arms an owner-local
wrap loop that other devices cannot see (`engine.playlistLoop`, deliberately
unsynced). So the same user action produces different behavior on the two
ends, and the phone loses visibility/control of a desktop-started playlist —
the exact inverse of the "full remote" goal.

---

## Part 1 — Findings

Legend: severity from the user's chair. Evidence = file:symbol.

### High

| # | Finding | iOS (live behavior) | Desktop today | Evidence |
|---|---------|--------------------|---------------|----------|
| 1 | Playlist play semantics diverge | Play/Shuffle enqueue into the **synced** queue w/o interrupting; 2 s "Play now?/Shuffle now?" double-tap plays immediately; no wrap; visible on all devices | `playAll` interrupts now + owner-local wrap loop invisible to other devices; playlist doesn't survive handover | `PlaylistDetailView.PlaylistActionButtons` vs `engine.playAll`/`playlistLoop` |
| 2 | Loop never auto-disables | Loop turns OFF on add-to-queue, queue-playlist, inject, play-from-queue | `player.loop` stays on → "Play all"/queued songs silently repeat one track forever | `AudioPlayerManager` (5 auto-disable sites) vs `engine.queueLocal`/`playAll`/`playFromQueue`… |
| 3 | Add-to-queue while idle is inert | `addToQueue` with nothing playing starts playback immediately | `queueLocal` appends and… nothing; Space/next also do nothing while idle, so the queue sits dormant | `AudioPlayerManager.addToQueue` vs `engine.queueLocal` |

### Medium

| # | Finding | iOS | Desktop today | Evidence |
|---|---------|-----|---------------|----------|
| 4 | No visible play history | Queue tab shows **Previously Played** rows; tap replays | history exists (powers prev) but is invisible | `QueueView` "Previous" section vs `engine.history` (private) |
| 5 | Clicking the playing row restarts it | Tap on the current track's row = pause/resume toggle | click = `playLocal` → restart from 0 | `DownloadRow.handleTap` vs `ui.ts renderLibrary` `li.onclick` |
| 6 | Spotify playlist/album downloads rejected | `fetchSpotifyPlaylistTracks` resolves every track → per-track ytsearch downloads | error: "paste a YouTube playlist link" (P5 deferral) | `DownloadManager.downloadPlaylist` vs `download.ts` throw |
| 7 | Playlist downloads: no per-track dedupe/failures | skips already-downloaded tracks; each failure lands in the failed banner; sequential with per-track titles | single `--yes-playlist` run: dups re-fetched, one aggregate error on failure | `downloadPlaylist` filter vs `download.ts` args |
| 8 | Crop/rename unreachable from Now Playing | top bar has ✂ crop; long-press title = rename | rail has loop/fx/lyrics/add-pl only; must locate the row in the library | `NowPlayingView.topBar` vs `index.html .rail-actions` |
| 9 | Prev after "play from queue" restarts instead of going back | `playFromQueue` pushes current onto `previousQueue` | `playFromQueue` → `playLocal` skips the history push | `AudioPlayerManager.playFromQueue` vs `ui.ts playFromQueue` |
| 10 | Empty-queue hint promises drag that doesn't exist | (n/a — swipe-to-queue gesture) | hint says "…or drag songs in", but library rows aren't draggable and the queue panel has no drop target | `ui.ts` hint string vs `renderLibrary` (no `draggable`) |

### Low

| # | Finding | Evidence |
|---|---------|----------|
| 11 | No fx reset affordances (iOS: per-slider Reset + Reset All) | `AudioSettingsSheet` vs `#fx` rows |
| 12 | Hold gestures missing: rewind-hold = scrub −0.5 s repeating, FF-hold = temporary 2× (works even bypassed) | `RewindButton`/`FastForwardButton` vs `btn-back10/fwd10` click-only |
| 13 | Resume after >60 s paused restarts from 0 on iOS; desktop resumes in place | `AudioPlayerManager.resume` autoRestartThreshold |
| 14 | Queue rows have no context menu (iOS: rename/redownload) | `QueueTrackRow.contextMenu` vs `ui.ts` queue row |
| 15 | No bulk add: iOS creates playlists with multi-selected songs and has a checkmark "Add Songs" sheet; desktop adds one row at a time via ♪ | `CreatePlaylistSheet`/`SelectSongsSheet` |
| 16 | Playlist cards show count only (iOS: count + duration on every card) | `PlaylistCardLabel` vs `renderPlaylists` card chip |
| 17 | No "Playing from playlist/queue" status strip + song counts in the queue panel | `QueueView` status strip |
| 18 | `rail-addpl` tooltip says "open playlist" but it opens the any-playlist picker | `index.html` title attr |
| 19 | Effects default: iOS ships bypassed (`effectsBypass = true`); desktop ships active | `AudioPlayerManager` vs `ui.ts fx` |

### Known deferrals still open (from NOTES, unchanged)
- Crop for local-only (no-yt) files — iOS crops them (crop lives in the local
  Download record); desktop has no doc to carry it. Needs a local crop store.
- Local artwork for folder imports / offline — desktop art requires internet
  (i.ytimg.com); iOS caches thumbnail files. Needs a tag parser or bundled art.

### Checked and fine (no action)
Sync engines, remote control both directions, seek ±10 (incl. remote), lyrics
(synced/plain/instrumental/offset/tap-seek/Try Again — network errors coalesce
into the retryable "No lyrics found"), crop editor math + preview + badge,
rename/delete-undo/redownload/info, dup detection, failed panel, shuffle,
queue reorder guard, playlist rename/reorder/delete-confirm/cover, 500-cap,
sort, keyboard/media keys, handoff, demo mode. Siri/share-sheet/lock-screen ↔
media keys are platform-appropriate; MPVolumeView ↔ element volume likewise.

---

## Part 2 — Plan (strict priority order)

Ground rules unchanged: iOS live behavior is the reference; frozen Firestore
wire contracts; static gate = `tsc --noEmit` + `npm run bundle`; logic gates in
Node for DOM-free code; GUI smoke deferred to the user's machine
(`smoke-test.md` accumulates).

### Phase A — Queue & playlist semantics (match the live product)
1. **Queue-based playlist play** `[#1]` — "Play all"/"Shuffle all" (cards,
   open header, card menu) enqueue all resolvable tracks into the **shared
   queue** without interrupting; if idle, start the first track (same as #3).
   Button flips to "Play now?"/"Shuffle now?" for 2 s; second activation
   removes those tracks from the queue and re-inserts at the front + plays
   (twin of `injectAtFrontOfQueue`). Retire `playlistLoop`/wrap/`playFromPlaylist`
   and the "Up Next from Playlist" split — live iOS has neither; the shared
   queue becomes the single source the phone can also see and reorder.
   *(Decision recorded below — this reverses a P3 choice made against the dead
   `loadPlaylist` path.)*
2. **Loop auto-disable** `[#2]` — clear `player.loop` on queueLocal /
   playlist-enqueue / inject / playFromQueue, mirroring the five iOS sites.
3. **Idle queue starts playback** `[#3]` — `queueLocal` (and playlist enqueue)
   with no active owner/track: take over and play the first resolvable ref.
4. **History on play-from-queue** `[#9]` — push current track before jumping.
5. **Row click on the playing track = pause/resume** `[#5]` — library, open
   playlist, and queue rows (by resolved id).

**Verify:** Node tests for the new queue ops (enqueue-many order, inject-front
dedupe, idle-start guard); manual two-device pass: phone sees + reorders a
desktop-started playlist, "Play now?" double-tap, loop clears.

### Phase B — Queue panel parity
6. **Previously Played section** `[#4]` — render the (owner-local) history,
   most recent at the bottom, muted; click replays (pushes current first).
7. **Queue-row context menu** `[#14]` — reuse `trackMenu` on resolvable rows.
8. **Drag-to-queue** `[#10]` — library rows `draggable`; queue panel (incl.
   empty state) accepts drops → `queueLocal`. Hint text stays honest.
9. **Status strip** `[#17]` — "PLAYING FROM QUEUE · N songs" over the panel.

### Phase C — Downloads parity
10. **Spotify playlist/album sets** `[#6]` — port iOS's approach: resolve the
    set to (title, artist) pairs (Spotify embed/oEmbed page data, as the iOS
    embedded-python script does), then sequential `ytsearch1:` downloads with
    per-track progress, dedupe (`findDuplicateByVideoID` twin = library yt/name
    scan), and failed-panel entries.
11. **YouTube playlist rework to per-track pipeline** `[#7]` — enumerate with
    `--flat-playlist --print id,title` first; skip tracks already in the
    library; download one at a time (`Track N/M`); each failure → failed panel;
    suppress the post-download playlist prompt during a batch (iOS
    `isBatchDownloading`).

### Phase D — Now Playing rail + transport polish
12. **Crop from the rail** `[#8]` — ✂ button (enabled when the current track
    resolves locally + has a yt id) → existing `showCropSheet`.
13. **Rename current track** `[#8]` — double-click the title (desktop idiom
    for iOS long-press) → existing rename prompt, when the track is local.
14. **fx resets** `[#11]` — double-click a slider = reset that control;
    "Reset all" link under the stack (skips volume, like iOS Reset All).
15. **Hold gestures** `[#12]` — hold ⏪ = repeat −0.5 s scrub; hold ⏩ =
    temporary 2× (element `playbackRate` override, restore on release).
16. **>60 s-pause auto-restart** `[#13]` — track `lastPausedAt`; owner resume
    after 60 s restarts at 0 (iOS `autoRestartThreshold`).

### Phase E — Small parity + cosmetics
17. **Bulk add songs** `[#15]` — "＋ Add songs" in the open-playlist header →
    checkmark modal over the library list; create-playlist prompt gains the
    same picker (or keep create-then-add: user call, low stakes).
18. **Playlist card durations** `[#16]` — reuse `computePlaylistDuration`
    lazily per visible card, cached.
19. **Tooltip + defaults** `[#18, #19]` — fix `rail-addpl` title; align the
    fresh-install effects-bypass default with iOS (start bypassed).

### Deferred (unchanged, need a user call)
- Crop for local-only files (local crop store).
- Offline/local artwork (tag parser dep).

### Decision points surfaced to the user
- **A1 reverses P3-item-16**: that phase twinned `loadPlaylist`'s wrap +
  interleave, which this audit found unreachable in the live iOS UI. Options:
  (a) match live iOS (recommended — synced, visible cross-device, simpler), or
  (b) keep the wrap loop as a desktop extra behind the current buttons and add
  the queue-based path separately. The plan assumes (a).
- Phase C item 10 (Spotify sets) is the largest new work item; skippable if
  the pointer-to-YouTube error is acceptable long-term.

### Cross-cutting verification
- Every phase: `tsc --noEmit` + `npm run bundle` green before commit.
- Phase A ships a Node logic-test file for the queue semantics.
- `docs/arpi/smoke-test.md` gains a checklist per phase; two-device checks
  need a real home secret (owner-visibility of playlists is the key one).
- NOTES.md updated before each phase starts.
