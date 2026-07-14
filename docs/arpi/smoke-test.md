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
