# Desktop UI Usability Pass + iOS Edge Visualizer Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebalance the desktop rail layout, make row actions always-visible, and port the iOS `EdgeVisualizerView` (FFT bars wrapping the album art, art-color-matched, bass-pulsing) to desktop.

**Architecture:** Pure CSS/HTML changes for the rail + row-action work (Tasks 1-2). The visualizer reuses the existing `BeatFeed`/`AnalyserNode` audio tap in `beat.ts` — a new 100-bin log-spaced band array is added alongside the existing 48-bin one via shared pure helper functions (Task 3). Color sampling and canvas drawing live in a new `desktop/src/visualizer.ts` module (Tasks 4-5), wired into the existing per-frame loop in `ui.ts` (Task 6).

**Tech Stack:** TypeScript (desktop/src), esbuild bundling, Node-based logic tests (`tests/*.test.ts` via `npm run test:logic`), Electron MCP for visual verification (already connected this session via `desktop/scripts/launch-debug.js`).

## Global Constraints

- No change to `#main`'s two-column grid structure — only the `400px` value changes.
- No new IPC surface, no new npm dependencies.
- Existing `tests:logic` suite must keep passing; new pure logic gets its own test file in the same style (top-level `eq()` assertions, see `tests/phaseA-queue.test.ts`).
- `npm run build` (tsc + esbuild) must pass with zero errors before any commit that touches `.ts` files.

---

### Task 1: Rail CSS rebalance

**Files:**
- Modify: `desktop/index.html:126-138` (`#main`, `.rail`), `:176-183` (`#art`), `:223-245` (`.transport`, button sizes), `:257-283` (`.rail-actions`), `:372-379` (`#fx`, `.fx-row`)

**Interfaces:**
- Produces: no new IDs/classes — pure value changes on existing selectors, nothing later tasks depend on by name.

- [ ] **Step 1: Widen the rail and bump art size**

In `desktop/index.html`, change:

```css
#main {
  flex: 1; display: grid; grid-template-columns: 400px 1fr;
  gap: 0; min-height: 0;
}
```
to `grid-template-columns: 460px 1fr;`

