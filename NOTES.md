# NOTES — Desktop parity effort (ARPI)

State file for the desktop↔iOS feature-parity work. Read this FIRST on resume
(before re-reading source). Authoritative summary of prior sessions. Keep terse,
keep < ~100 lines. Full detail lives in `docs/arpi/`.

## GOAL
Bring the Electron desktop app (`desktop/`) to feature parity with the iOS app
(`musicApp/`), then make every feature visible + usable on desktop. Scope = ALL
audit findings (see `docs/arpi/desktop-parity-findings.md`), strict priority order.

## DECISIONS  (append-only, why in one line)
- 2026-07-14 Branch `arpi/desktop-parity` off main — keep main clean, user pushes.
- 2026-07-14 Scope = "everything, strict priority order" incl. Web Audio rebuild — user chose.
- 2026-07-14 Remote control = "full remote" (unblur rail, wire mirror transport) — user chose.
- 2026-07-14 Web Audio rebuild is a foundational phase (P4) — pitch-shift is impossible on bare HTMLAudioElement; effects/crop ride the same graph.
- 2026-07-14 Bass range: align desktop UP to iOS −10..+20 dB and fix the settingsSync clamp — iOS is the reference twin.
- 2026-07-14 iOS side is the source of truth for behavior; desktop mirrors it (README calls desktop the "twin").
- 2026-07-14 Verify cadence = BATCH: implement all phases with static+logic gates, user does one GUI pass at end. Per-phase smoke checklists accumulate in `docs/arpi/smoke-test.md`.
- 2026-07-14 P1 prev-history: built only by trackEnded (natural advance / "next"), NOT by direct clicks — mirrors iOS previousQueue. prev re-queues current at front via queue `insert afterId:null`.
- 2026-07-14 P1 remote control: dropped the blur+cover lock; rail transport already routes through the command bus, so following devices now control the owner directly + a `#remote-banner` shows state + Play Here.
- 2026-07-14 P3 playlist mode = WRAP-ONLY on desktop. `playAll` dumps the remainder into the shared (Firestore) queue and arms an owner-local `playlistLoop`; on drain it wraps to the top — twin of iOS `next()`'s `(i+1)%count`. Interleave (queued songs play *before* the playlist continues) + the "Up Next / Up Next from Playlist" split are NOT ported: iOS keeps a separate local `userQueue`; matching it needs a dual-queue that conflicts with the frozen single shared-queue contract. Deferred (see OPEN), pending user call.
- 2026-07-14 P3 queue reorder bug caught by the logic gate: dropping a row onto the row *directly below* it made rebase(move) anchor to the just-removed row → item flung to tail. Guarded with an adjacent-below no-op (matches `moveIndex`'s playlist behavior).
- 2026-07-14 Pure list logic (shuffle / fmtDuration / moveIndex reorder) split into `desktop/src/listOps.ts` so it's Node-testable without a DOM — same pattern as P2's `urls.ts`.

## ASSUMPTIONS
- [unconfirmed] Firestore doc contracts stay frozen; parity work must not change wire field names (they are the cross-platform contract — see SettingsSync.swift header).
- [unconfirmed] A pure-JS pitch shifter (SoundTouch-style / phase vocoder) can be vendored offline; no CDN (Electron renderer, but nodeIntegration on so npm dep is fine).
- [confirmed] `beat.ts` already taps the <audio> element via a Web Audio MediaElementSource — P4 consolidates onto that graph rather than adding a second one.
- [confirmed] Engine command-bus already supports follower→owner control; remote-control work is UI-side (ui.ts render + controls), not protocol.

## DONE
- Full audit of iOS + desktop surfaces. Findings → `docs/arpi/desktop-parity-findings.md`.
- ARPI plan (phases + verification) → `docs/arpi/desktop-parity-plan.md`.
- ARPI process doc → `docs/arpi/README.md`.
- Branch + this NOTES.md.
- Build baseline green (tsc --noEmit + esbuild bundle) @ 9658ab8; verification constraint recorded @ 2896674.
- **Phase 1** (playback control parity): prev-track history (engine.ts), single-click play (ui.ts rowClick), full remote control (index.html + ui.ts, unblur + banner), on-screen seek ±10s. Gate: tsc+bundle green; `rebase` logic 11/11 PASS. Smoke checklist in smoke-test.md.
- **Phase 2** (library management): rename/delete(5s undo)/song-info/redownload via a reusable context menu (right-click + ⋯), duplicate detection, failed-downloads panel, text-input modal (Electron has no window.prompt). New pure `urls.ts` (extractYtId + isBarePlaylistURL). FS edits reconcile to cloud like startDownload. Gate: tsc+bundle green; urls logic 14/14 PASS.
- **Phase 3** (queue & playlist parity): playlist shuffle (Shuffle all) [#2]; queue drag-reorder + Clear-All + click-queued-to-play [#9]; playlist rename/track-reorder/cover-art/count·duration [#10]; add-to-playlist picker from any row + now-playing rail + post-download prompt [#11]; playlist delete confirm [U4]; playlist-mode WRAP (owner-local `playlistLoop`) [#7, partial — interleave/split deferred]; empty-queue hint [U11]. New pure `listOps.ts` (shuffle/fmtDuration/moveIndex). Fixed a queue-reorder tail bug (see DECISIONS). Gate: tsc+bundle green; Phase-3 logic 39/39 PASS.

## OPEN  (unanswered / deferred / known issues)
- **[USER DECISION] P3 item 16 interleave/split.** Desktop ships wrap-only (see DECISIONS). Full iOS parity = queued songs interleave to play *next* + "Up Next" vs "Up Next from Playlist" UI split. Needs a local user-queue overlay on top of the shared queue (would also change what followers see as "up next"), OR accept the wrap-only deviation. Awaiting user call before Phase 4.
- Pitch-shift library choice (vendored soundtouch-js vs. hand-rolled) — decide at P4 start.
- Crop editor on desktop needs a preview player that doesn't fight the main player (iOS uses a throwaway AVAudioPlayer) — mirror that with a second <audio>.
- How to verify Firestore-touching changes offline: use `--btn-demo` (offline preview) path for playback UX; sync writes verified by reading back the doc only when a real home secret is available.
- Local artwork for folder-imported files (no yt id) — desktop currently only has i.ytimg thumbs; may need on-disk embedded-art extraction (deferred to P5, low priority).

## RULED OUT  (approaches abandoned + why)
- (none yet)

## VERIFY STRATEGY
- ENV CONSTRAINT (2026-07-14): this dev box has NO display server (no Xvfb, cannot install). Electron GUI cannot be launched/screenshotted here. So:
  - Static gate every change: `npx tsc --noEmit` + `npm run bundle` must stay green. (Baseline: both green at commit 9658ab8.)
  - Logic gate for DOM-free code (history stack, shuffle, queue ops, dup detection, crop math, resolve/parseLRC/positionAt): Node test scripts bundled via esbuild, run with node.
  - GUI smoke-test per phase is DEFERRED TO THE USER's machine (has a display). Each phase ships with an explicit "smoke-test checklist" for them.
- Sync writes: read the Firestore doc back after the action (only with a real secret); otherwise assert the payload in review.
- Never mark a phase "done" (vs "code-complete, GUI-unverified") without either a Node logic test or the user's GUI smoke-test.
