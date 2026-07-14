# Desktop Playlist Interleave + Up Next Split — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Electron desktop app match iOS playlist-mode: manually-queued songs interleave (play *next*, before the playlist continues), and Up Next splits into "Up Next" (user queue) + "Up Next from Playlist" (upcoming playlist tracks, clickable).

**Architecture:** The shared (Firestore) queue already *is* the cross-device user queue. Keep it that way and make the playlist owner-local: `SyncEngine` holds `playlistLoop` + `playlistIndex` (not synced, like iOS `currentPlaylist`/`currentIndex`). `trackEnded` drains the shared queue first (interleave), then advances the playlist by index and wraps. This *removes* Phase 3's "dump the remainder into the shared queue" code. Spec: `docs/superpowers/specs/2026-07-14-desktop-playlist-interleave-design.md`.

**Tech Stack:** TypeScript, Electron renderer (nodeIntegration on), esbuild bundle, Node for logic tests. No new dependencies.

## Global Constraints

- **iOS is the source of truth for behavior** (`musicApp/AudioPlayerManager.swift`); desktop mirrors it.
- **Do not change the Firestore/queue wire format** — field names are the frozen cross-platform contract (`desktop/src/protocol.ts` header). The playlist is owner-local and never synced.
- **No display on the build box:** verification per change = `npx tsc --noEmit` green **and** `npm run bundle` green; DOM-free logic gets a Node test bundled via esbuild. GUI smoke is deferred to the user's machine.
- All shell commands run from `desktop/` unless stated. The logic-test bundle goes to `$CLAUDE_JOB_DIR/tmp` (never committed).
- Commit messages end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## File Structure

- `desktop/src/listOps.ts` — **modify**: add pure `nextPlaylistIndex(i, len)`.
- `desktop/src/engine.ts` — **modify**: `playlistIndex` state, `inPlaylistMode`/`playlistUpNext` getters, `notePlaylistPos`, `playFromPlaylist`; rewrite `playAll`/`trackEnded` drained-branch; reset index in `playLocal`/`clearQueue`; index-sync in `goPrevious`; clear playlist on ownership loss in `handleRemote`.
- `desktop/src/ui.ts` — **modify**: render the "Up Next from Playlist" section (owner-only, clickable rows); empty-state / Clear-button gating on `inPlaylistMode`.
- `docs/arpi/smoke-test.md` — **modify**: replace the Phase-3 "known gap" note with interleave/split/jump/handover checks.
- `NOTES.md` — **modify**: mark item 16 complete; retire the OPEN deferral; add a DECISION.
- Throwaway: `desktop/_pltest.ts` (bundled to `$CLAUDE_JOB_DIR/tmp/pltest.js`, run, then deleted).

---

## Task 1: Pure `nextPlaylistIndex` + interleave sequence logic test

**Files:**
- Modify: `desktop/src/listOps.ts`
- Test: `desktop/_pltest.ts` (throwaway; bundled to `$CLAUDE_JOB_DIR/tmp/pltest.js`)

**Interfaces:**
- Produces: `nextPlaylistIndex(i: number, len: number): number` — returns `(i+1) % len`, or `0` when `len === 0`. Used by `engine.trackEnded` in Task 2.

- [ ] **Step 1: Write the failing test** — create `desktop/_pltest.ts`:

