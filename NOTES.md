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

## OPEN  (unanswered / deferred / known issues)
- Pitch-shift library choice (vendored soundtouch-js vs. hand-rolled) — decide at P4 start.
- Crop editor on desktop needs a preview player that doesn't fight the main player (iOS uses a throwaway AVAudioPlayer) — mirror that with a second <audio>.
- How to verify Firestore-touching changes offline: use `--btn-demo` (offline preview) path for playback UX; sync writes verified by reading back the doc only when a real home secret is available.
- Local artwork for folder-imported files (no yt id) — desktop currently only has i.ytimg thumbs; may need on-disk embedded-art extraction (deferred to P5, low priority).

## RULED OUT  (approaches abandoned + why)
- (none yet)

## VERIFY STRATEGY
- Playback/UX: launch electron via the app's run path in offline-preview (demo) mode, drive the flow, watch it.
- Sync writes: read the Firestore doc back after the action (only with a real secret); otherwise assert the local intent + doc payload in code review.
- Never claim a phase done without running the app on the changed flow (per verification-before-completion).
