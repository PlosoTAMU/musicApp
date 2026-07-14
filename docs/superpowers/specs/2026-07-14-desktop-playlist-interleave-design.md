# Desktop playlist interleave + Up Next split — design

Item 16 of the desktop↔iOS parity effort (see `docs/arpi/desktop-parity-plan.md`
Phase 3, finding #7). Phase 3 shipped playlist **wrap** (`arpi P3`, commit
`9908842`); this closes the remaining two behaviors: **interleave** (manually
queued songs play *before* the playlist continues) and the **"Up Next" vs
"Up Next from Playlist"** UI split.

## Goal

Match iOS `AudioPlayerManager` playlist-mode behavior on the desktop:

1. A song added to the queue while a playlist is playing plays **next**, ahead of
   the rest of the playlist — not after it.
2. The Up Next panel distinguishes user-queued songs ("Up Next") from the
   upcoming playlist tracks ("Up Next from Playlist").

## Reference — the iOS model (source of truth)

`musicApp/AudioPlayerManager.swift` + `musicApp/Sync/PlaybackSyncEngine.swift`:

- **The synced session queue *is* the user queue.** `PlaybackSyncEngine.handleRemote`
  maps `state.queue` straight onto `player.queue` (AudioPlayerManager's user queue),
  and local `player.queue` edits are pushed back via `queueSync.apply(.replaceAll)`.
- **`currentPlaylist` is never synced** — it is owner-local. Followers therefore
  never see the playlist remainder, and playlist mode does not survive handover.
- **`next()`** (`AudioPlayerManager.swift:1532`): if `!queue.isEmpty` play
  `queue.removeFirst()` (interleave); else if playlist mode
  `currentIndex = (currentIndex+1) % currentPlaylist.count`; else stop.
- **`loadPlaylist`** (`:631`): sets `currentPlaylist`, `currentIndex = 0`, plays
  `[0]`. Does **not** clear the user `queue`.
- **`play(_:)`** (`:815`): whenever a played track is in `currentPlaylist`,
  `currentIndex` is set to its index.
- **`upNextTracks`** (`:1556`) = `queue` ++ `currentPlaylist[currentIndex+1...]`;
  **`playlistUpNextTracks`** (`:1571`) = `currentPlaylist[currentIndex+1...]`.
- **`clearQueueAndExitPlaylist`** (`:1670`): clears `queue`, exits playlist mode.

## Chosen approach — faithful iOS (approach A)

The desktop shared (Firestore) queue already **is** the cross-device user queue
(`queueLocal`/`queueRemove`/`queueMove` operate on it). So the port is mostly a
**simplification** of the current desktop code: stop dumping the playlist
remainder into the shared queue (Phase 3's wrap model did), and instead keep the
playlist owner-local with an index — exactly as iOS keeps `currentPlaylist`.

Rejected — approach B (keep the remainder in the shared queue + a locally-tracked
boundary for interleave): the boundary can't be persisted (the queue wire format
is a frozen cross-platform contract) so it desyncs under concurrent/cross-device
queue edits. More code, more fragile, and it preserves a behavior (playlist
survives handover) iOS never had.

### Accepted tradeoff

Playlist mode becomes owner-local: followers see only the user queue, and a
cross-device handover hands over the user queue but ends playlist mode. This
matches iOS exactly. It is a change from Phase 3's wrap model, where the
remainder lived in the shared queue and thus survived handover.

## Component changes

### 1. Engine (`desktop/src/engine.ts`)

State:
- Keep `playlistLoop: LocalTrack[] | null` (owner-local; set only by `playAll`,
  and only on the owner since `playAll` → `playLocal` takes over first).
- Add `playlistIndex = 0`.

Methods:
- **`playAll(ts)`** — play `ts[0]` (via `playLocal`, which takes over + nulls the
  old loop), then `playlistLoop = ts; playlistIndex = 0`. **Do not** write the
  remainder to the shared queue. The shared (user) queue is left untouched, so any
  already-queued songs interleave — iOS `loadPlaylist` does not clear it either.
- **`trackEnded()`** — unchanged at the top: it already drains the shared-queue
  heads first (CAS `consumeHead`, ghost-skip). That IS the interleave. The
  drained-queue branch changes from "restart at `list[0]` + `replaceAll` refill"
  to: `playlistIndex = (playlistIndex+1) % playlistLoop.length;` then
  `play(playlistLoop[playlistIndex])` — no queue write.
- **Index sync** — a small helper `notePlaylistPos(t)` sets `playlistIndex` to
  `t`'s index in `playlistLoop` when present. Called where a track that may belong
  to the playlist is played out of sequence: the `trackEnded` queue-head branch and
  `goPrevious`. Twin of iOS `play(_:)` maintaining `currentIndex`; prevents a
  just-played playlist track from replaying immediately on the next advance.
- **`playLocal(t)` / `clearQueue()`** — additionally reset `playlistIndex = 0`
  (they already null `playlistLoop`).
- **Ownership loss** — null `playlistLoop` (and reset index) when this device stops
  being owner, so a demoted owner holds no stale playlist. (UI also gates on role;
  this is belt-and-suspenders. Exact hook located during implementation.)

Exposed to the UI:
- `get inPlaylistMode(): boolean` → `!!this.playlistLoop`.
- `get playlistUpNext(): LocalTrack[]` → `playlistLoop ? playlistLoop.slice(playlistIndex+1) : []`.

### 2. UI (`desktop/src/ui.ts`, queue panel in `renderLibrary`)

- Render the shared queue as today's **"Up Next"**. Then, only when
  `coord.role === "owner"` and `engine.playlistUpNext.length > 0`, render a second
  read-only **"Up Next from Playlist"** section (thumb + title rows). Playlist rows
  are not draggable/removable (they are derived from `playlistLoop`, not the user
  queue). Clicking to jump into the playlist is **out of scope** for this change.
- Empty-state / Clear button react to either source: show the panel when the shared
  queue is non-empty **or** `engine.inPlaylistMode`; the `Clear` button
  (→ `engine.clearQueue()`, which exits playlist mode) is visible in both cases.
  The existing "Queue is empty" hint shows only when the shared queue is empty
  **and** not in playlist mode.
- Followers need no special-casing: `playlistLoop` is owner-local, so
  `playlistUpNext` is empty on a follower.

## Data flow (owner, playlist `[P0,P1,P2]`, user queues `U` after `P0` starts)

```
playAll([P0,P1,P2])  → play P0; playlistLoop=[P0,P1,P2]; playlistIndex=0; shared queue unchanged
queueLocal(U)        → shared queue = [U]           (Up Next: [U];  from-playlist: [P1,P2])
P0 ends → trackEnded → shared queue non-empty → play U, consume head → shared queue = []
U ends  → trackEnded → shared queue empty → index=1 → play P1
P1 ends → index=2 → play P2
P2 ends → index=0 → play P0   (wrap)
```

## Testing

Verification constraint (this box has no display) still applies: static gate +
Node logic gate here; GUI smoke deferred to the user's machine.

- **Static gate:** `npx tsc --noEmit` + `npm run bundle` stay green.
- **Logic gate (Node, bundled via esbuild):**
  - `nextPlaylistIndex(i, len)` — new pure helper in `listOps.ts` (shipped, used by
    the engine's playlist branch); wrap arithmetic.
  - **Interleave sequence test:** a pure `advance({queue, playlist, index})`
    simulator that mirrors `trackEnded`'s decision (queue-first, else
    `nextPlaylistIndex`, else end). It lives **in the test file only** (the engine
    does not consume it — no dead code shipped) and asserts the emitted order for
    representative sequences (empty queue, interleaved user songs, wrap, and a
    playlist track that is also user-queued). Documents item 16's intended order.
- **GUI smoke (`docs/arpi/smoke-test.md`, Phase 3):** replace the "known gap" note
  with: queue-a-song-while-a-playlist-plays → it plays **next**; Up Next shows two
  labeled sections; a follower shows only the user queue; Play-Here/handover ends
  playlist mode.

## Out of scope

- Clicking an "Up Next from Playlist" row to jump to that track.
- Persisting/synchronizing the playlist across devices (iOS doesn't; contract-frozen).
- Any change to the queue wire format.

## Files touched

- `desktop/src/engine.ts` — playlistIndex, playAll, trackEnded, getters, index sync.
- `desktop/src/ui.ts` — two-section Up Next, empty/Clear gating.
- `desktop/src/listOps.ts` — `nextPlaylistIndex` (the `advance` test model stays in the throwaway test file).
- `docs/arpi/smoke-test.md` — Phase 3 checklist update.
- `NOTES.md` — mark item 16 complete; retire the OPEN/deferred entry.