```ts
// Throwaway item-16 logic gate — bundled via esbuild, run with node, then deleted.
// Tests nextPlaylistIndex + a pure model of trackEnded's interleave/wrap decision.
import { nextPlaylistIndex } from "./src/listOps";

let pass = 0, fail = 0;
const eq = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);
function check(name: string, got: unknown, want: unknown) {
  if (eq(got, want)) pass++;
  else { fail++; console.log(`  FAIL ${name}\n    got  ${JSON.stringify(got)}\n    want ${JSON.stringify(want)}`); }
}

// nextPlaylistIndex — wrap arithmetic (twin of iOS (i+1) % count)
check("next 0/3", nextPlaylistIndex(0, 3), 1);
check("next 1/3", nextPlaylistIndex(1, 3), 2);
check("next 2/3 wraps", nextPlaylistIndex(2, 3), 0);
check("next 0/1 wraps", nextPlaylistIndex(0, 1), 0);
check("next 5/3 wraps", nextPlaylistIndex(5, 3), 0);
check("next _/0 = 0", nextPlaylistIndex(3, 0), 0);

// Pure model of trackEnded's decision: queue-first (interleave), else advance the
// playlist by index (wrap), else end. The driver also mirrors engine.notePlaylistPos:
// after a track plays, if it belongs to the playlist, index snaps to its position.
interface S { queue: string[]; playlist: string[]; index: number; }
function step(s: S): { track: string | null; s: S; ended: boolean } {
  if (s.queue.length) {
    const [track, ...queue] = s.queue;
    return { track, s: { ...s, queue }, ended: false };
  }
  if (s.playlist.length) {
    const index = nextPlaylistIndex(s.index, s.playlist.length);
    return { track: s.playlist[index], s: { ...s, index }, ended: false };
  }
  return { track: null, s, ended: true };
}
function drive(init: S, n: number): string[] {
  let s = init, out: string[] = [];
  for (let k = 0; k < n; k++) {
    const r = step(s); s = r.s;
    if (r.ended) { out.push("(end)"); break; }
    out.push(r.track!);
    const pos = s.playlist.indexOf(r.track!);   // notePlaylistPos
    if (pos >= 0) s = { ...s, index: pos };
  }
  return out;
}

// Playing P0 (index 0); assert what plays as tracks end.
check("pure wrap", drive({ queue: [], playlist: ["P0", "P1", "P2"], index: 0 }, 5),
  ["P1", "P2", "P0", "P1", "P2"]);
check("one queued song interleaves then playlist resumes",
  drive({ queue: ["U"], playlist: ["P0", "P1", "P2"], index: 0 }, 4),
  ["U", "P1", "P2", "P0"]);
check("two queued songs both play before the playlist continues",
  drive({ queue: ["U1", "U2"], playlist: ["P0", "P1", "P2"], index: 0 }, 5),
  ["U1", "U2", "P1", "P2", "P0"]);
check("queued track that is also in the playlist does not double-play",
  drive({ queue: ["P2"], playlist: ["P0", "P1", "P2"], index: 0 }, 4),
  ["P2", "P0", "P1", "P2"]);
check("empty queue + empty playlist ends",
  drive({ queue: [], playlist: [], index: 0 }, 3), ["(end)"]);

console.log(`\nitem-16 logic gate: ${pass}/${pass + fail} PASS` + (fail ? ` (${fail} FAIL)` : ""));
process.exit(fail ? 1 : 0);
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
npx esbuild _pltest.ts --bundle --outfile="$CLAUDE_JOB_DIR/tmp/pltest.js" --platform=node --format=cjs --log-level=warning
```
Expected: esbuild FAILS — `No matching export in "src/listOps.ts" for import "nextPlaylistIndex"`.

- [ ] **Step 3: Implement `nextPlaylistIndex`** — append to `desktop/src/listOps.ts`:

```ts
/** Next index in a wrapping playlist — twin of iOS next()'s (i+1) % count.
 *  Returns 0 for an empty playlist. */
export function nextPlaylistIndex(i: number, len: number): number {
  return len > 0 ? (i + 1) % len : 0;
}
```

- [ ] **Step 4: Bundle + run the test to verify it passes**

Run:
```bash
npx esbuild _pltest.ts --bundle --outfile="$CLAUDE_JOB_DIR/tmp/pltest.js" --platform=node --format=cjs --log-level=warning && node "$CLAUDE_JOB_DIR/tmp/pltest.js"
```
Expected: `item-16 logic gate: 11/11 PASS`, exit 0.

- [ ] **Step 5: Static gate**

Run: `npx tsc --noEmit && npm run bundle`
Expected: tsc prints nothing (exit 0); bundle prints `dist/bundle.js …kb` / `Done`.

- [ ] **Step 6: Delete the throwaway test and commit**

```bash
rm -f _pltest.ts
git add src/listOps.ts
git commit -m "$(printf 'arpi P3: add nextPlaylistIndex for playlist wrap\n\nPure (i+1)%%len helper for item-16 interleave. Node logic gate 11/11 PASS\n(nextPlaylistIndex + a pure model of trackEnded interleave/wrap/notePlaylistPos).\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```
(Run `git add` from `desktop/`; the repo root is the parent — `git` resolves it. The throwaway `_pltest.ts` is deleted, not committed.)

---

## Task 2: Engine — owner-local playlist, interleave, jump, ownership-loss

