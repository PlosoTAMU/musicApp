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
- 2026-07-14 P3 item 16 DONE (faithful iOS, approach A): playlist is now owner-local (playlistLoop + playlistIndex, not synced). playAll no longer dumps the remainder into the shared queue; trackEnded drains the shared user-queue first (interleave) then advances the playlist by (i+1)%len. Up Next split into user queue + owner-only "Up Next from Playlist" (rows jump via playFromPlaylist). Tradeoff accepted: playlist mode doesn't survive cross-device handover (= iOS). Spec: `docs/superpowers/specs/2026-07-14-desktop-playlist-interleave-design.md`.
- 2026-07-14 P4 pitch = hand-rolled streaming WSOLA granular shifter in an AudioWorklet (pitchShifter.ts core + pitchWorklet.ts entry), NOT vendored soundtouch-js — the npm worklet build wants a decoded buffer, not a MediaElementSource stream; the pure core is Node-testable. Pitch is LOCAL-only (iOS doesn't sync it) and adds ~95 ms latency only while active (0 st = exact passthrough).
- 2026-07-14 P4 graph ownership moved beat.ts → audioGraph.ts (src → pitch → EQ×5 → analyser → dry/wet → dest, twin of the iOS chain); BeatFeed only binds the analyser. Speed stays on the element (playbackRate + preservesPitch) so follower rate extrapolation is untouched. Worklet loads from a Blob URL (fs read) — file:// module fetch is CORS-hostile; load failure degrades to a disabled pitch slider.
- 2026-07-14 P4 crop editor gated to yt-bearing tracks — crop lives on the yt-keyed library doc; local-only files have no doc to carry it. Known parity edge, recorded here.

## ASSUMPTIONS
- [unconfirmed] Firestore doc contracts stay frozen; parity work must not change wire field names (they are the cross-platform contract — see SettingsSync.swift header).
- [confirmed] A pure-JS pitch shifter can be vendored offline: P4 hand-rolled one (pitchShifter.ts), verified by Node sine tests; no CDN, no npm dep.
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
- **Phase 3** (queue & playlist parity): playlist shuffle (Shuffle all) [#2]; queue drag-reorder + Clear-All + click-queued-to-play [#9]; playlist rename/track-reorder/cover-art/count·duration [#10]; add-to-playlist picker from any row + now-playing rail + post-download prompt [#11]; playlist delete confirm [U4]; playlist mode — interleave + wrap + Up Next split (owner-local `playlistLoop`+index) [#7]; empty-queue hint [U11]. New pure `listOps.ts` (shuffle/fmtDuration/moveIndex). Fixed a queue-reorder tail bug (see DECISIONS). Gate: tsc+bundle green; Phase-3 logic 39/39 PASS.
- **Phase 4** (Web Audio rebuild): one graph in new `audioGraph.ts` [18]; bass −10..+20 dB with iOS 5-band shaping + settingsSync clamp fix [#14/19]; pitch ±12 st via vendored WSOLA AudioWorklet, local-only [#8/20]; per-track fx memory `trackFx.ts` [#15/21]; crop editor `cropSheet.ts` + replicator.setCrop + ✂ CROPPED badge [#5/22]. New pure `fxMath.ts` + `pitchShifter.ts`. Gates: tsc + both bundles green; logic 23/23 (fxMath) + 8/8 (pitch DSP: 440→880/220/659 Hz ±5%, exact 0-st passthrough) + 6/6 (trackFx) PASS. GUI smoke deferred to user (smoke-test.md Phase 4).

## OPEN  (unanswered / deferred / known issues)
- How to verify Firestore-touching changes offline: use `--btn-demo` (offline preview) path for playback UX; sync writes verified by reading back the doc only when a real home secret is available.
- Crop on local-only (no yt) files: no cloud doc to carry the window — deferred unless the user wants a local-crop store.
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
