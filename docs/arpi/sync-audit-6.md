# Audit 6 — up-next tap, library re-download, playback transfer, remote progress, thumbnails, beat detection

2026-09-13. Six user reports in one pass. Same environment as audits 3–5: no
Swift toolchain, no display server. TS half gated by `tsc --noEmit` + bundle +
`tests/run.js` (new `audit6-sync.test.ts`, 35 assertions); Swift half by
line-by-line review against its TS twin. GUI pass is the user's —
`smoke-test.md` → "Audit 6".

---

## Task 1 — Up Next strip opens the queue

`NowPlayingView.upNextStrip` now sets `showUpNext = true` instead of
skipping to the next track; `skipToNext` and the `list.bullet` top-bar
button are gone (five buttons after the chevron). With nothing queued the
strip keeps its exact footprint (a 34 pt clear spacer where the art was),
reads "No songs left" in the dim tone, and still opens the sheet. Trailing
glyph is `list.bullet` so it reads as "open the list", not "skip".

## Task 2 — "my phone tried to download all the songs it already has"

Read end to end: `LibraryReplicator.swift`, `replicator.ts`, `player.ts`
(scan/resolve/norm), `libraryMeta.ts` (new), the DownloadManager hooks
(`findDuplicateByVideoID`, `startBackgroundDownload`, `applyRemoteMeta`,
`removeDownloadFromSync`, `loadDownloads`, `renameDownload`, `redownload`),
`SyncSessionManager.attachReplication`, and the desktop start/folder/forget
flows in `ui.ts`. I could not read the user's Firestore (no secret here), so
the exact trigger is inferred; every defect below is real in the code and
each one alone explains part of the report. Fixed, in order of likelihood:

**L1 (desktop, blocker) — up-sync ran against an EMPTY cloud map on every
launch.** `ui.ts` calls `replicator.syncUp()` right after `start()`. The
library listener's first snapshot is a network round trip (desktop Firestore
has no persistence cache), so the first pump saw `meta` empty and mirrored
every local file as a NEW doc under its path id — a full `setDoc` (crop and
`metaBy` overwritten with disk metadata) and, for songs whose doc the phone
had minted, a DUPLICATE doc. Each launch re-minted the first N files
(however many `setDoc` round trips fit before the snapshot). Fix: `ready`
flag, set by the first snapshot; `pump()` is a no-op before it. Twin on iOS
(L4).

**L2 (desktop, blocker) — a folder switch or an empty scan tombstoned the
whole library.** `reconcile()` treats "doc has a shadow entry but no local
file" as "user deleted it on disk" → tombstone. The shadow was keyed only
by yt, so picking a different music folder (`btn-library`), or one scan of
an unmounted/empty folder, read EVERY known song as deleted: the phone
applied every tombstone (`removeDownloadFromSync` deletes the file), and
when the desktop's files were visible again the up-sync "revived" every doc
— which the phone then re-downloaded in full. This is the one chain that
produces "download all the songs it already has from the computer"
verbatim. Fix: the shadow is scoped to the folder it was recorded against
(`sync.meta.shadow.dir`; a different folder resets it, like forgetHome),
and an empty scan never tombstones.

**L3 (iOS, blocker) — Spotify-pasted tracks were invisible to the yt
identity check.** `findDuplicate` called `findDuplicateByVideoID(source:
.youtube)`, which filters on `source`. A track pasted as a Spotify link is
stored with `source: .spotify` and `videoID` = the YouTube id after
conversion — exactly the `yt` the cloud doc carries — and never matched.
The fallback name comparison then decided: any doc whose name differed from
the local one (desktop-minted doc, a rename there) meant a re-download of a
song already on the phone. Fix: new `DownloadManager.download(forVideoID:)`
(source-agnostic) wired into the replicator.

**L4 (iOS, medium) — upload pump before the first snapshot minted
duplicates.** `upload()` matches an existing doc by yt/name against `meta`;
with `meta` still empty it fell through to "does a doc with MY UUID exist"
— no, for anything the desktop had minted — and created one. Fix:
`snapshotReady` gate on `pumpUploads`, released by the first snapshot.

**L5 (both, medium) — duplicate docs had no rule.** Once two live docs carry
one yt (L1/L4 made these routinely), desktop `reconcile` applied doc A's
name, then doc B's, every pump — a rename loop on disk, mirrored on the
phone through `applyRemoteMeta`. A tombstone on either doc deleted the
file on the other device although the song was still live under the other
doc. Fix, both ends: one CANONICAL doc per yt (latest `metaAt`, tie →
smaller docId; `libraryMeta.ts canonicalByYt` / `LibraryReplicator.
canonicalDocId`). Metadata/crop/download decisions read the canonical doc
only; a tombstone applies only when NO live doc remains for the yt; iOS
`pushTombstone` tombstones every live doc for the yt. Desktop (metadata
authority) also cleans up: merges a loser's crop into the winner if the
winner has none, then DELETES the loser — a removed doc is harmless on
either build of the phone (it just leaves its map).

**L6 (both, medium) — the name fallback used two different lenses.** Desktop
compared through the Windows-illegal-char lens (`? → _`); iOS
`neutralizeName` turns `_` into a space and deletes `* ~ \` #`. yt-dlp
titles carry all of those, so "Song_Name" vs "Song Name" or "A*B" vs "A_B"
never matched — a re-download whenever yt couldn't settle it (L3). Fix: one
key on both ends, letters + digits only, lowercased (`nameKey` /
`SyncNames.key`), used by the replicators AND the resolver's last rung; an
empty key never matches. Pinned by the new test.