**Files:**
- Modify: `desktop/src/engine.ts`

**Interfaces:**
- Consumes: `nextPlaylistIndex` from Task 1; existing `sameId` (already imported line 9), `toRef`, `resolve`, `LocalTrack`, `this.player`, `this.coord`, `this.queueSync`, `this.pushHistory`, `this.applyCrop`, `this.publish`, `this.demoQueue`.
- Produces (used by Task 3 UI):
  - `get inPlaylistMode(): boolean`
  - `get playlistUpNext(): LocalTrack[]`
  - `playFromPlaylist(t: LocalTrack): void`

- [ ] **Step 1: Add `playlistIndex` + getters + `notePlaylistPos`.** Replace the existing `playlistLoop` comment block and declaration (`engine.ts:36-41`):

```ts
  // Playlist wrap — twin of iOS isPlaylistMode. Armed by playAll(), so a played
  // playlist keeps going and wraps to the top when the queue drains. Owner-local
  // (not synced): the wrap just re-fills the shared queue, which followers see.
  // Cleared by a direct single-track play (playLocal) or clearQueue — exiting
  // "playlist mode" the same way iOS play(_:) does.
  private playlistLoop: LocalTrack[] | null = null;
```

with:

```ts
  // Playlist mode — twin of iOS currentPlaylist/currentIndex. Owner-local and NOT
  // synced (iOS never syncs currentPlaylist): the shared queue stays the user
  // queue and drains first (interleave), then the playlist advances by index and
  // wraps. Armed by playAll(); cleared by a direct single-track play (playLocal),
  // clearQueue, or losing ownership — exiting "playlist mode" like iOS play(_:).
  private playlistLoop: LocalTrack[] | null = null;
  private playlistIndex = 0;

  /** True on the owner while a playlist is driving playback. */
  get inPlaylistMode(): boolean { return !!this.playlistLoop; }

  /** Upcoming playlist tracks after the current one — the "Up Next from Playlist"
   *  section (twin of iOS playlistUpNextTracks). Owner-only; empty on followers. */
  get playlistUpNext(): LocalTrack[] {
    return this.playlistLoop ? this.playlistLoop.slice(this.playlistIndex + 1) : [];
  }

  /** Snap playlistIndex to a track that belongs to the playlist but was played out
   *  of band (a queued duplicate, or prev) — twin of iOS play(_:) maintaining
   *  currentIndex, so the next advance doesn't immediately replay it. */
  private notePlaylistPos(t?: LocalTrack) {
    if (!t || !this.playlistLoop) return;
    const i = this.playlistLoop.findIndex(x => sameId(x.id, t.id));
    if (i >= 0) this.playlistIndex = i;
  }
```

- [ ] **Step 2: Clear playlist on ownership loss.** In `handleRemote` (`engine.ts:93`), insert at the top of the method body (before the `this.ghostQueue = …` line):

```ts
    // Lost ownership → drop our owner-local playlist (iOS: currentPlaylist doesn't
    // survive handover). trackEnded is role-gated, but this also stops a stale
    // playlist from resuming if we regain ownership without a fresh playAll.
    if (this.coord.role !== "owner" && this.playlistLoop) {
      this.playlistLoop = null;
      this.playlistIndex = 0;
    }
```

- [ ] **Step 3: Index-sync `playLocal` and `goPrevious`.**

In `playLocal` (`engine.ts:221`), add the index reset right after `this.playlistLoop = null;`:

```ts
  async playLocal(t: LocalTrack) {
    this.playlistLoop = null;
    this.playlistIndex = 0;
```

In `goPrevious` (`engine.ts:140-141`), add `notePlaylistPos` before playing:

```ts
    this.applyCrop(prev);
    this.notePlaylistPos(prev);
    this.player.play(prev);
```

- [ ] **Step 4: Rewrite `playAll` to keep the playlist local (no queue refill).** Replace the whole `playAll` method (`engine.ts:232-242`):

```ts
  /** Play a whole list: first track now, rest replace the shared queue. Arms
   *  playlist wrap so playback continues past the queue and loops to the top. */
  async playAll(ts: LocalTrack[]) {
    if (!ts.length) return;
    await this.playLocal(ts[0]);   // clears playlistLoop…
    this.playlistLoop = ts;        // …then arm it with the full set
    const refs = ts.slice(1).map(toRef);
    if (this.coord.demo) { this.demoQueue(() => refs); return; }
    void this.queueSync.apply({ kind: "replaceAll", queue: refs },
      this.coord.remote?.queueVersion ?? 0);
  }
```

