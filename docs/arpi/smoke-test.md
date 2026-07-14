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
