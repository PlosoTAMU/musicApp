# Desktop parity — implementation plan (ARPI Plan phase)

Scope: **all** findings in `desktop-parity-findings.md`, strict priority order.
Reference = iOS. Each phase is one reviewable, pushable increment. Item tags in
`[#N]` refer to Part 1 findings; `[U#]` to Part 2 usability issues.

Ground rules (see `README.md`): iOS is the source of truth; do not change Firestore
wire field names; verify by running the app, not just reading the diff.

---

## Phase 1 — Playback control parity + core interaction fixes
Highest impact, lowest architectural risk; the remote engine already supports it.

1. **Real previous-track history** `[#1]` — give `LocalPlayer`/`SyncEngine` a bounded
   history stack pushed on every track change; `prev` pops it (falls back to seek-0
   when empty), mirroring `AudioPlayerManager.previous()`. Owner-side only (followers
   route `prev` through the command bus as today).
2. **Single-click play** `[U1]` — library/playlist/queue rows play on single click;
   keep double-click working; make rows visibly interactive (cursor + hover state).
3. **Full remote control while following** `[#6, U2]` — when `role==="follower"` and a
   remote owner is active: stop blurring the rail; wire play/pause/next/prev/seek to
   the command bus (already have optimistic echo in `toggleCmd`/`seekCmd`); keep
   mirrored progress (`mirrorPositionMs`). Replace the lock card with a small
   "control / play here" affordance. Remove/soften `.rail-content.blurred`.
4. **On-screen seek ±10s** `[#18]` — add rewind/forward-10 buttons to the transport;
   route through `seekCmd` so they work as owner and remote.

**Verify:** launch electron in offline-preview (demo) mode; play a queue, hit
prev/next/seek, single-click rows. For remote: two-client manual check when a real
home secret is available — follower buttons move the owner.

---

## Phase 2 — Library management parity
In-app equivalents of the iOS row/context-menu actions. Sync already carries edits.

5. **Rename** `[#3]` — rename control on library/queue/playlist rows + now-playing;
   writes the file rename through the same path the dir-watch reconcile uses, so it
   round-trips to the cloud (`replicator` reconcile / `updateDoc`). Match iOS naming.
6. **Delete w/ 5s undo** `[#4]` — trash control; optimistic hide + 5s undo window
   before the on-disk delete + tombstone; if the deleted track is playing, stop.
   Mirrors `DownloadManager.markForDeletion`.
7. **Song info** `[#17]` — panel/popover: name, source, yt id, folder, path, crop.
8. **Redownload** `[#13a]` — row action for yt-bearing tracks → re-fetch via `download.ts`.
9. **Duplicate detection** `[#13b]` — before a manual paste-download, check the library
   for the same yt id; block + message like iOS.
10. **Failed-download surfacing** `[#13c]` — collect replicator/manual failures into a
    dismissible list (twin of `FailedDownloadsBanner`), not just a transient line `[U8]`.

**Verify:** rename → file renamed + doc `name` updated; delete → file gone + doc
`deleted:true` + undo restores within 5s; dup paste blocked.

---

## Phase 3 — Queue & playlist parity

11. **Shuffle** `[#2]` — shuffle on play-all + a shuffle control; mirror the iOS
    "queue shuffled order" behavior.
12. **Queue reorder + Clear All** `[#9]` — drag to reorder (persist via `queueSync`
    replaceAll/move op); Clear-All button.
13. **Playlist management** `[#10]` — rename, reorder tracks (persist to playlist doc),
    show cover art (first track thumb) + count + total duration.
14. **Add-to-playlist picker + post-download prompt** `[#11]` — from any row / now-playing,
    choose a playlist (not only the open one); after a download completes, prompt to add.
15. **Playlist delete confirm** `[U4]` — confirmation (or undo) before tombstoning.
16. **Playlist-mode wrap/interleave** `[#7]` — match iOS: play past the queue, wrap at end,
    interleave user-queued songs; distinguish "Up Next" vs "Up Next from Playlist".
17. **Empty-queue hint** `[U11]` — desktop-correct wording.

**Verify:** reorder persists to Firestore + survives reload; picker adds to the chosen
playlist; delete asks first; playlist plays past its queue and wraps.

---

## Phase 4 — Web Audio rebuild (foundational: pitch, effects, crop)
Pitch-shift is impossible on a bare `HTMLAudioElement`. Rebuild `LocalPlayer` onto the
Web Audio graph `beat.ts` already taps, then hang effects/pitch/crop off it.

18. **Consolidate playback on one Web Audio graph** — single `MediaElementSource` →
    effect chain → analyser (beat) → destination; `beat.ts` reads from it instead of
    owning a parallel graph.
19. **Real bass range aligned to iOS** `[#14]` — slider −10..+20 dB; fix
    `settingsSync.onRemote` clamp to −10..20 so phone values survive.
20. **Pitch shift ±12 st** `[#8]` — vendored offline pitch shifter (soundtouch-style /
    phase vocoder), independent of speed; add slider + settings sync field ONLY if iOS
    already syncs pitch — otherwise keep local (confirm against `SettingsSync.swift`
    fields: currently speed/bassDb/reverbPct — pitch is NOT synced, so keep desktop
    pitch local to match).
21. **Per-track effect memory** `[#15]` — persist speed/pitch/reverb/bass per track id;
    restore on play; mirror `AudioPlayerManager.TrackSettings`.
22. **Crop editor + CROPPED badge** `[#5, U7]` — editor with start/end sliders + preview
    (second throwaway `<audio>`, like iOS's throwaway AVAudioPlayer); write
    `cropStartMs`/`cropEndMs` to the library doc (fields already consumed by `cropFor`);
    show a badge on cropped tracks.

**Verify:** pitch audibly independent of speed; bass +20/−10 from phone applies; crop
writes the doc + shortens playback + badge shows; per-track settings restore on replay.
**Risk gate:** if the pitch/graph rebuild balloons, stop and re-plan per NOTES (§ Failure).

---

## Phase 5 — Downloads & discoverability polish

23. **Playlist-URL downloads** `[#12]` — detect bare playlist/album links (as iOS
    `isBarePlaylistURL`) and drop `--no-playlist` for those; keep single-track default.
24. **Lyrics "Try Again"** `[#16]` — retry button on the no-lyrics/failed state.
25. **500-row cap indicator** `[U6]` — "showing 500 of N".
26. **File-edit discoverability** `[U5]` — statusline/help note that on-disk rename/move
    /delete syncs (until in-app covers it fully).
27. **Local artwork for folder imports / offline** `[artwork]` — extract embedded art or
    a placeholder for non-yt files (low priority; may defer per NOTES OPEN).
28. **Library sort by name** `[sort]` — case-insensitive, matching iOS.
29. **UX cleanup** — complete keyboard hints incl. Esc + media keys + focus-search `[U10]`;
    effects-bypass label/slash state `[U9]`; role-chip tooltip; refresh `shot-*.png`;
    fix name-based "playing" highlight to match by id `[U12]`; title marquee `[cosmetic]`.

**Verify:** playlist URL fetches N tracks; retry refetches; UI review of each item.

---

## Cross-cutting verification & tracking
- Progress + decisions tracked in `../../NOTES.md` (update before risky ops).
- No phase is "done" until the app has been run on the changed flow.
- Firestore-touching changes: read the doc back when a real secret is available; else
  assert the payload in review and exercise the offline-preview path.