with:

```ts
  /** Play a whole list: play the first track now and arm playlist mode. The shared
   *  (user) queue is left untouched — iOS loadPlaylist doesn't clear it, and
   *  trackEnded drains it first so any queued songs interleave before the playlist
   *  resumes. */
  async playAll(ts: LocalTrack[]) {
    if (!ts.length) return;
    await this.playLocal(ts[0]);   // takes over + plays ts[0] + clears the old loop
    this.playlistLoop = ts;
    this.playlistIndex = 0;
  }
```

- [ ] **Step 5: Reset index in `clearQueue`.** In `clearQueue` (`engine.ts:246-249`), add the index reset after nulling the loop:

```ts
  clearQueue() {
    this.playlistLoop = null;
    this.playlistIndex = 0;
    if (this.coord.demo) { this.demoQueue(() => []); return; }
    void this.queueSync.apply({ kind: "replaceAll", queue: [] },
      this.coord.remote?.queueVersion ?? 0);
  }
```

- [ ] **Step 6: Index-advance the drained branch in `trackEnded` + sync on the queue head.**

In `trackEnded`, in the queue-head branch (`engine.ts:162-168`), add `notePlaylistPos`:

```ts
      if (local) {
        this.pushHistory(this.player.current);   // remember what we're leaving
        this.notePlaylistPos(local);             // a queued playlist track keeps index in step
        this.applyCrop(local);
        this.player.play(local);
        this.publish();
        return;
      }
```

Replace the drained-queue playlist branch (`engine.ts:170-183`):

```ts
    // Queue drained. In playlist mode, wrap to the top instead of stopping —
    // twin of iOS next()'s currentIndex = (i+1) % count.
    if (this.playlistLoop && this.playlistLoop.length) {
      const list = this.playlistLoop;
      this.pushHistory(this.player.current);
      this.applyCrop(list[0]);
      this.player.play(list[0]);
      const refs = list.slice(1).map(toRef);
      if (this.coord.demo) this.demoQueue(() => refs);
      else void this.queueSync.apply({ kind: "replaceAll", queue: refs },
        this.coord.remote?.queueVersion ?? 0);
      this.publish();
      return;
    }
```

with:

```ts
    // Queue drained. In playlist mode, advance to the next playlist track and wrap
    // — twin of iOS next()'s currentIndex = (i+1) % count. The playlist is
    // owner-local; nothing is written to the shared queue.
    if (this.playlistLoop && this.playlistLoop.length) {
      this.playlistIndex = nextPlaylistIndex(this.playlistIndex, this.playlistLoop.length);
      const t = this.playlistLoop[this.playlistIndex];
      this.pushHistory(this.player.current);
      this.applyCrop(t);
      this.player.play(t);
      this.publish();
      return;
    }
```

- [ ] **Step 7: Add `playFromPlaylist`.** Add a new method right after `clearQueue` (`engine.ts`, after the `clearQueue` closing brace):

```ts
  /** Click an "Up Next from Playlist" row: jump to that track, stay in playlist
   *  mode, leave the user queue intact (queued songs still interleave next). Owner
   *  only — playlistLoop is owner-local. Distinct from playFromQueue, which removes
   *  from the user queue and exits playlist mode. */
  playFromPlaylist(t: LocalTrack) {
    if (!this.playlistLoop) return;
    const i = this.playlistLoop.findIndex(x => sameId(x.id, t.id));
    if (i < 0) return;
    this.pushHistory(this.player.current);
    this.playlistIndex = i;
    this.applyCrop(t);
    this.player.play(t);
    this.publish();
  }
```

- [ ] **Step 8: Add the `nextPlaylistIndex` import.** At the top of `engine.ts`, after the `serverClock` import (`engine.ts:10`), add:

```ts
import { nextPlaylistIndex } from "./listOps";
```

- [ ] **Step 9: Static gate + re-run the logic gate**

Run:
```bash
npx tsc --noEmit && npm run bundle
```
Expected: tsc exit 0; bundle prints `dist/bundle.js …kb` / `Done`.

