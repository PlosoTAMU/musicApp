# Desktop UI usability pass + iOS edge visualizer port

## Goals

- Reduce wasted space and cramped feel in the left rail (`.rail`), without changing the app's core two-column structure.
- Make row actions (delete/add/info buttons on Library/Queue/Playlist rows) discoverable without hover-hunting.
- Port the iOS `EdgeVisualizerView` (FFT bars wrapping the album art, color-matched to the art, art pulsing with bass) to desktop, replacing the existing flat `#viz` spectrum strip.

## Non-goals

- No change to the two-column grid (`#main { grid-template-columns: 400px 1fr }` stays a fixed-left/flex-right split — width value changes, structure doesn't).
- No change to panel stack order (Up Next / Playlists / Library) or data flow (`coordinator.ts`, `replicator.ts`, `queueSync.ts` untouched).
- No new IPC surface, no new dependencies.

## 1. Rail rebalance

- Widen rail from `400px` → `460px` in `#main` grid-template-columns.
- Bump art from `168px` → `208px`, matching the visual weight increase.
- Bump `.rail-actions button` from `34px` → `38px` (loop/fx/crop/lyrics/add-to-playlist icons) — larger touch target, fixes flagged click-target issue.
- Add a bit more vertical gap in `#fx` (`.fx-row` gap 6px → 10px) so the FX sliders use the freed vertical space instead of leaving it dead below them.
- Transport buttons (`.transport button`) get a modest bump too: 52px → 56px, back10/fwd10 44px → 48px.

## 2. Row actions always visible

- `.row-btn` currently `opacity: 0`, `opacity: 1` on `.panel li:hover`. Change default to `opacity: 1` (drop the hover-reveal rule entirely) — matches the "always visible, full opacity" choice.
- Bump `.row-btn` font-size 14px → 15px and padding slightly (3px 7px → 5px 9px) for an easier hit target now that it's always rendered.
- Applies uniformly to Library, Queue, and Playlist rows — no per-panel special-casing.

## 3. Edge visualizer

### Audio path (reuse, don't rebuild)

`beat.ts`'s `BeatFeed` already taps an `AnalyserNode` and produces smoothed display bins (`DISPLAY_BINS = 48`, log-spaced 40Hz–14kHz, fast-attack/slow-release). This is functionally the desktop twin of iOS's `processFFTBuffer` + `frequencyBins`. Plan:

- Add a second bin array to `BeatFeed`: `edgeBins = new Float32Array(100)` with its own log-spaced band edges (mirrors the existing 48-bin logic, just 100 bins to match iOS's 25-bars-per-side layout). Computed in the same `tick()` pass — one extra peak-scan loop, no new analyser/tap.
- Bass/pulse for the art scale reuses the existing `BeatOutput.pulse` (already wired to the CSS transform per the code comment at `index.html:172-175` — "transform/box-shadow are driven per-frame by the beat engine"). No change needed there, the edge canvas just reads the same value.

### Rendering

- Remove `#viz` canvas and its CSS/JS (`vizLoop`, `vizCtx`, etc. in `ui.ts`).
- Add a new canvas (`#edge-viz`) absolutely positioned over `#art`'s parent, sized to the pulsed box (mirrors `EdgeVisualizerView`'s geometry: `barsPerSide = 25`, bars drawn outward from each of the 4 edges of the (rounded) art square, spacing computed from straight-edge length minus corner radius).
- Driven from the existing `requestAnimationFrame` loop that already calls `beatFeed.tick()` — draw happens right after `tick()`, using `edgeBins`.
- New module `desktop/src/visualizer.ts` owns the draw function (`drawEdgeVisualizer(ctx, bins, pulse, colors)`) — keeps `ui.ts` from growing further; `ui.ts` just calls it each frame.

### Color

- Attempt art-color sampling: draw the loaded `#art-img` into an offscreen canvas (`img.crossOrigin = "anonymous"` set before `src` assignment) and sample dominant colors the same way iOS does (downsample to 50×50, bucket-quantize, pick top colors), computed once per track change (mirrors iOS's `precomputeBarColors`, not per-frame).
- Wrap the `getImageData` call in try/catch — on `SecurityError` (CORS-tainted canvas, since i.ytimg.com's CORS headers are unverified), fall back to the existing `--red-gradient` theme colors for all bars.
- Result cached per track (same `lastArtYt` cache key already used for art loading) so this never runs on the hot path.

## Verification

- `npm run build` (tsc + esbuild) must pass clean.
- `npm run test:logic` (existing logic tests) must still pass.
- Visual check via the Electron MCP connection already in use this session: launch with `node scripts/launch-debug.js`, screenshot before/after for the rail layout and the visualizer during playback (both a track with normal art and the fallback ♫ state, to confirm the CORS-fallback color path doesn't break rendering).