**L7 (iOS, low) — three code paths rebuilt `Download` through `init` and
dropped fields.** `loadDownloads` (every launch), `renameDownload`,
`redownload`: `folderOverride`, the Spotify/YouTube provenance, and
`thumbnailFetchFailedAtMs` were lost — so the thumbnail-failure backoff
never held (a permanently missing thumbnail re-fetched on every launch)
and the desktop's folder was re-applied and re-saved on every connect.
`name`/`url` are now `var`; the three paths mutate in place. `renameDownload`
also no longer regresses a `<videoID>.jpg`-keyed record to the legacy
audio-filename key.

**L8 (iOS, low) — `pumpDownloads` skipped a queued item only when the
canonical doc was `deleted`.** With canonical never being a tombstone, a yt
whose live docs all died since it was queued would have downloaded. Now
skips when no live doc remains.

Not changed, noted: `handleFailures` resets `downFails` for every finished
track (harmless); desktop `hasLocally` still accepts a name-only match (by
design — two different videos with one title dedupe to one file).

## Task 3 — switch playback in both directions

Before: phone → "Switch playback to this iPhone" (follower only), desktop →
"Play Here" (follower only). Nothing let the OWNER push playback away.

Design: the existing Bluetooth beacon slot `handoff {by, atMs}` gains an
optional `transfer: true`. The owner writes it (`postTransfer`, plain
write, self-expiring at 60 s). Any follower that sees a fresh transfer
beacon and can resolve the track claims the seat through the normal
`takeOverHere(forcePlay: wasPlaying)` — continuity math unchanged — and the
takeover transaction now REQUIRES the beacon to still be present when it
claims (`takeOver(requireHandoffFrom:)`): the takeover deletes the beacon,
so a second follower answering the same beacon gets `.seatTaken` instead of
deposing the first. The old owner is deposed as usual (audio pauses there,
continues here). A beacon nobody claims within 12 s is retracted
(`cancelTransfer`, fenced on it being ours) and the UI says "No other
device answered — is the app open there?" — a backgrounded follower has no
listener and cannot answer. One claim per beacon per device
(`answeredTransferAtMs`), so a failed claim doesn't retry every snapshot.
Bluetooth consumers are untouched (a transfer beacon also satisfies them,
same intent).

UI: iOS Now Playing shows "Switch playback to other device" (owner, home
connected, track loaded) in the slot the remote pill uses; desktop's rail
banner is now the handover strip in both directions ("Playing on this
computer · Play on other device" as owner; unchanged as follower).

Wire: `handoff.transfer` (optional bool) — additive. Old builds ignore it.

## Task 4 — remote progress bar after ⏮

Root cause: the desktop publishes the instant it swaps `src`, before the
element knows its duration, so the first frame of a track change carries
`dur: 0`; the `durationchange` republish (audit-5 S1) follows 100–500 ms
later, and Firestore delivers the two as one snapshot or two. When two, the
phone's slider range collapsed to `0…max(0,1)`, the handle jumped to the
END of the track, the countdown read a negative time, and it snapped back
on the second frame — "sometimes bugs when I go back a song". Fix, both
ends: (owner) `snapshot()` publishes the last known length of the same
track when the element reports 0 — ⏮ is always a track played moments
ago; (follower) `mirrorDurationMs` / `mirrorDurMs()` fall back to the last
non-zero length seen for the same track id; the phone's remaining-time
label shows "-:--" while the length is unknown instead of a negative
count. Pinned by `knownDurationMs` cases in the new test.

## Task 5 — Up Next / mini player thumbnails

The resolver (`artworkPath(for:)`) is shared and correct; the remaining
defects were view-side:

- **Mini player drew the previous song's art under the new title.** The
  thumbnail view is re-keyed by track id (a fresh view per song), but its
  path came from `cachedThumbnailPath`, refreshed in `onChange(of:
  activeTrack?.id)` — which runs AFTER the render that created the new
  view. That render handed the new view the OLD path: an instant cache
  hit, so the previous song's art showed until the re-resolve one pass
  later (then a placeholder while the new file decoded). The cache is now
  keyed by the track it was resolved for and ignored on the mismatching
  pass (one inline stat per track change).
- `UpNextRow` resolved through `getDownload(byID:)?.artworkPath` — a
  placeholder for imported files with no record — and its rows are
  index-keyed, so the image is now re-keyed on the track id and uses the
  shared resolver.
- `EdgeVisualizerView` sampled bar colors through the audio-URL lookup
  only, which misses renamed/synced tracks (white bars next to colored
  art); it now receives the path Now Playing already resolved.
- `AsyncThumbnailView` completions are generation-checked, so a slower
  decode of an earlier path can never paint over a newer one.
- L7 above (rename regressing the thumbnail key; failure backoff dropped).

## Task 6 — beat detection review (no code change)

See the session summary; short version: the thumbnail pulse is a bass
loudness follower, the beat detector only modulates bar height; no tempo
model; 44.1 kHz assumed in the bin map; reactive by ~80–100 ms. Recommended
order: beat-driven pulse envelope → log-compressed low-band onset function
with a median threshold → tempo/phase tracking with scheduled pulses → then
a tap-trained classifier if taste still differs.

## Wire-contract changes

`handoff.transfer` (optional bool, additive). Library docs: none; the
desktop now DELETES duplicate library docs (removed docs were always
handled by both ends).