Then re-confirm the model still matches (recreate the Task 1 throwaway if gone), or at minimum verify no `toRef` "unused import" error — `toRef` is still used elsewhere in `engine.ts` (`queueLocal`, `goPrevious`), so tsc staying green confirms it.

- [ ] **Step 10: Commit**

```bash
git add src/engine.ts
git commit -m "$(printf 'arpi P3: playlist mode = owner-local interleave + jump (item 16)\n\nStop dumping the playlist remainder into the shared queue. playlistLoop +\nplaylistIndex stay owner-local (iOS currentPlaylist/currentIndex); trackEnded\ndrains the shared user-queue first (interleave), then advances the playlist by\n(i+1)%%len. New playFromPlaylist (jump, stay in playlist mode), notePlaylistPos\nindex-sync, inPlaylistMode/playlistUpNext getters. Playlist cleared on ownership\nloss. Gate: tsc + bundle green.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 3: UI — two-section Up Next (clickable playlist rows) + empty/Clear gating

**Files:**
- Modify: `desktop/src/ui.ts`

**Interfaces:**
- Consumes: `engine.inPlaylistMode`, `engine.playlistUpNext`, `engine.playFromPlaylist` (Task 2); existing `coord.role`, `$`, `thumbEl`, `titleSpan`, `rowClick` (`ui.ts:813`), `run`.

- [ ] **Step 1: Gate the Clear button and empty hint on playlist mode.** In `renderLibrary`, replace (`ui.ts:1217-1220`):

```ts
  $("queue-clear").hidden = q.length === 0;
  if (q.length === 0) {
    queueEl.innerHTML = `<div class="list-empty">Queue is empty — hover a library song and press ＋, or drag songs in</div>`;
  }
```

with:

```ts
  $("queue-clear").hidden = q.length === 0 && !engine.inPlaylistMode;
  if (q.length === 0 && !engine.inPlaylistMode) {
    queueEl.innerHTML = `<div class="list-empty">Queue is empty — hover a library song and press ＋, or drag songs in</div>`;
  }
```

- [ ] **Step 2: Render the "Up Next from Playlist" section after the user-queue loop.** The user-queue `q.forEach(…)` loop ends at `ui.ts:1259` with `});`. Immediately after that closing `});`, insert:

```ts
  // Up Next from Playlist — owner-only playlist remainder (iOS currentPlaylist,
  // never synced). A follower's playlistUpNext is empty, so this stays hidden.
  const plUp = coord.role === "owner" ? engine.playlistUpNext : [];
  if (plUp.length) {
    const head = document.createElement("li");
    head.textContent = "Up Next from Playlist";
    head.style.cssText = "list-style:none; opacity:.55; font-size:11px; " +
      "text-transform:uppercase; letter-spacing:.08em; padding:10px 0 2px; cursor:default";
    queueEl.appendChild(head);
    for (const t of plUp) {
      const li = document.createElement("li");
      li.appendChild(thumbEl(t.yt));
      li.appendChild(titleSpan(t.name));
      li.onclick = rowClick(() => engine.playFromPlaylist(t));   // jump, stay in playlist mode
      queueEl.appendChild(li);
    }
  }
```

- [ ] **Step 3: Static gate**

Run: `npx tsc --noEmit && npm run bundle`
Expected: tsc exit 0; bundle prints `dist/bundle.js …kb` / `Done`.

- [ ] **Step 4: Commit**

```bash
git add src/ui.ts
git commit -m "$(printf 'arpi P3: two-section Up Next + clickable playlist rows (item 16)\n\nRender an owner-only Up Next from Playlist section (engine.playlistUpNext);\nrows jump via engine.playFromPlaylist. Empty hint + Clear button now react to\nplaylist mode as well as the user queue. Followers show only the user queue.\nGate: tsc + bundle green.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Task 4: Docs — smoke checklist + NOTES

**Files:**
- Modify: `docs/arpi/smoke-test.md`
- Modify: `NOTES.md`

- [ ] **Step 1: Replace the Phase-3 "known gap" note with real checks.** In `docs/arpi/smoke-test.md`, find the block:

```markdown
> ⚠️ Known gap (item 16, deferred): manually **queued** songs are appended after the
> playlist remainder rather than interleaved to play *next*, and Up Next is one flat
> list (no "Up Next from Playlist" split). See NOTES → OPEN. Not covered by this pass.
```

