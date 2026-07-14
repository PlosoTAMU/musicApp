# Desktop ↔ iOS parity audit — findings

Audit date: 2026-07-14. Sources read in full: iOS (`musicApp/**`, all Swift views
+ `AudioPlayerManager`/`DownloadManager` at API level) and desktop (`desktop/main.js`,
`desktop/index.html`, all `desktop/src/*.ts`).

Summary: sync, playback, downloads, lyrics and effects have solid twins on desktop.
The desktop is missing an entire tier of **library/queue/playlist management** and,
most importantly, cannot be used as a **remote** while the phone owns playback.

Legend: **impact** = user-visible severity; **evidence** = where the gap lives.

## Part 1 — Feature parity gaps (iOS has, desktop lacks/degrades)

### High impact

| # | iOS feature | Desktop status | Evidence |
|---|---|---|---|
| 1 | Previous track — real history (`previousQueue`), restores playlist index | `prev` only seeks to 0; no history, no "Previously Played" | `desktop/src/engine.ts` `applyLocal` `case "prev"` |
| 2 | Shuffle — playlist Shuffle w/ double-tap "Shuffle now?" | Absent everywhere | no `shuffle` in `desktop/src` |
| 3 | Rename track — context menu + long-press title | No UI; only file-manager rename syncs | `DownloadsView.swift` ctx menu vs. none in `ui.ts` |
| 4 | Delete track — trash w/ 5s undo, removes from playlists, stops player | No UI; only on-disk delete (→ tombstone), no undo | `DownloadManager.markForDeletion` vs. `replicator.ts` reconcile |
| 5 | Crop editor — start/end sliders, text fields, preview | Honors crops from sync, cannot create/edit; no CROPPED badge | `CropSongSheet.swift` vs. `player.setCrop` only |
| 6 | Remote control of the owning device (full touch remote) | Rail blurred + `pointer-events:none`; only "Play Here". Keyboard/media keys secretly still work | `index.html` `.rail-content.blurred`; `ui.ts` keydown handlers |
| 7 | Playlist mode — plays past queue, wraps `(i+1)%n`, interleaves queued vs playlist | "Play all" dumps rest into shared queue; stops at end, no wrap/interleave | `AudioPlayerManager.next()` vs. `engine.playAll` |
| 8 | Pitch shift ±12 st (a headline reason the app exists per README) | Absent (HTMLAudioElement can't; needs Web Audio) | `AudioSettingsSheet` pitch card vs. `ui.ts` fx (no pitch) |

### Medium impact

| # | iOS feature | Desktop status | Evidence |
|---|---|---|---|
| 9 | Queue reorder (drag) + Clear All | Remove-one only | `QueueView` onMove/onDelete vs. `ui.ts` queue row |
| 10 | Playlist mgmt — rename, reorder, cover art, count + duration | Create/delete/open/play/add/remove only; count only | `PlaylistsView`/`PlaylistDetailView` vs. `playlists.ts`/`renderPlaylists` |
| 11 | Add-to-playlist picker (any row / Now Playing) + post-download prompt | Only adds to currently-open playlist; no prompt | `AddToPlaylistSheet` vs. `rail-addpl`/row `♪` |
| 12 | Playlist-URL downloads (whole set) | `--no-playlist` — single tracks only | `download.ts` args |
| 13 | Failed-downloads banner + duplicate detection + redownload | One transient status line; silent 3× retry; no dup check; no redownload | `FailedDownloadsBanner`/`findDuplicateByVideoID` vs. `startDownload` |
| 14 | Bass boost −10..+20 dB | Slider 0..+12; `settingsSync.onRemote` clamps 0..12 → phone value lost | `AudioSettingsSheet` vs. `index.html` `#fx-bass`, `ui.ts` clamp |
| 15 | Per-track effect memory (speed/pitch/reverb/bass persisted per track) | Global fx blob; never contributes per-track back | `AudioPlayerManager.TrackSettings` vs. `ui.ts` `fx` |
| 16 | Lyrics "Try Again" on failure | No retry (must close/reopen) | `LyricsView.unavailableView` vs. `renderLyrics` msg |
| 17 | Song info sheet (source, URLs, video id, path, crop) | None | `SongInfoSheet` vs. none |
| 18 | Seek ±10s buttons / scrub-hold / temporary 2× hold | Keyboard arrows only | `RewindButton`/`FastForwardButton` vs. keydown only |

### Low impact / cosmetic
- Artwork: desktop uses `i.ytimg.com` by yt-id only → folder imports blank, needs internet; no blurred/pulsing artwork.
- Library sort: iOS case-insensitive by name; desktop raw dir-walk order.
- Up-next peek in mini bar / now-playing strip (desktop Up Next panel covers it).
- Long-title marquee (desktop ellipsizes — fine).

### Platform-appropriate, no action
Siri/App Shortcuts, share-extension deep links, lock-screen controls ↔ desktop global media keys; MPVolumeView ↔ element volume. Desktop-only extras iOS lacks: offline demo mode, Bluetooth output handoff, beat/BPM visualizer, disk-edit sync.

## Part 2 — Desktop usability issues

1. **Dead single-click** — rows play only on double-click; hover ▶ is `opacity:0`. Reads as broken.
2. **Remote-control lock inconsistency** — while phone plays, desktop looks decorative yet Space/media keys secretly control it. Half-state.
3. **All row actions hover-only** — ▶ ＋ ✕ ♪ › appear on hover, explained only by `title=`. `♪` and `›`-vs-dblclick undiscoverable.
4. **Playlist delete = one hidden hover-click, no confirm** — tombstones on every device; ✕ sits next to ▶.
5. **File-manager superpowers invisible** — disk rename/move/delete is the only library management and it syncs, but nothing says so.
6. **500-row cap silent** — `renderLibrary` slices to 500 with no "showing 500 of N".
7. **Cropped tracks look wrong, not cropped** — shortened duration, no badge.
8. **Two competing status lines** — `#dl-status` vs. `#repl-status`; replication failures only flash in the bottom bar.
9. **Effects-bypass button ambiguous** — lit=active, no label.
10. **Incomplete keyboard hints** — no Esc, no media keys, no focus-search shortcut.
11. **Empty-queue hint mismatch** — says "Queue is empty"; should say how to add on desktop.
12. **Misc** — role chip no tooltip; `shot-*.png` stale; "playing" highlight matches by normalized name (duplicate titles double-highlight).
