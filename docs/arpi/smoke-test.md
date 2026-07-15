# Desktop parity — GUI smoke-test checklist

The dev box that wrote this code has no display, so GUI/interaction verification
happens here, on a machine that can run `cd desktop && npm start`. Each phase
appends its checklist. Static gates (tsc + bundle) and Node logic tests already
passed for every committed phase; this is the human/visual pass.

Run `cd desktop && npm start`. Use **Offline Preview** (skip connect) for
single-device checks; use a real home secret + your phone for the remote/sync checks.

---

## Phase 1 — Playback control parity + interaction fixes

Single device (offline preview):
- [ ] **Single-click** a library row → it plays (no double-click needed). Clicking the row's ▶ ＋ buttons still does their own action, not a stray re-play.
- [ ] Single-click a **playlist** row → it opens (doesn't require double-click). The ▶ / › buttons still work.
- [ ] Open a playlist, single-click a track row → it plays.
- [ ] **Seek buttons**: the two new circular "10" buttons flank the play button. ◄10 jumps back 10s, 10► jumps forward 10s. Time/slider update.
- [ ] **Prev-track history**: play a queue of ≥3, let it advance (or press ⏭) a couple times, then press ⏮ → it returns to the *previous* song (not just restart). Press ⏮ again → the one before that. With no history (first song) ⏮ restarts the track.
- [ ] After going back with ⏮, press ⏭ → you return forward to the song you came from (current was re-queued at the front).

Two devices (real secret; phone owns playback):
- [ ] Start playback on the **phone**. On desktop the rail is NOT blurred/locked; a small "Controlling your other device — <song>" banner shows with a Play Here link.
- [ ] Desktop ⏯ / ⏭ / ⏮ / seek buttons and the progress slider **control the phone** (phone reacts within ~1–2s; desktop shows optimistic change immediately).
- [ ] Desktop progress bar mirrors the phone's position and the play/pause icon matches the phone's state.
- [ ] Click **Play Here** → desktop takes over playback at the live position (phone stops owning).

---

## Phase 2 — Library management parity

Single device (offline preview + a music folder with a few YouTube-sourced tracks):
- [ ] **Right-click** a library row → context menu (Play / Add to queue / Rename… / Song info / Redownload / Delete). The **⋯** button on hover opens the same menu.
- [ ] **Rename…** → a text modal opens pre-filled; enter a new name → the file on disk is renamed (still tagged `[ytid]`) and the row updates. (With a real secret, the new name reaches the phone.)
- [ ] **Song info** → popover shows title, source, folder, video id, filename, full path (and crop if set). Text is selectable.
- [ ] **Redownload** (only on yt tracks) → re-fetches via yt-dlp; status shows progress; row refreshes.
- [ ] **Delete** → row goes muted/strikethrough with an **Undo** for 5s. Clicking Undo cancels. Letting it lapse deletes the file (and, with a secret, tombstones it on the phone). Deleting the currently-playing track stops playback.
- [ ] **Duplicate guard**: paste a YouTube link for a track already in the library → status says "Already downloaded: <name>", no second download.
- [ ] **Failed downloads**: paste a bad/broken link → a red "1 download failed" panel appears with the error; the ✕ dismisses it.
- [ ] Menus/popovers/modals close on click-away (mousedown outside) and Esc (modal).

---

## Phase 3 — Queue & playlist parity

Single device (offline preview + a few tracks and ≥1 playlist):

Queue:
- [ ] **Drag to reorder** an Up-Next row onto another → order changes and holds. Drag a row onto the one *directly below* it → nothing happens (no-op), it does **not** jump to the bottom.
- [ ] Drag a row to the **top** → it becomes next. The ✕ still removes a row.
- [ ] **Clear** button shows only when the queue is non-empty; clicking it empties Up Next.
- [ ] Single-click a resolvable queued row → it plays and leaves the queue. A ghost ("not here yet") row does not play on click.
- [ ] Empty-queue hint reads "Queue is empty — hover a library song and press ＋, or drag songs in".

Playlists (card list):
- [ ] Each playlist card shows a **cover thumb** (first track's art), the track **count**, a ▶ Play-all, a 🔀 Shuffle-all, and a **⋯** menu. **Right-click** a card opens the same menu (Open / Play all / Shuffle all / Rename… / Delete).
- [ ] **Shuffle all** plays the playlist in a randomized order (run twice → different order); **Play all** uses saved order.
- [ ] Single-click a card → it **opens**.

Playlists (open detail):
- [ ] Header shows **count · total duration** (duration fills in from "…" after a moment); ← back, ▶ Play all, 🔀 Shuffle, ✎ Rename, 🗑 Delete controls.
- [ ] **Rename** (✎ or menu) → text modal → name updates (and reaches the phone with a real secret).
- [ ] **Drag to reorder** tracks in the open playlist → order persists (survives closing/reopening the playlist and, with a secret, a reload).
- [ ] **Delete** (🗑 or menu) → a **confirm** dialog appears first; Cancel keeps it, Delete tombstones it and returns to the card list.

Add-to-playlist (works from anywhere, not just the open list):
- [ ] Library row **⋯ → Add to playlist…** → picker lists every playlist + **New playlist…**; choosing one adds the track (toast); "New playlist…" prompts for a name and creates it already holding the track.
- [ ] Now-playing rail **＋ (add-to-playlist)** → same picker for the current track, with nothing/any playlist open.
- [ ] After a **download completes**, the add-to-playlist picker auto-opens for the fresh track (when ≥1 playlist exists).

Playlist mode (wrap):
- [ ] **Play all** a playlist, let it run to the last track → it **wraps** to the top and keeps playing (does not stop at the end).
- [ ] Directly single-click a **library** track while a playlist is playing → playback switches and playlist-wrap stops (a plain single-track play exits playlist mode).
- [ ] **Clear** the queue → wrap stops (next end-of-track stops instead of looping).

Playlist mode (interleave + Up Next split, item 16):
- [ ] **Play all** a playlist, then hover a library song and press ＋ (or ⋯ → Add to queue) → the queued song plays **next**, *before* the playlist continues (not after the whole playlist).
- [ ] Up Next shows two labeled groups: **Up Next** (your queued songs) then **Up Next from Playlist** (the upcoming playlist tracks). With no queued songs, only the playlist group shows.
- [ ] Click a row under **Up Next from Playlist** → it jumps to that track and keeps playing the playlist from there (still in playlist mode; your queued songs still play next).
- [ ] Let the last playlist track end → it **wraps** to the top.
- [ ] **Clear** while in playlist mode (even with an empty user queue) → exits playlist mode; the next track-end stops instead of looping.

Two devices (real secret; desktop owns a playlist):
- [ ] On the **follower**, Up Next shows only the shared user queue — **no** "Up Next from Playlist" section (the playlist is owner-local, like iOS).
- [ ] Follower taps **Play Here** → it takes over the user queue and playlist mode ends (matches iOS: currentPlaylist isn't synced).

Two devices (real secret):
- [ ] Reorder / clear the queue on desktop → the phone's queue reflects it (and vice-versa).
- [ ] Rename / reorder / delete a playlist on desktop → the phone reflects it.

---

## Phase 4 — Web Audio rebuild (pitch, effects, crop)

Single device (offline preview + a local library):
- [ ] Play a track; move **Pitch** to +7 → melody rises, tempo unchanged. Back to 0 → clean audio again (0 st is an exact passthrough).
- [ ] Pitch at −12 and +12: some granular artifacts are acceptable, but **no dropouts/silence/stutter**; the beat visualizer keeps drawing.
- [ ] **Speed** 1.5× with pitch 0 → no chipmunk effect (preservesPitch still owns speed).
- [ ] **Bass** slider now spans **−10..+20 dB**: at +20 loud but not muddy (300 Hz scoop working); at −10 audibly thinner. Label shows signed values (−10dB … +20dB).
- [ ] **Fx bypass** (rail button) neutralizes speed+pitch+bass+reverb at once; sliders keep their values; volume stays live.
- [ ] **Per-track memory**: set 1.5× / +3 st / +10 dB on song A; play song B → sliders snap to defaults; back to A → sliders *and* audio restore. Relaunch the app, play A → still restored.
- [ ] **Crop editor**: ⋯ → **Crop…** on a YouTube-sourced track → modal with full/cropped durations, seek bar, −5s/⏯/+5s/End transport, Start/End sliders + clickable m:ss chips (inline edit; Enter commits, Esc cancels). Start can't pass End−0.5s and vice versa.
- [ ] Preview **loops inside the crop window**; releasing the Start slider previews from the start; releasing End previews the last 3 s. Editing pauses the main player and resumes it on close.
- [ ] **Reset** restores 0..full; **Apply Crop** on the near-full range removes the crop.
- [ ] After Apply: rail shows the **✂ CROPPED** chip; the progress bar's duration equals the cropped length; playback stops/advances at the crop end.
- [ ] Crop the **currently-playing** track → it restarts inside the new window without a stall.
- [ ] Worklet fallback: temporarily rename `dist/pitchWorklet.js` → app still plays; Pitch slider is disabled; bass/reverb/crop all still work. (Rename it back.)

Two devices (real secret; phone nearby):
- [ ] Set bass **+18** on the phone → desktop applies +18 (old 0..12 clamp is gone). Set −10 on desktop → phone shows −10.
- [ ] Change tracks on desktop while the phone follows → desktop's restored per-track speed/bass/reverb reach the phone; **pitch never appears on iOS** (local-only).
- [ ] Apply a crop on desktop → the phone's copy of the track picks up the same crop (doc round-trip); Reset+Apply clears it on both; the ✂ badge tracks both ways.

---

## Phase 5 — Downloads & discoverability polish

Downloads:
- [ ] Paste a **bare YouTube playlist link** (`youtube.com/playlist?list=…`) → every track downloads; status shows "Track N/M — pct%"; files land tagged `[ytid]` and sync up.
- [ ] Paste a **watch?v=…&list=…** link (specific video inside a playlist) → only that one video downloads (single-track default kept).
- [ ] Paste a **bare Spotify playlist/album link** → clear error pointing at YouTube playlist links (no garbage single download).
- [ ] Single-track YouTube + Spotify track links still download as before.

Lyrics:
- [ ] Open lyrics on a track with none found → "No lyrics found" now has a **Try Again** pill; clicking refetches (watch the Loading… flash). Same on "Instrumental track".

Library & statusline:
- [ ] Library is sorted **case-insensitively by name** (was folder-walk order).
- [ ] With >500 tracks (or a broad search), the list ends with "**Showing 500 of N — search to narrow**".
- [ ] Two tracks with the **same title**: only the one actually playing is highlighted (id match, not name).
- [ ] Statusline shows "Disk renames / moves / deletes sync too" with a tooltip explaining the watched folder.

Keyboard & chrome:
- [ ] **/** (or Ctrl+F) focuses search; **Esc** blurs it. **Esc** closes context menus/popovers, the delete-confirm modal, and the crop sheet (but not while typing in a chip field).
- [ ] Statusline hints list Space/←→/L//" "/Esc/F11 + "media keys".
- [ ] **Fx button**: lit when effects active; **slashed** with tooltip "Effects bypassed — click to re-enable" after clicking it.
- [ ] **Role chip** tooltip: hover "Playing Here" / "Remote" / "Offline Preview" → sensible explanation each.
- [ ] Play a track with a **very long name** → the title scrolls gently back and forth; short names don't move.
- [ ] **Retake `shot-*.png`** screenshots once everything above passes (setup, pairing, session, main — plus the new fx/crop UI if you like).

---

## Audit-2 Phase A — Queue-based playlist semantics (live-iOS parity)

Single device (offline preview):
- [ ] **Play** on a playlist (card ▶, open-header ▶, or menu "Play all") while a song is playing → nothing interrupts; all tracks land in **Up Next**; the button reads **"Play now?"** for ~2 s.
- [ ] Click **"Play now?"** within 2 s → the first playlist track plays immediately; the remaining tracks sit at the **front** of the queue (no duplicates left behind).
- [ ] Same double-tap for **Shuffle / "Shuffle now?"** — the confirm keeps the same shuffled order it queued.
- [ ] Let the 2 s lapse → button returns to ▶ / 🔀; the queued tracks simply stay queued.
- [ ] Starting Play while "Shuffle now?" is pending (or vice versa) resets the other button.
- [ ] **No wrap**: let a queued playlist drain → playback stops at the end (no loop back to the top). The "Up Next from Playlist" section is gone for good.
- [ ] **Loop auto-disables**: turn 🔁 on, then add a song to the queue / queue a playlist / "Play now?" / click a queued row → 🔁 turns off each time (no infinite repeat of one track).
- [ ] **Idle queue starts playback**: with nothing playing, press ＋ on a library row → the song starts immediately instead of parking. Same with playlist Play while idle → first track plays, rest queue.
- [ ] **Prev after playing from the queue**: click a queued row to jump to it, then press ⏮ → you return to the song you left (not a restart).
- [ ] **Click the playing row** (library, open playlist, or queue) → toggles pause/resume; clicking it again resumes. Other rows still play fresh.

Two devices (real secret):
- [ ] Start a playlist from the **desktop** → the **phone's** queue shows every upcoming playlist track; reordering/removing on the phone changes what plays next on desktop.
- [ ] "Play now?" double-tap on desktop while the phone is mid-song → desktop takes over immediately, rest of the playlist queued at the front, phone mirrors.

---

## Audit-2 Phase B — Queue panel parity

Single device (offline preview), with a few songs played and queued:
- [ ] **Previously Played**: after a couple of natural track advances (or ⏭), the Up Next panel shows a muted **Previously Played** divider with the past tracks, oldest at top / most recent at the bottom.
- [ ] Click a **Previously Played** row → it plays; press ⏮ afterward → returns to the song you left (current was pushed onto history first).
- [ ] **Status strip**: while a song is playing, a small "PLAYING FROM QUEUE · N songs" strip sits above the queue; N = previous + current + upcoming, and it updates as songs advance / are queued.
- [ ] **Queue-row context menu**: right-click a queued (resolvable) row → the full row menu (Play / Add to queue / Add to playlist / Rename / Song info / Crop / Redownload / Delete). Ghost rows have no menu.
- [ ] **Drag-to-queue**: drag a **library** row onto the Up Next panel → a dashed drop cue appears; releasing adds it to the queue (hint confirms "Queued …"). Works onto the empty-queue state too.
- [ ] Dragging a **queue** row still only reorders it (the library-drag and reorder gestures don't cross).
- [ ] "Clear" still empties the upcoming queue; the Previously Played list is history and is kept.

---

## Audit-2 Phase C — Downloads parity (per-track playlist/album)

Requires yt-dlp reachable + a music folder. (Static gate covered the parsers; this is the live pass.)
- [ ] **YouTube playlist** (`youtube.com/playlist?list=…`): downloads **one track at a time**; status shows "Track N/M — Downloading… X%". Tracks already in the library are skipped (final line notes "… already had").
- [ ] Kill one track mid-playlist (e.g. an unavailable video) → it lands as its **own row** in the failed panel; the rest keep going (no single aggregate error).
- [ ] Final status reads "Playlist done — X added[, Y already had][, Z failed]" and clears after a few seconds.
- [ ] Re-run the same YouTube playlist → every track is skipped ("All N tracks already downloaded"), nothing re-fetched.
- [ ] **Spotify playlist / album** (`open.spotify.com/playlist/…` or `/album/…`): resolves the set via the public embed page, then downloads each track via `ytsearch1:<artist> - <title>` one at a time. Files land tagged `[ytid]` and sync up.
- [ ] A private/empty Spotify or YouTube set → a clear error in the failed panel (not a crash).
- [ ] The post-download **"add to playlist" prompt does NOT pop** during a batch (only for single-link downloads).
- [ ] Single-track YouTube + Spotify **track** links still download exactly as before, with the duplicate guard and the post-download playlist prompt.

---

## Audit-2 Phase D — Now Playing rail + transport polish

Single device (offline preview), a yt-sourced track playing:
- [ ] **Crop from the rail**: a ✂ button sits in the rail action row; it's dimmed/disabled when nothing local+yt is playing (and in Offline Preview). With a yt track playing on a real session, clicking it opens the crop editor.
- [ ] **Rename current track**: double-click the big Now Playing title → the rename modal opens pre-filled; renaming updates the file + row (and, with a secret, the phone).
- [ ] **fx per-slider reset**: nudge a slider, then **double-click** it → it snaps back to default (Volume 100%, Speed 1.00×, Pitch 0st, Bass 0dB, Reverb 0%).
- [ ] **Reset all**: the link under the sliders resets Speed/Pitch/Bass/Reverb but **leaves Volume** where it is.
- [ ] **Hold ⏪**: a quick click still jumps −10s; press-and-hold scrubs backward (~0.5s every 200ms) until release, stopping at 0:00.
- [ ] **Hold ⏩**: a quick click still jumps +10s; press-and-hold plays at **2×** until you release, then returns to the normal rate (works even with effects bypassed).
- [ ] **>60s pause auto-restart**: pause a track, wait just over a minute, press play → it restarts from the beginning. Pausing briefly (<60s) resumes in place. Seeking while paused, then resuming, honors the seek.

Two devices (real secret):
- [ ] Hold ⏩ on the **owner** → the following device's progress speeds up to match (rate re-published); releasing returns both to normal.
- [ ] On a **follower**, ⏪/⏩ are plain −/+10s (no hold effects) — no command spam.