Change:
```css
#art {
  width: 168px; height: 168px; border-radius: 22px; overflow: hidden;
  ...
  font-size: 46px; color: var(--bone-faint); margin: 10px 0 2px;
  flex: none; will-change: transform, box-shadow;
}
```
to `width: 208px; height: 208px;` (keep everything else the same — `border-radius: 22px` stays, it's referenced again in Task 6).

- [ ] **Step 2: Bump transport and rail-action button sizes**

Change `.transport button` from `width: 52px; height: 52px;` to `width: 56px; height: 56px;`.
Change `.transport #btn-back10, .transport #btn-fwd10` from `width: 44px; height: 44px;` to `width: 48px; height: 48px;`.
Change `.rail-actions button` from `width: 34px; height: 34px;` to `width: 38px; height: 38px;`.

- [ ] **Step 3: Give the FX rows more breathing room**

Change `#fx { margin-top: 18px; display: grid; gap: 6px; }` to `gap: 10px;`.

- [ ] **Step 4: Build and visually verify**

Run: `cd desktop && npm run build`
Expected: exits 0, no tsc errors (pure CSS change, should be a no-op for tsc but confirms nothing else broke).

The app is already running under Electron MCP debug mode from earlier in this session (`desktop/scripts/launch-debug.js`, port 9222). Reload it and screenshot:
- Call `mcp__electron__navigate_page` (or close/relaunch if the page handle is stale) to reload `index.html` — Electron doesn't hot-reload the bundle, so if `npm run start` isn't already watching, kill and relaunch: `node scripts/launch-debug.js`.
- Call `mcp__electron__take_screenshot` and visually confirm: rail is wider, art is bigger, no layout overflow/clipping in the rail column.

- [ ] **Step 5: Commit**

```bash
git add desktop/index.html
git commit -m "Widen desktop rail and bump touch-target sizes"
```

---

### Task 2: Row actions always visible

**Files:**
- Modify: `desktop/index.html:321-327` (`.row-btn`)

**Interfaces:**
- Produces: no new IDs/classes.

- [ ] **Step 1: Remove hover-reveal, bump target size**

Change:
```css
.row-btn {
  background: none; border: none; color: var(--bone-faint);
  font-size: 14px; cursor: pointer; padding: 3px 7px;
  opacity: 0; transition: opacity .15s, color .15s;
}
.panel li:hover .row-btn { opacity: 1; }
```
to:
```css
.row-btn {
  background: none; border: none; color: var(--bone-faint);
  font-size: 15px; cursor: pointer; padding: 5px 9px;
  opacity: 1; transition: color .15s;
}
```
(drop the `.panel li:hover .row-btn` rule entirely — there's nothing left for it to toggle.)

Leave `.row-btn.confirm` (the "…now?" playlist confirm state) and `#failed-panel .fp-head .row-btn` alone — both already force `opacity: 1` and are unaffected by this change.

- [ ] **Step 2: Build and visually verify**

Run: `cd desktop && npm run build`
Expected: exits 0.

Screenshot via `mcp__electron__take_screenshot` on the Library panel (needs library rows on screen — scroll if needed via `mcp__electron__evaluate_script` or a page interaction). Confirm the row action buttons (▶ / + / ⋯) are visible without hovering.

- [ ] **Step 3: Commit**

```bash
git add desktop/index.html
git commit -m "Make library/queue row actions always visible"
```

---

### Task 3: Shared band-edge helpers + 100-bin edge array in BeatFeed

**Files:**
- Modify: `desktop/src/beat.ts:171-256`
- Test: `desktop/tests/beatBins.test.ts` (new)

**Interfaces:**
- Produces:
  - `computeBandEdges(sampleRate: number, fftSize: number, nyquistBins: number, bandCount: number, loHz: number, hiHz: number): number[]` — pure function, exported from `beat.ts`.
  - `peakPerBand(freq: Uint8Array, bandEdges: number[], bandCount: number): Float32Array` — pure function, exported from `beat.ts`, returns raw (unsmoothed) 0-1 peak values per band.
  - `BeatFeed.edgeBins: Float32Array` (length 100) — smoothed display bins for the edge visualizer, same fast-attack/slow-release behavior as the existing `bins` field. Consumed by Task 6.

- [ ] **Step 1: Write the failing test**

Create `desktop/tests/beatBins.test.ts`:

```typescript
// Pure band-math logic gate for the visualizer's FFT bin bucketing.
import { computeBandEdges, peakPerBand } from "../src/beat";

let n = 0;
function eq(name: string, got: unknown, want: unknown) {
  n++;
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) throw new Error(`${name}: got ${g}, want ${w}`);
}
function ok(name: string, cond: boolean) {
  n++;
  if (!cond) throw new Error(`${name}: expected true`);
}

// ── computeBandEdges ─────────────────────────────────────────────────────
const edges48 = computeBandEdges(48000, 2048, 1024, 48, 40, 14_000);
eq("48-band edge count", edges48.length, 49);
ok("edges strictly non-decreasing", edges48.every((v, i) => i === 0 || v >= edges48[i - 1]));
ok("edges within analyser bin range", edges48.every(v => v >= 1 && v <= 1024));

const edges100 = computeBandEdges(48000, 2048, 1024, 100, 40, 14_000);
eq("100-band edge count", edges100.length, 101);
ok("100-band edges non-decreasing", edges100.every((v, i) => i === 0 || v >= edges100[i - 1]));

// ── peakPerBand ──────────────────────────────────────────────────────────
const freq = new Uint8Array(1024);
freq[10] = 255; // sits in an early low-frequency band
freq[500] = 128; // sits in a later band
const bands = peakPerBand(freq, edges48, 48);
eq("peakPerBand output length", bands.length, 48);
ok("band containing bin 10 picks up the peak", bands.some(v => v === 1));
ok("all values normalized 0-1", bands.every(v => v >= 0 && v <= 1));

const flatFreq = new Uint8Array(1024); // silence
const flatBands = peakPerBand(flatFreq, edges48, 48);
ok("silence yields all-zero bands", flatBands.every(v => v === 0));

console.log(`beatBins.test.ts: ${n} assertions passed`);
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd desktop && npm run test:logic`
Expected: FAIL — `computeBandEdges` / `peakPerBand` are not exported from `../src/beat` yet.

- [ ] **Step 3: Extract the pure helpers and add the 100-bin edge array**

In `desktop/src/beat.ts`, replace the `// ── Analyser feeder ──` section (lines 171-256) with:

```typescript
// ── Analyser feeder ─────────────────────────────────────────────────────────

const DISPLAY_BINS = 48;
const EDGE_BINS = 100; // 4 sides × 25 bars — matches iOS EdgeVisualizerView

/** Log-spaced band edges (bin indices into an analyser's frequency array)
 *  covering [loHz, hiHz]. Returns bandCount+1 edges. Pure — no analyser needed. */
export function computeBandEdges(
  sampleRate: number, fftSize: number, nyquistBins: number,
  bandCount: number, loHz: number, hiHz: number,
): number[] {
  const binHz = sampleRate / fftSize;
  const lo = Math.log(loHz), hi = Math.log(hiHz);
  return Array.from({ length: bandCount + 1 }, (_, i) => {
    const hz = Math.exp(lo + ((hi - lo) * i) / bandCount);
    return Math.max(1, Math.min(nyquistBins - 1, Math.round(hz / binHz)));
  });
}

/** Per-band peak (0-1, unsmoothed) from a `getByteFrequencyData` snapshot. Pure. */
export function peakPerBand(freq: Uint8Array, bandEdges: number[], bandCount: number): Float32Array {
  const out = new Float32Array(bandCount);
  for (let b = 0; b < bandCount; b++) {
    let peak = 0;
    for (let i = bandEdges[b]; i < bandEdges[b + 1]; i++) {
      if (freq[i] > peak) peak = freq[i];
    }
    out[b] = peak / 255;
  }
  return out;
}

export class BeatFeed {
  readonly engine = new BeatEngine();
  /** Log-spaced 0-1 display bins (fast attack, slow release) for the flat canvas. */
  readonly bins = new Float32Array(DISPLAY_BINS);
  /** Same smoothing, 100 bins — feeds the edge visualizer wrapped around the art. */
  readonly edgeBins = new Float32Array(EDGE_BINS);

  private analyser?: AnalyserNode;
  private sampleRate = 48000;
  private freq?: Uint8Array<ArrayBuffer>; // getByteFrequencyData rejects ArrayBufferLike
  private prevLog?: Float32Array;
  private bandEdges: number[] = [];
  private edgeBandEdges: number[] = [];
  private energyEma = 0;
  private lastT = 0;

  /** Bind to the AudioGraph's analyser — a read-only tap. Idempotent. */
  bind(analyser: AnalyserNode, sampleRate: number) {
    if (this.analyser) return;
    analyser.fftSize = 2048;
    analyser.smoothingTimeConstant = 0; // engine + bins do their own smoothing
    this.analyser = analyser;
    this.sampleRate = sampleRate;
    this.freq = new Uint8Array(analyser.frequencyBinCount);
    this.prevLog = new Float32Array(analyser.frequencyBinCount);

    this.bandEdges = computeBandEdges(
      sampleRate, analyser.fftSize, analyser.frequencyBinCount, DISPLAY_BINS, 40, 14_000);
    this.edgeBandEdges = computeBandEdges(
      sampleRate, analyser.fftSize, analyser.frequencyBinCount, EDGE_BINS, 40, 14_000);
  }

  get bound() { return !!this.analyser; }

  resetTrack() {
    this.engine.reset();
    this.prevLog?.fill(0);
    this.energyEma = 0;
  }

  /** One animation frame: spectral flux → engine; also refreshes `bins`/`edgeBins`. */
  tick(nowMs: number): BeatOutput {
    const a = this.analyser;
    if (!a || !this.freq || !this.prevLog) {
      return { nod: 0, pulse: 0, confidence: 0, bpm: 0 };
    }
    const dt = this.lastT ? (nowMs - this.lastT) / 1000 : 1 / 60;
    this.lastT = nowMs;

    a.getByteFrequencyData(this.freq);

    // Kick-weighted half-wave-rectified log-spectral flux + loudness gate.
    const binHz = this.sampleRate / a.fftSize;
    let flux = 0, level = 0;
    const nBins = this.freq.length;
    for (let i = 1; i < nBins; i++) {
      const v = this.freq[i];
      level += v;
      const m = Math.log1p(v);
      const d = m - this.prevLog[i];
      if (d > 0) {
        const hz = i * binHz;
        flux += d * (hz < 120 ? 3 : hz < 250 ? 2 : hz < 4000 ? 1 : 0.3);
      }
      this.prevLog[i] = m;
    }
    const loudness = Math.min(1, (level / nBins / 255) * 4);
    this.energyEma += (loudness - this.energyEma) * 0.1;

    // Display bins: per-band peak, fast attack / slow release.
    const peaks = peakPerBand(this.freq, this.bandEdges, DISPLAY_BINS);
    for (let b = 0; b < DISPLAY_BINS; b++) {
      const v = peaks[b];
      this.bins[b] += (v - this.bins[b]) * (v > this.bins[b] ? 0.55 : 0.16);
    }

    const edgePeaks = peakPerBand(this.freq, this.edgeBandEdges, EDGE_BINS);
    for (let b = 0; b < EDGE_BINS; b++) {
      const v = edgePeaks[b];
      this.edgeBins[b] += (v - this.edgeBins[b]) * (v > this.edgeBins[b] ? 0.55 : 0.16);
    }

    return this.engine.process(flux / nBins, this.energyEma, dt);
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd desktop && npm run test:logic`
Expected: PASS, including the pre-existing test files (`phaseA-queue.test.ts` etc. must still pass — this refactor must not change the 48-bin math's behavior, only extract it into a named function).

- [ ] **Step 5: Build**

Run: `cd desktop && npm run build`
Expected: exits 0, no tsc errors.

- [ ] **Step 6: Commit**

```bash
git add desktop/src/beat.ts desktop/tests/beatBins.test.ts
git commit -m "Extract pure band-edge helpers, add 100-bin edge array to BeatFeed"
```

---

### Task 4: Dominant-color extraction helper

**Files:**
- Create: `desktop/src/visualizer.ts`
- Test: `desktop/tests/visualizer.test.ts` (new)

**Interfaces:**
- Consumes: nothing (pure, no dependency on Tasks 1-3).
- Produces:
  - `extractDominantColors(data: Uint8ClampedArray, width: number, height: number): string[]` — pure function, returns `"r,g,b"` strings, always non-empty (falls back to `["241,43,38"]`, the theme's `--red` in RGB, if no pixel passes the brightness filter).
  - Consumed by Task 5's `sampleArtColors`.

- [ ] **Step 1: Write the failing test**

Create `desktop/tests/visualizer.test.ts`:

```typescript
// Pure color-quantization logic gate for the edge visualizer's art-color sampling.
import { extractDominantColors } from "../src/visualizer";

let n = 0;
function eq(name: string, got: unknown, want: unknown) {
  n++;
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) throw new Error(`${name}: got ${g}, want ${w}`);
}
function ok(name: string, cond: boolean) {
  n++;
  if (!cond) throw new Error(`${name}: expected true`);
}

// Build a 4x4 RGBA buffer: half mid-gray-blue, half mid-gray-red.
function makeImage(w: number, h: number, fill: (x: number, y: number) => [number, number, number]) {
  const data = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const [r, g, b] = fill(x, y);
      const i = (y * w + x) * 4;
      data[i] = r; data[i + 1] = g; data[i + 2] = b; data[i + 3] = 255;
    }
  }
  return data;
}

const twoTone = makeImage(4, 4, (x) => (x < 2 ? [80, 90, 180] : [180, 90, 80]));
const colors = extractDominantColors(twoTone, 4, 4);
ok("returns at least one color", colors.length >= 1);
ok("all entries are 'r,g,b' strings", colors.every(c => /^\d+,\d+,\d+$/.test(c)));

// All-black image: every pixel fails the brightness>0.2 filter → fallback color.
const black = makeImage(2, 2, () => [0, 0, 0]);
eq("all-dark image falls back to theme red", extractDominantColors(black, 2, 2), ["241,43,38"]);

// All-white image: every pixel fails the brightness<0.9 filter → fallback color.
const white = makeImage(2, 2, () => [255, 255, 255]);
eq("all-bright image falls back to theme red", extractDominantColors(white, 2, 2), ["241,43,38"]);

console.log(`visualizer.test.ts: ${n} assertions passed`);
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd desktop && npm run test:logic`
Expected: FAIL — `desktop/src/visualizer.ts` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

Create `desktop/src/visualizer.ts`:

```typescript
// Edge visualizer — twin of musicApp's EdgeVisualizerView: FFT bars wrapped
// around the album art, colored from the art's dominant colors, art itself
// pulsing on the beat (driven by the existing BeatFeed pulse, see ui.ts).

const FALLBACK_COLOR = "241,43,38"; // --red

/** Downsampled dominant-color extraction — port of ContentView.swift's
 *  extractDominantColors. Pure: takes raw RGBA pixel data, no DOM/canvas
 *  dependency, so it's testable without a browser. */
export function extractDominantColors(data: Uint8ClampedArray, width: number, height: number): string[] {
export function extractDominantColors(data: Uint8ClampedArray, width: number, height: number): string[] {
  const counts = new Map<string, { r: number; g: number; b: number; count: number }>();

  for (let y = 0; y < height; y += 2) {
    for (let x = 0; x < width; x += 2) {
      const i = (y * width + x) * 4;
      const r = data[i], g = data[i + 1], b = data[i + 2];
      const brightness = (r + g + b) / 3 / 255;
      if (brightness <= 0.2 || brightness >= 0.9) continue;

      const qR = Math.floor(r / 64), qG = Math.floor(g / 64), qB = Math.floor(b / 64);
      const key = `${qR}-${qG}-${qB}`;
      const existing = counts.get(key);
      if (existing) {
        existing.count++;
      } else {
        counts.set(key, { r, g, b, count: 1 });
      }
    }
  }

  const sorted = [...counts.values()].sort((a, b) => b.count - a.count);
  if (sorted.length === 0) return [FALLBACK_COLOR];
  return sorted.slice(0, 8).map(c => `${c.r},${c.g},${c.b}`);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd desktop && npm run test:logic`
Expected: PASS.

- [ ] **Step 5: Build**

Run: `cd desktop && npm run build`
Expected: exits 0.

- [ ] **Step 6: Commit**

```bash
git add desktop/src/visualizer.ts desktop/tests/visualizer.test.ts
git commit -m "Add dominant-color extraction for the edge visualizer"
```

---

### Task 5: Canvas draw function + DOM color sampling

**Files:**
- Modify: `desktop/src/visualizer.ts` (append to the file created in Task 4)

**Interfaces:**
- Consumes: `extractDominantColors` (Task 4, same file).
- Produces:
  - `drawEdgeVisualizer(ctx: CanvasRenderingContext2D, boxSize: number, cornerRadius: number, maxBarLen: number, bins: Float32Array, colors: string[] | null): void` — draws 100 bars (25/side) centered in the canvas. `colors === null` draws all bars in the fallback red gradient.
  - `sampleArtColors(img: HTMLImageElement): string[] | null` — draws `img` into an offscreen canvas and calls `extractDominantColors`; returns `null` (not a thrown error) if the canvas is CORS-tainted, so callers can fall back to `null` → red gradient in `drawEdgeVisualizer`.

- [ ] **Step 1: Append the draw + sampling functions**

Append to `desktop/src/visualizer.ts`:

```typescript
const BARS_PER_SIDE = 25; // 100 total, matches EDGE_BINS in beat.ts
const MIN_BAR = 1;

/** Draws the 100-bar edge visualizer centered in a `boxSize`×`boxSize` region
 *  of the canvas (canvas itself should be larger, to leave room for bars to
 *  extend outward — see the CSS/ui.ts sizing in Task 6). Twin of
 *  EdgeVisualizerView's Canvas body. */
export function drawEdgeVisualizer(
  ctx: CanvasRenderingContext2D, boxSize: number, cornerRadius: number,
  maxBarLen: number, bins: Float32Array, colors: string[] | null,
): void {
  const cx = ctx.canvas.clientWidth / 2, cy = ctx.canvas.clientHeight / 2;
  const halfBox = boxSize / 2;
  const straightEdge = boxSize - 2 * cornerRadius;
  const spacing = straightEdge / BARS_PER_SIDE;

  let barIndex = 0;
  const drawBar = (x: number, y: number, dx: number, dy: number) => {
    const v = bins[barIndex];
    const len = Math.max(MIN_BAR, v * maxBarLen);
    const rgb = colors ? colors[barIndex % colors.length] : FALLBACK_COLOR;
    ctx.strokeStyle = `rgba(${rgb},${(0.55 + v * 0.45).toFixed(3)})`;
    ctx.lineWidth = Math.max(1.5, spacing * 0.5);
    ctx.beginPath();
    ctx.moveTo(x, y);
    ctx.lineTo(x + dx * len, y + dy * len);
    ctx.stroke();
    barIndex++;
  };

  // TOP
  for (let i = 0; i < BARS_PER_SIDE; i++) {
    drawBar(cx - halfBox + cornerRadius + spacing * (i + 0.5), cy - halfBox, 0, -1);
  }
  // RIGHT
  for (let i = 0; i < BARS_PER_SIDE; i++) {
    drawBar(cx + halfBox, cy - halfBox + cornerRadius + spacing * (i + 0.5), 1, 0);
  }
  // BOTTOM
  for (let i = 0; i < BARS_PER_SIDE; i++) {
    drawBar(cx + halfBox - cornerRadius - spacing * (i + 0.5), cy + halfBox, 0, 1);
  }
  // LEFT
  for (let i = 0; i < BARS_PER_SIDE; i++) {
    drawBar(cx - halfBox, cy + halfBox - cornerRadius - spacing * (i + 0.5), -1, 0);
  }
}

/** Samples the currently-loaded art image's dominant colors. Returns `null`
 *  (never throws) if the canvas is CORS-tainted — i.ytimg.com's CORS headers
 *  are unverified, so this is the expected fallback path, not an error. */
export function sampleArtColors(img: HTMLImageElement): string[] | null {
  try {
    const size = 50;
    const cv = document.createElement("canvas");
    cv.width = size; cv.height = size;
    const ctx = cv.getContext("2d");
    if (!ctx) return null;
    ctx.drawImage(img, 0, 0, size, size);
    const { data } = ctx.getImageData(0, 0, size, size); // throws if tainted
    return extractDominantColors(data, size, size);
  } catch {
    return null;
  }
}
```

- [ ] **Step 2: Build**

Run: `cd desktop && npm run build`
Expected: exits 0, no tsc errors.

- [ ] **Step 3: Run logic tests (no new tests this step — confirms nothing broke)**

Run: `cd desktop && npm run test:logic`
Expected: PASS (unchanged from Task 4 — `drawEdgeVisualizer`/`sampleArtColors` are DOM-dependent and covered by Task 6's visual verification instead, matching the spec's testing plan).

- [ ] **Step 4: Commit**

```bash
git add desktop/src/visualizer.ts
git commit -m "Add edge-visualizer canvas draw and art-color sampling"
```

---

### Task 6: Wire the edge visualizer into the UI, remove the flat #viz strip

**Files:**
- Modify: `desktop/index.html:172-190` (art markup + `#viz` CSS), `desktop/src/ui.ts:775-872` (`vizLoop`/`drawViz`)

**Interfaces:**
- Consumes: `BeatFeed.edgeBins` (Task 3), `drawEdgeVisualizer`, `sampleArtColors` (Task 5).
- Produces: nothing further consumed — this is the final integration task.

- [ ] **Step 1: Replace the art markup and `#viz` CSS in `index.html`**

Replace:
```html
<div id="art">
  <span id="art-fallback">♫</span>
  <img id="art-img" hidden alt="" />
</div>
```
with:
```html
<div id="art-wrap">
  <canvas id="edge-viz"></canvas>
  <div id="art">
    <span id="art-fallback">♫</span>
    <img id="art-img" hidden alt="" />
  </div>
</div>
```

Remove the line `<canvas id="viz"></canvas>` (sits right before `<input id="progress" ...>`).

Replace the `#art` CSS block:
```css
#art {
  width: 168px; height: 168px; border-radius: 22px; overflow: hidden;
  background: var(--smoke-raised); border: 1px solid var(--seam);
  display: flex; align-items: center; justify-content: center;
  font-size: 46px; color: var(--bone-faint); margin: 10px 0 2px;
  flex: none; will-change: transform, box-shadow;
}
#art img { width: 100%; height: 100%; object-fit: cover; }
```
with:
```css
#art-wrap { position: relative; width: fit-content; margin: 10px 0 2px; }
#art {
  width: 208px; height: 208px; border-radius: 22px; overflow: hidden;
  background: var(--smoke-raised); border: 1px solid var(--seam);
  display: flex; align-items: center; justify-content: center;
  font-size: 46px; color: var(--bone-faint);
  flex: none; will-change: transform, box-shadow; position: relative; z-index: 1;
}
#art img { width: 100%; height: 100%; object-fit: cover; }
#edge-viz {
  position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%);
  width: 340px; height: 340px; pointer-events: none;
}
```

Remove the (now unused) `#viz` rule:
```css
#viz { width: 100%; height: 46px; display: block; margin: 0 0 10px; }
```

- [ ] **Step 2: Rewrite `vizLoop`/`drawViz` in `ui.ts`**

Add the import near the top of `desktop/src/ui.ts` (alongside the existing `beat.ts` import — find the line importing `BeatFeed`/`BeatOutput` and add beside it):

```typescript
import { drawEdgeVisualizer, sampleArtColors } from "./visualizer";
```

Replace the `// ── Beat visualizer (owner-side only — mirrors have no local audio) ────────` section (`ui.ts:775-872`) with:

```typescript
// ── Beat visualizer (owner-side only — mirrors have no local audio) ────────

let edgeVizCtx: CanvasRenderingContext2D | null = null;
let vizTrackId: string | null = null;
let vizIdle = true;
let artColors: string[] | null = null;
let artColorsForYt: string | null = null;

const ART_BOX = 208, ART_CORNER = 22, ART_MAX_BAR = 64;

function vizLoop(now: number) {
  requestAnimationFrame(vizLoop);
  const ownerPlaying = coord.role === "owner" && engine.player.playing;
  const btn = $("btn-toggle");
  const bpmChip = $("bpm");
  const art = $("art");

  if (!ownerPlaying) {
    if (!vizIdle) {
      vizIdle = true;
      const cv = $("edge-viz") as HTMLCanvasElement;
      edgeVizCtx?.clearRect(0, 0, cv.clientWidth, cv.clientHeight);
      btn.style.transform = "";
      btn.style.boxShadow = "";
      art.style.transform = "";
      art.style.boxShadow = "";
      bpmChip.classList.add("off");
    }
    return;
  }
  vizIdle = false;

  // First playing frame after a click — the gesture Web Audio needs.
  // attach() is async (worklet module load); frames until then just skip.
  if (!graph.attached) {
    if (!graph.attaching) {
      void graph.attach(engine.player.element).then(() => {
        beatFeed.bind(graph.analyser!, graph.sampleRate);
        ($("fx-pitch") as HTMLInputElement).disabled = !graph.pitchAvailable;
        applyFx(); // graph setters were no-ops before the graph existed
      });
    }
    return;
  }
  graph.resume();

  const curId = engine.player.current?.id ?? null;
  if (curId !== vizTrackId) {
    vizTrackId = curId;
    beatFeed.resetTrack(); // a new song is a new tempo — don't drag the old lock in
  }

  const out = beatFeed.tick(now);
  updateArtColors();
  drawEdgeViz(out);

  // The play button IS the head-nod: scale rides the phase-locked nod curve,
  // glow flashes on real hits. Inline styles override the CSS at 60 fps.
  btn.style.transform = `scale(${(1 + out.nod * 0.07).toFixed(4)})`;
  btn.style.boxShadow =
    `0 6px ${Math.round(24 + out.pulse * 30)}px rgba(241,43,38,${(0.45 + out.pulse * 0.4).toFixed(3)})`;

  // The thumbnail throbs on every beat — twin of the iOS PulsingThumbnailView,
  // with a shadow bloom that swells on the hit.
  art.style.transform = `scale(${(1 + out.pulse * 0.06).toFixed(4)})`;
  art.style.boxShadow =
    `0 ${Math.round(8 + out.pulse * 6)}px ${Math.round(22 + out.pulse * 26)}px rgba(0,0,0,${(0.45 + out.pulse * 0.35).toFixed(3)})`;

  if (out.confidence > 0.5) {
    bpmChip.classList.remove("off");
    bpmChip.textContent = `${Math.round(out.bpm)} bpm`;
  } else {
    bpmChip.classList.add("off");
  }
}

/** Re-samples art colors once per track change (not per-frame) — mirrors
 *  the iOS EdgeVisualizerView's precomputeBarColors-on-track-change. */
function updateArtColors() {
  const artYt = engine.player.current?.yt;
  if (artYt === artColorsForYt) return;
  artColorsForYt = artYt ?? null;
  const img = $("art-img") as HTMLImageElement;
  if (!artYt || img.hidden || !img.complete) { artColors = null; return; }
  artColors = sampleArtColors(img);
}

function drawEdgeViz(out: BeatOutput) {
  const cv = $("edge-viz") as HTMLCanvasElement;
  const dpr = window.devicePixelRatio || 1;
  const w = cv.clientWidth, h = cv.clientHeight;
  if (!w || !h) return;
  if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) {
    cv.width = Math.round(w * dpr);
    cv.height = Math.round(h * dpr);
    edgeVizCtx = cv.getContext("2d");
    edgeVizCtx?.setTransform(dpr, 0, 0, dpr, 0, 0); // resize resets ctx state
  }
  edgeVizCtx ??= cv.getContext("2d");
  const c = edgeVizCtx;
  if (!c) return;

  c.clearRect(0, 0, w, h);
  const pulseScale = 1 + out.pulse * 0.06; // matches the #art scale above
  drawEdgeVisualizer(c, ART_BOX * pulseScale, ART_CORNER * pulseScale, ART_MAX_BAR, beatFeed.edgeBins, artColors);
}
```

Note: `engine.player.current?.yt` — check the actual `Track`/queue-item type in `desktop/src/player.ts` for the correct field name if `yt` doesn't resolve (the art-loading code at `ui.ts:1082` uses `pb?.track?.yt`, i.e. the track ref from `coord.remote`, not `engine.player.current` — use `coord.remote?.playback.track?.yt` instead to match that existing pattern exactly, keeping a single source of truth for "what art is currently shown").

- [ ] **Step 3: Build**

Run: `cd desktop && npm run build`
Expected: exits 0, no tsc errors. If `engine.player.current?.yt` doesn't typecheck, fix per the note in Step 2 and rebuild.

- [ ] **Step 4: Run logic tests**

Run: `cd desktop && npm run test:logic`
Expected: PASS — all prior tests plus `beatBins.test.ts` and `visualizer.test.ts`.

- [ ] **Step 5: Visual verification via Electron MCP**

Relaunch the app (kill any prior debug instance first):
```bash
cd desktop && node scripts/launch-debug.js
```
Then:
- `mcp__electron__list_pages` — confirm the Pulsor page is present.
- `mcp__electron__take_screenshot` while a track is playing — confirm bars are visible wrapping the art, art still pulses, no `#viz` strip remnants, no console errors from a CORS-tainted canvas (check via `mcp__electron__get_console_message` or `list_console_messages` — a caught `SecurityError` should NOT appear as an uncaught error; if it does, `sampleArtColors`'s try/catch isn't catching it and needs fixing).
- Confirm the fallback path: temporarily note whether `artColors` end up `null` (red-gradient bars) or populated (art-colored bars) — either is an acceptable pass, per the spec's CORS-uncertainty note, but the app must not crash or leave the canvas blank either way.

- [ ] **Step 6: Commit**

```bash
git add desktop/index.html desktop/src/ui.ts
git commit -m "Wire the edge visualizer into the now-playing rail, remove flat #viz strip"
```
