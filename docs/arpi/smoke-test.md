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