and replace it with:

```markdown
Playlist mode (interleave + Up Next split, item 16):
- [ ] **Play all** a playlist, then hover a library song and press ＋ (or ⋯ → Add to queue) → the queued song plays **next**, *before* the playlist continues (not after the whole playlist).
- [ ] Up Next shows two labeled groups: **Up Next** (your queued songs) then **Up Next from Playlist** (the upcoming playlist tracks). With no queued songs, only the playlist group shows.
- [ ] Click a row under **Up Next from Playlist** → it jumps to that track and keeps playing the playlist from there (still in playlist mode; your queued songs still play next).
- [ ] Let the last playlist track end → it **wraps** to the top.
- [ ] **Clear** while in playlist mode (even with an empty user queue) → exits playlist mode; the next track-end stops instead of looping.

Two devices (real secret; desktop owns a playlist):
- [ ] On the **follower**, Up Next shows only the shared user queue — **no** "Up Next from Playlist" section (the playlist is owner-local, like iOS).
- [ ] Follower taps **Play Here** → it takes over the user queue and playlist mode ends (matches iOS: currentPlaylist isn't synced).
```

- [ ] **Step 2: Update NOTES — mark item 16 done, retire the OPEN entry, add a DECISION.**

In `NOTES.md`, in the DECISIONS section, add after the last P3 decision line:

```markdown
- 2026-07-14 P3 item 16 DONE (faithful iOS, approach A): playlist is now owner-local (playlistLoop + playlistIndex, not synced). playAll no longer dumps the remainder into the shared queue; trackEnded drains the shared user-queue first (interleave) then advances the playlist by (i+1)%len. Up Next split into user queue + owner-only "Up Next from Playlist" (rows jump via playFromPlaylist). Tradeoff accepted: playlist mode doesn't survive cross-device handover (= iOS). Spec: docs/superpowers/specs/2026-07-14-desktop-playlist-interleave-design.md.
```

In the `## DONE` section, update the Phase 3 line's item-16 clause from `playlist-mode WRAP (owner-local playlistLoop) [#7, partial — interleave/split deferred]` to `playlist mode: interleave + wrap + Up Next split (owner-local playlistLoop+index) [#7]`.

In the `## OPEN` section, delete the entire bullet that begins `- **[USER DECISION] P3 item 16 interleave/split.**` (the item is now resolved).

- [ ] **Step 3: Commit**

```bash
git add docs/arpi/smoke-test.md NOTES.md
git commit -m "$(printf 'arpi P3: item 16 done — smoke checklist + NOTES\n\nReplace the deferred-gap note with interleave/split/jump/handover smoke checks;\nmark item 16 complete in NOTES and retire the OPEN decision.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Self-Review

**Spec coverage:**
- Interleave (queued songs play next) → Task 2 Steps 4/6 (playAll no-refill + trackEnded queue-first), verified by Task 1 sequence test.
- `(i+1)%len` wrap → Task 1 `nextPlaylistIndex`, used in Task 2 Step 6.
- Index-sync (`notePlaylistPos`) → Task 2 Steps 1/3/6.
- Up Next split → Task 3 Step 2.
- Clickable playlist rows (`playFromPlaylist`) → Task 2 Step 7 + Task 3 Step 2.
- Empty/Clear gating → Task 3 Step 1.
- Ownership-loss clears playlist → Task 2 Step 2.
- Follower shows only user queue → Task 3 Step 2 (`coord.role === "owner"` gate) + Task 2 owner-local `playlistUpNext`.
- Smoke + NOTES → Task 4.

**Placeholder scan:** none — every code step shows full code; commands have expected output.

**Type consistency:** `nextPlaylistIndex(i, len)` (Task 1) matches its use in Task 2 Step 6 and its import in Task 2 Step 8. Getters `inPlaylistMode`/`playlistUpNext` and method `playFromPlaylist(t: LocalTrack)` (Task 2) match their consumption in Task 3 Step 2. `sameId` already imported in `engine.ts:9`.

**Notes for the implementer:** line numbers are from the current tree and will drift as edits land — locate by the shown surrounding code / method name, not the line number alone. `git` commands run from `desktop/` operate on the whole repo (the `.git` dir is the parent); the doc paths in Task 4 are repo-relative, so run those `git add` calls from the repo root or with the `../` prefix.
