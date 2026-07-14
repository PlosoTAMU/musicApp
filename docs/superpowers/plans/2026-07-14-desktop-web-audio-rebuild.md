# Desktop Web Audio Rebuild (P4: pitch, effects, crop) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild desktop playback onto one Web Audio graph so it gains iOS parity: pitch shift ±12 st (local-only), bass −10..+20 dB with iOS's 5-band shaping, per-track effect memory, and a crop *editor* with a CROPPED badge (plan items 18–22).

**Architecture:** A new `AudioGraph` module owns the single graph — `MediaElementSource → [pitch AudioWorklet] → 5-band EQ → analyser → dry/convolver-wet → destination` — mirroring the iOS chain `player → AVAudioUnitTimePitch → AVAudioUnitEQ(5) → reverb → mixer`. `BeatFeed` stops owning a graph and binds to the analyser read-only. Pitch is a hand-rolled streaming WSOLA-style granular shifter (pure DSP core, Node-testable; worklet wrapper bundled separately). Speed stays on the element (`playbackRate` + `preservesPitch`) so follower rate extrapolation is untouched. Per-track fx mirror iOS `TrackSettings` (local JSON, never synced). Crop editor writes `cropStartMs`/`cropEndMs` (or field-deletes) to the library doc exactly like iOS `pushMeta`.

**Tech Stack:** TypeScript, Electron 31 renderer (nodeIntegration on, AudioWorklet available), esbuild (second bundle entry for the worklet), Node for logic tests. **No new dependencies** — the pitch shifter is vendored in-repo (decided over soundtouch-js: the npm worklet build wants a decoded buffer, not a streaming `MediaElementSource`).

## Global Constraints

- **iOS is the source of truth for behavior** (`musicApp/AudioPlayerManager.swift`, `CropSongSheet.swift`); desktop mirrors it.
- **Do not change Firestore wire field names.** Settings doc stays `{ speed, bassDb, reverbPct, updatedBy, at }` — **pitch is NOT synced** (confirmed against `SettingsSync.swift`; per-track memory is local on both platforms). Crop fields stay `cropStartMs`/`cropEndMs` + `metaAt`/`metaBy`.
- **No display on the build box:** gate per change = `npx tsc --noEmit` green **and** `npm run bundle` green; DOM-free logic gets a Node test bundled via esbuild. GUI smoke is deferred to the user (checklist in `docs/arpi/smoke-test.md`).
- All shell commands run from `desktop/`. Logic-test bundles go to `$CLAUDE_JOB_DIR/tmp` (throwaway sources `desktop/_p4*.ts`, never committed).
- Commit messages end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Risk gate (from the phase plan):** if the pitch/graph rebuild balloons, stop and re-plan per NOTES § Failure.

---

## File Structure

- `desktop/src/fxMath.ts` — **create**: pure fx/crop math (`bassGains`, `clampCrop`, `clampStart`, `clampEnd`, `cropForSave`, `parseTime`, `fmtTime`).
- `desktop/src/pitchShifter.ts` — **create**: pure streaming WSOLA granular pitch shifter (`PitchShifter`).
- `desktop/src/pitchWorklet.ts` — **create**: AudioWorklet entry registering `pulsor-pitch`; bundled to `dist/pitchWorklet.js`.
- `desktop/src/audioGraph.ts` — **create**: `AudioGraph` — owns context + nodes; setters for bass/reverb/pitch; `makeImpulse` moves here from beat.ts.
- `desktop/src/trackFx.ts` — **create**: `TrackFxStore` — per-track `{speed,pitch,reverb,bass}`, localStorage-backed, injectable storage for tests.
- `desktop/src/cropSheet.ts` — **create**: crop editor modal (DOM), twin of `CropSongSheet.swift`.
- `desktop/src/beat.ts` — **modify**: `BeatFeed` loses graph ownership (attach/setBassDb/setReverbMix/resume/makeImpulse removed); gains `bind(analyser, sampleRate)`.
- `desktop/src/player.ts` — **modify**: `LocalPlayer.onTrack` hook (fires in `play()`).
- `desktop/src/replicator.ts` — **modify**: `setCrop(yt, r)` doc write.
- `desktop/src/ui.ts` — **modify**: `AudioGraph` wiring, fx.pitch, bass clamp −10..20, per-track fx restore/save, crop menu item + badge render.
- `desktop/index.html` — **modify**: bass slider range, pitch row, crop badge span, crop-modal CSS.
- `desktop/package.json` — **modify**: `bundle` script gains the worklet build.
- `docs/arpi/smoke-test.md`, `NOTES.md` — **modify** (Task 7).

---

## Task 1: Pure fx/crop math (`fxMath.ts`)

**Files:**
- Create: `desktop/src/fxMath.ts`
- Test: `desktop/_p4math.ts` (throwaway → `$CLAUDE_JOB_DIR/tmp/p4math.js`)

**Interfaces:**
- Produces: `bassGains(db: number): [number, number, number, number, number]` (Task 4),
  `clampCrop(start: number, end: number, full: number): { start: number; end: number }`,
  `clampStart(v: number, end: number): number`, `clampEnd(v: number, start: number, full: number): number`,
  `cropForSave(start: number, end: number, full: number): { startMs: number; endMs: number } | null`,
  `parseTime(text: string): number | undefined`, `fmtTime(s: number): string` (Task 6).

- [ ] **Step 1: Write the failing test** — `desktop/_p4math.ts`:

```ts
// Throwaway P4 logic gate (fxMath) — bundled via esbuild, run with node, deleted.
import { bassGains, clampCrop, clampStart, clampEnd, cropForSave, parseTime, fmtTime } from "./src/fxMath";

let pass = 0, fail = 0;
const eq = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);
function check(name: string, got: unknown, want: unknown) {
  if (eq(got, want)) pass++;
  else { fail++; console.log(`  FAIL ${name}\n    got  ${JSON.stringify(got)}\n    want ${JSON.stringify(want)}`); }
}
const round = (xs: number[]) => xs.map(x => Math.round(x * 100) / 100);

// bassGains — exact iOS applyBassBoost ratios (AudioPlayerManager.swift:1422)
check("bass 0", round(bassGains(0)), [0, 0, 0, 0, 0]);
check("bass 12 (moderate ratios)", round(bassGains(12)), [12, 7.2, -4.2, 1.8, 1.2]);
check("bass 20 (extreme ratios)", round(bassGains(20)), [20, 12, -8, 4, 2.4]);
check("bass cut: no mud/presence/air", round(bassGains(-10)), [-10, -6, 0, 0, 0]);

// clampCrop — iOS loadAudioDuration clamps
check("crop load clamp", clampCrop(-1, 200, 100), { start: 0, end: 100 });
check("crop load min gap", clampCrop(99.9, 100, 100), { start: 99.5, end: 100 });
// clampStart / clampEnd — iOS slider ranges (0...(end-0.5), (start+0.5)...full)
check("start capped at end-0.5", clampStart(80, 80.2), 79.7);
check("start floor 0", clampStart(-3, 60), 0);
check("end floor start+0.5", clampEnd(10, 10.2, 100), 10.7);
check("end capped at full", clampEnd(300, 0, 100), 100);

// cropForSave — iOS applyCrop's hasCrop (start > 0.1 || end < full - 0.1)
check("full range = no crop", cropForSave(0, 100, 100), null);
check("hairline = no crop", cropForSave(0.05, 99.95, 100), null);
check("real crop", cropForSave(5, 90, 100), { startMs: 5000, endMs: 90000 });
check("end-only crop keeps startMs 0", cropForSave(0, 50, 100), { startMs: 0, endMs: 50000 });

// parseTime — iOS CropSongSheet.parseTime
check("m:ss", parseTime("1:30"), 90);
check("raw seconds", parseTime("90"), 90);
check("bad seconds field", parseTime("1:75"), undefined);
check("garbage", parseTime("abc"), undefined);
check("0:05", parseTime("0:05"), 5);
check("negative", parseTime("-4"), undefined);

// fmtTime
check("fmt 0", fmtTime(0), "0:00");
check("fmt 90", fmtTime(90), "1:30");
check("fmt NaN", fmtTime(NaN), "0:00");

console.log(fail ? `FAIL ${fail} (pass ${pass})` : `PASS ${pass}/${pass}`);
process.exit(fail ? 1 : 0);
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx esbuild _p4math.ts --bundle --outfile=$CLAUDE_JOB_DIR/tmp/p4math.js --platform=node --format=cjs && node $CLAUDE_JOB_DIR/tmp/p4math.js`
Expected: esbuild ERROR — `Could not resolve "./src/fxMath"`.

- [ ] **Step 3: Implement** — `desktop/src/fxMath.ts`:

```ts
// Pure effect/crop math — Node-testable without a DOM (pattern of listOps/urls).

/** Twin of AudioPlayerManager.applyBassBoost's 5-band surgical shaping.
 *  db ∈ [−10, +20]; returns gains (dB) for
 *  [sub shelf 40 Hz, mid-bass 120 Hz, mud cut 300 Hz, presence 3 kHz, air 10 kHz].
 *  Cutting bass (db < 0) skips the compensation bands, exactly like iOS. */
export function bassGains(db: number): [number, number, number, number, number] {
  const sub = db;
  const mid = db * 0.6;
  if (db <= 0) return [sub, mid, 0, 0, 0];
  const extreme = db > 12; // iOS: past +12 dB the shaping gets more aggressive
  return [
    sub,
    mid,
    -db * (extreme ? 0.4 : 0.35),
    db * (extreme ? 0.2 : 0.15),
    db * (extreme ? 0.12 : 0.1),
  ];
}

// ── Crop window math (twin of CropSongSheet.swift) ─────────────────────────
// All values in SECONDS like iOS; ms conversion happens only at the doc write.

/** Loading clamp — iOS loadAudioDuration: keep ≥0.5 s of window inside the file. */
export function clampCrop(start: number, end: number, full: number): { start: number; end: number } {
  const s = Math.max(0, Math.min(start, full - 0.5));
  return { start: s, end: Math.max(s + 0.5, Math.min(end, full)) };
}

/** Start-slider clamp — iOS startSliderRange = 0...(end − 0.5). */
export const clampStart = (v: number, end: number): number =>
  Math.max(0, Math.min(v, end - 0.5));

/** End-slider clamp — iOS endSliderRange = (start + 0.5)...full. */
export const clampEnd = (v: number, start: number, full: number): number =>
  Math.min(full, Math.max(v, start + 0.5));

/** Twin of applyCrop's hasCrop: a near-full window means "no crop" (null). */
export function cropForSave(start: number, end: number, full: number):
    { startMs: number; endMs: number } | null {
  const hasCrop = start > 0.1 || end < full - 0.1;
  return hasCrop
    ? { startMs: Math.round(start * 1000), endMs: Math.round(end * 1000) }
    : null;
}

/** "m:ss" | "mm:ss" | raw seconds → seconds — twin of CropSongSheet.parseTime. */
export function parseTime(text: string): number | undefined {
  const t = text.trim();
  if (t.includes(":")) {
    const parts = t.split(":");
    if (parts.length !== 2) return undefined;
    const m = Number(parts[0]), s = Number(parts[1]);
    if (!Number.isInteger(m) || !Number.isInteger(s) || m < 0 || s < 0 || s >= 60)
      return undefined;
    return m * 60 + s;
  }
  const s = Number(t);
  return Number.isFinite(s) && s >= 0 && t !== "" ? s : undefined;
}

/** Seconds → "m:ss" — twin of CropSongSheet.formatTime. */
export function fmtTime(time: number): string {
  if (!Number.isFinite(time) || time < 0) return "0:00";
  const total = Math.floor(time);
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: same command as Step 2. Expected: `PASS 21/21`.

- [ ] **Step 5: Gate + commit**

Run: `npx tsc --noEmit && npm run bundle` — both green. Delete `desktop/_p4math.ts` **after Task 6** (later tasks extend it). Commit:

```bash
git add desktop/src/fxMath.ts
git commit -m "arpi P4: pure fx/crop math (iOS bassGains ratios, crop clamps, parseTime)"
```

---

## Task 2: Streaming pitch shifter core (`pitchShifter.ts`)

**Files:**
- Create: `desktop/src/pitchShifter.ts`
- Test: `desktop/_p4pitch.ts` (throwaway → `$CLAUDE_JOB_DIR/tmp/p4pitch.js`)

**Interfaces:**
- Produces: `class PitchShifter { setSemitones(st: number): void; process(input: Float32Array[], output: Float32Array[]): void }` — block-based, any block length, 1–2 input channels (mono duplicated), exactly 2 internal channels. `0 st` = exact passthrough. Consumed by Task 3's worklet.

- [ ] **Step 1: Write the failing test** — `desktop/_p4pitch.ts`:

```ts
// Throwaway P4 logic gate (pitch DSP) — sine in, frequency measured out.
import { PitchShifter } from "./src/pitchShifter";

let pass = 0, fail = 0;
function check(name: string, ok: boolean, detail = "") {
  if (ok) pass++; else { fail++; console.log(`  FAIL ${name} ${detail}`); }
}

const SR = 48000, BLOCK = 128;

function run(st: number, freq = 440, secs = 2): { out: Float32Array; inp: Float32Array } {
  const p = new PitchShifter();
  p.setSemitones(st);
  const n = Math.floor((SR * secs) / BLOCK) * BLOCK;
  const out = new Float32Array(n), inp = new Float32Array(n);
  const iL = new Float32Array(BLOCK), iR = new Float32Array(BLOCK);
  const oL = new Float32Array(BLOCK), oR = new Float32Array(BLOCK);
  for (let b = 0; b < n; b += BLOCK) {
    for (let i = 0; i < BLOCK; i++) iL[i] = iR[i] = Math.sin((2 * Math.PI * freq * (b + i)) / SR);
    p.process([iL, iR], [oL, oR]);
    out.set(oL, b);
    inp.set(iL, b);
  }
  return { out, inp };
}

/** Mean frequency from positive-going zero crossings over the steady tail. */
function measureHz(x: Float32Array, fromSec = 1): number {
  const from = Math.floor(fromSec * SR);
  let crossings = 0, first = -1, last = -1;
  for (let i = from + 1; i < x.length; i++) {
    if (x[i - 1] <= 0 && x[i] > 0) { crossings++; if (first < 0) first = i; last = i; }
  }
  return crossings < 2 ? 0 : ((crossings - 1) * SR) / (last - first);
}
const rms = (x: Float32Array, from: number) => {
  let s = 0; for (let i = from; i < x.length; i++) s += x[i] * x[i];
  return Math.sqrt(s / (x.length - from));
};

// 0 st — bit-exact passthrough
{
  const { out, inp } = run(0);
  let same = true;
  for (let i = 0; i < out.length; i++) if (out[i] !== inp[i]) { same = false; break; }
  check("0 st is exact passthrough", same);
}
// +12 st — 440 → ~880 Hz
{
  const { out } = run(12);
  const hz = measureHz(out);
  check("+12 st doubles frequency", Math.abs(hz - 880) / 880 < 0.05, `hz=${hz.toFixed(1)}`);
  check("+12 st no NaN", out.every(Number.isFinite));
  const r = rms(out, SR);
  check("+12 st energy sane", r > 0.35 && r < 1.1, `rms=${r.toFixed(3)}`); // sine rms ≈ 0.707
}
// −12 st — 440 → ~220 Hz
{
  const { out } = run(-12);
  const hz = measureHz(out);
  check("-12 st halves frequency", Math.abs(hz - 220) / 220 < 0.05, `hz=${hz.toFixed(1)}`);
}
// +7 st — 440 → ~659.3 Hz
{
  const { out } = run(7);
  const hz = measureHz(out);
  check("+7 st ratio", Math.abs(hz - 659.3) / 659.3 < 0.05, `hz=${hz.toFixed(1)}`);
}
// mid-stream engage: 1 s at 0 st then flip to +12 — stays finite, ends near 880
{
  const p = new PitchShifter();
  const n = SR * 2, out = new Float32Array(n);
  const iL = new Float32Array(BLOCK), oL = new Float32Array(BLOCK), oR = new Float32Array(BLOCK);
  for (let b = 0; b < n; b += BLOCK) {
    if (b === SR) p.setSemitones(12);
    for (let i = 0; i < BLOCK; i++) iL[i] = Math.sin((2 * Math.PI * 440 * (b + i)) / SR);
    p.process([iL], [oL, oR]);
    out.set(oL, b);
  }
  check("mid-stream engage no NaN", out.every(Number.isFinite));
  const hz = measureHz(out, 1.5);
  check("mid-stream engage reaches 880", Math.abs(hz - 880) / 880 < 0.05, `hz=${hz.toFixed(1)}`);
}

console.log(fail ? `FAIL ${fail} (pass ${pass})` : `PASS ${pass}/${pass}`);
process.exit(fail ? 1 : 0);
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx esbuild _p4pitch.ts --bundle --outfile=$CLAUDE_JOB_DIR/tmp/p4pitch.js --platform=node --format=cjs && node $CLAUDE_JOB_DIR/tmp/p4pitch.js`
Expected: esbuild ERROR — `Could not resolve "./src/pitchShifter"`.

- [ ] **Step 3: Implement** — `desktop/src/pitchShifter.ts`:

```ts
// Streaming granular (WSOLA-style) pitch shifter — the DSP core behind the
// "pulsor-pitch" AudioWorklet. Pure Float32 math: no DOM, no Web Audio —
// Node-testable like listOps/urls.
//
// Output is rebuilt from Hann-windowed grains overlap-added every HOP samples.
// Each grain reads the input ring resampled by f = 2^(st/12), so pitch moves
// while time stays 1:1 (grain anchors and output both advance by HOP per
// grain). Anchors are refined WSOLA-style: a small cross-correlation search
// against the standing overlap tail picks a phase-aligned start, avoiding the
// comb/tremolo artifacts of naive granular shifting. 0 st is an exact
// zero-latency passthrough; shifting adds ~GRAIN·2 samples (~95 ms @48 kHz)
// of latency — inaudible for a music player, and the position clock reads the
// media element, not the graph.

export const GRAIN = 2048;     // ~43 ms @48 kHz — SoundTouch "sequence" ballpark
export const HOP = GRAIN / 2;  // Hann at 50 % overlap sums to 1 (COLA)
const SEEK = 384;              // ± input-anchor search radius (samples)
const SEEK_STEP = 16;
const RING_LEN = 16384;        // power of two ≫ GRAIN·2 + SEEK + one block
const LATENCY = GRAIN * 2 + SEEK + 128; // input lead a grain needs at f ≤ 2

function hann(n: number): Float32Array {
  const w = new Float32Array(n);
  for (let i = 0; i < n; i++) w[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / n);
  return w;
}

export class PitchShifter {
  private st = 0;
  private f = 1; // resample factor 2^(st/12)

  private ring = [new Float32Array(RING_LEN), new Float32Array(RING_LEN)];
  private written = 0;  // total input samples ever pushed
  private anchor = 0;   // nominal input position of the next grain
  private ola = [new Float32Array(GRAIN), new Float32Array(GRAIN)];
  private win = hann(GRAIN);
  // Synthesized output waiting to be emitted in caller-sized blocks.
  private fifo = [new Float32Array(RING_LEN), new Float32Array(RING_LEN)];
  private fifoHead = 0;
  private fifoLen = 0;

  setSemitones(st: number) {
    if (st === this.st) return;
    const wasBypass = this.st === 0;
    this.st = st;
    this.f = Math.pow(2, st / 12);
    if (st === 0) { this.fifoHead = 0; this.fifoLen = 0; return; } // back to passthrough
    if (wasBypass) {
      // Engage: anchor into the already-buffered history so shifting starts
      // ~LATENCY behind the live edge without a silence gap.
      this.ola[0].fill(0); this.ola[1].fill(0);
      this.fifoHead = 0; this.fifoLen = 0;
      this.anchor = Math.max(0, this.written - LATENCY);
    }
  }

  /** One audio block. input/output are per-channel arrays of equal length;
   *  mono input feeds both internal channels. Always writes the ring (even in
   *  bypass) so engaging mid-track has history to anchor into. */
  process(input: Float32Array[], output: Float32Array[]) {
    const inL = input[0], inR = input[1] ?? input[0];
    if (!inL) { for (const o of output) o.fill(0); return; }
    this.push(inL, inR);
    if (this.st === 0) { // exact passthrough
      output[0]?.set(inL);
      output[1]?.set(inR);
      return;
    }
    const n = output[0]?.length ?? inL.length;
    while (this.fifoLen < n) this.synthesize();
    this.pop(output, n);
  }

  // ── input ring ────────────────────────────────────────────────────────────

  private push(l: Float32Array, r: Float32Array) {
    for (let i = 0; i < l.length; i++) {
      const w = (this.written + i) & (RING_LEN - 1);
      this.ring[0][w] = l[i];
      this.ring[1][w] = r[i];
    }
    this.written += l.length;
  }

  /** Linear-interpolated read at a fractional absolute position. */
  private read(ch: 0 | 1, pos: number): number {
    if (pos < 0 || pos >= this.written - 1) return 0;
    const i0 = Math.floor(pos), fr = pos - i0;
    const r = this.ring[ch];
    return r[i0 & (RING_LEN - 1)] * (1 - fr) + r[(i0 + 1) & (RING_LEN - 1)] * fr;
  }

  // ── synthesis ─────────────────────────────────────────────────────────────

  /** Overlap-add one grain (when enough input lead exists) and emit HOP
   *  samples. Warm-up right after engage emits the accumulator as-is. */
  private synthesize() {
    if (this.written >= this.anchor + GRAIN * this.f + SEEK) {
      const a = this.seekAnchor();
      for (let ch = 0 as 0 | 1; ch < 2; ch = (ch + 1) as 0 | 1) {
        const ola = this.ola[ch];
        for (let k = 0; k < GRAIN; k++) {
          ola[k] += this.read(ch, a + k * this.f) * this.win[k];
        }
        if (ch === 1) break;
      }
      this.anchor += HOP;
    }
    for (let ch = 0; ch < 2; ch++) {
      const ola = this.ola[ch], fifo = this.fifo[ch];
      for (let k = 0; k < HOP; k++) {
        fifo[(this.fifoHead + this.fifoLen + k) & (RING_LEN - 1)] = ola[k];
      }
      ola.copyWithin(0, HOP);
      ola.fill(0, HOP);
    }
    this.fifoLen += HOP;
  }

  /** WSOLA search: slide the candidate grain start ±SEEK and keep the offset
   *  whose (windowed, resampled) opening best correlates with the standing
   *  overlap tail — in-phase addition instead of cancellation. */
  private seekAnchor(): number {
    const nominal = this.anchor;
    const refL = this.ola[0], refR = this.ola[1];
    let refEnergy = 0;
    for (let j = 0; j < HOP; j += 4) { const v = refL[j] + refR[j]; refEnergy += v * v; }
    if (refEnergy < 1e-6) return nominal; // first grain — nothing to align to
    const lo = Math.max(0, nominal - SEEK);
    let best = nominal, bestScore = -Infinity;
    for (let c = lo; c <= nominal + SEEK; c += SEEK_STEP) {
      let dot = 0, energy = 1e-9;
      for (let j = 0; j < HOP; j += 4) {
        const p = c + j * this.f;
        const s = (this.read(0, p) + this.read(1, p)) * this.win[j];
        dot += s * (refL[j] + refR[j]);
        energy += s * s;
      }
      const score = dot / Math.sqrt(energy);
      if (score > bestScore) { bestScore = score; best = c; }
    }
    return best;
  }

  private pop(output: Float32Array[], n: number) {
    for (let ch = 0; ch < Math.min(2, output.length); ch++) {
      const fifo = this.fifo[ch], out = output[ch];
      for (let i = 0; i < n; i++) out[i] = fifo[(this.fifoHead + i) & (RING_LEN - 1)];
    }
    this.fifoHead = (this.fifoHead + n) & (RING_LEN - 1);
    this.fifoLen -= n;
  }
}
```

(Note the `synthesize` channel loop: write it as a plain `for (let ch = 0; ch < 2; ch++)` with `ch as 0 | 1` at the `read` call if the `0 | 1` gymnastics annoy — behavior identical.)

- [ ] **Step 4: Run to verify it passes**

Run: same command as Step 2. Expected: `PASS 8/8`. If a frequency check misses by a hair (>5 %), inspect with a printout before touching the DSP — the measurement tail must skip the ~95 ms warm-up.

- [ ] **Step 5: Gate + commit**

Run: `npx tsc --noEmit && npm run bundle` — green.

```bash
git add desktop/src/pitchShifter.ts
git commit -m "arpi P4: streaming WSOLA granular pitch shifter core (item 20 DSP)"
```

---

## Task 3: AudioWorklet entry + second bundle

**Files:**
- Create: `desktop/src/pitchWorklet.ts`
- Modify: `desktop/package.json` (`scripts.bundle`)

**Interfaces:**
- Consumes: `PitchShifter` (Task 2).
- Produces: `dist/pitchWorklet.js` registering processor **`"pulsor-pitch"`** with a k-rate AudioParam **`semitones`** (−12..12, default 0). Loaded by Task 4's `AudioGraph`.

- [ ] **Step 1: Implement** — `desktop/src/pitchWorklet.ts`:

```ts
// AudioWorklet entry — bundled separately (dist/pitchWorklet.js) and loaded
// via audioWorklet.addModule from a Blob URL. Runs in the
// AudioWorkletGlobalScope: no DOM, no require — everything bundles in.
import { PitchShifter } from "./pitchShifter";

// The DOM lib has no worklet-scope types; declare the minimum we touch.
declare class AudioWorkletProcessor {
  readonly port: MessagePort;
  constructor();
}
declare function registerProcessor(name: string, ctor: unknown): void;

class PulsorPitchProcessor extends AudioWorkletProcessor {
  static get parameterDescriptors() {
    return [{
      name: "semitones", defaultValue: 0, minValue: -12, maxValue: 12,
      automationRate: "k-rate" as const,
    }];
  }

  private shifter = new PitchShifter();

  process(inputs: Float32Array[][], outputs: Float32Array[][],
          parameters: Record<string, Float32Array>): boolean {
    const input = inputs[0], output = outputs[0];
    if (!output?.length) return true;
    if (!input?.length) { for (const o of output) o.fill(0); return true; }
    this.shifter.setSemitones(parameters.semitones?.[0] ?? 0);
    this.shifter.process(input, output);
    return true;
  }
}

registerProcessor("pulsor-pitch", PulsorPitchProcessor);
```

- [ ] **Step 2: Extend the bundle script** — `desktop/package.json`, replace the `bundle` line:

```json
"bundle": "esbuild src/ui.ts --bundle --outfile=dist/bundle.js --platform=browser --format=cjs --external:electron --external:fs --external:path --external:crypto --external:child_process --external:url --external:os && esbuild src/pitchWorklet.ts --bundle --outfile=dist/pitchWorklet.js --platform=browser --format=iife",
```

- [ ] **Step 3: Gate**

Run: `npx tsc --noEmit && npm run bundle`
Expected: green; `dist/pitchWorklet.js` exists and contains `registerProcessor("pulsor-pitch"`.
(`electron-builder` already packs `dist/**` — no packaging change needed.)

- [ ] **Step 4: Commit**

```bash
git add desktop/src/pitchWorklet.ts desktop/package.json
git commit -m "arpi P4: pulsor-pitch AudioWorklet entry + second esbuild bundle"
```

---

## Task 4: One graph — `AudioGraph`, `BeatFeed.bind`, ui/index rewiring (items 18–20)

**Files:**
- Create: `desktop/src/audioGraph.ts`
- Modify: `desktop/src/beat.ts` (BeatFeed + delete `makeImpulse`), `desktop/src/ui.ts` (fx object, `applyFx`, `bindFx` wiring, `initFxSliders`, `settingsSync.onRemote`, `vizLoop`), `desktop/index.html` (bass range, pitch row)

**Interfaces:**
- Consumes: `bassGains` (Task 1), `dist/pitchWorklet.js` (Task 3).
- Produces: `class AudioGraph { attach(el: HTMLAudioElement): Promise<void>; attached: boolean; attaching: boolean; sampleRate: number; pitchAvailable: boolean; analyser?: AnalyserNode; setBassDb(db: number): void; setReverbMix(mix: number): void; setPitchSemitones(st: number): void; resume(): void }`;
  `BeatFeed.bind(analyser: AnalyserNode, sampleRate: number): void`. `fx.pitch: number` exists on the ui fx object (Task 5 persists it per-track).

- [ ] **Step 1: Create `desktop/src/audioGraph.ts`**

```ts
// The ONE Web Audio graph (P4 item 18) — twin of the iOS engine chain
// player → AVAudioUnitTimePitch → AVAudioUnitEQ(5) → reverb → mixer:
//
//   src → [pitch worklet] → eq×5 → analyser → dry ──────────┐
//                                    └→ convolver → wet ────┴→ destination
//
// Owns the AudioContext and every DSP node. BeatFeed binds to `analyser`
// read-only; ui.ts drives the setters from the fx sliders. Speed stays on the
// media element (playbackRate + preservesPitch) so follower rate
// extrapolation is untouched. The pitch worklet is optional: if
// dist/pitchWorklet.js can't load, the chain builds without it and
// `pitchAvailable` stays false (the slider disables).
import * as fs from "fs";
import * as path from "path";
import { bassGains } from "./fxMath";

// iOS band layout (setupAudioEngine). AVAudioUnitEQ bandwidth is octaves;
// biquad peaking Q = 1 / (2·sinh(ln2/2 · BW)) — precomputed here.
const EQ_BANDS: { type: BiquadFilterType; freq: number; q?: number }[] = [
  { type: "lowshelf",  freq: 40 },            // sub-bass shelf (chest thump)
  { type: "peaking",   freq: 120,  q: 1.17 }, // mid-bass bell, BW 1.2 oct
  { type: "peaking",   freq: 300,  q: 0.92 }, // mud cut, BW 1.5 oct
  { type: "peaking",   freq: 3000, q: 1.41 }, // presence, BW 1.0 oct
  { type: "highshelf", freq: 10000 },         // air shelf
];

/** Exponentially-decaying stereo noise burst — a compact synthetic room. */
function makeImpulse(ctx: AudioContext, seconds: number, decay: number): AudioBuffer {
  const len = Math.floor(ctx.sampleRate * seconds);
  const buf = ctx.createBuffer(2, len, ctx.sampleRate);
  for (let ch = 0; ch < 2; ch++) {
    const d = buf.getChannelData(ch);
    for (let i = 0; i < len; i++) {
      d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, decay);
    }
  }
  return buf;
}

export class AudioGraph {
  /** False when the worklet failed to load — ui disables the pitch slider. */
  pitchAvailable = false;
  analyser?: AnalyserNode;

  private ctx?: AudioContext;
  private eq: BiquadFilterNode[] = [];
  private dry?: GainNode;
  private wet?: GainNode;
  private pitch?: AudioWorkletNode;
  private attachP?: Promise<void>;

  get attached() { return !!this.analyser; }
  get attaching() { return !!this.attachP; }
  get sampleRate() { return this.ctx?.sampleRate ?? 48000; }

  /** Idempotent; call from a user gesture. Once createMediaElementSource
   *  runs, the element's audio routes through this context permanently. */
  attach(el: HTMLAudioElement): Promise<void> {
    return (this.attachP ??= this.build(el));
  }

  private async build(el: HTMLAudioElement) {
    const ctx = (this.ctx = new AudioContext());

    // Worklet first — the graph wires once, so the source isn't created
    // until we know whether a pitch node exists to splice in. Loaded from a
    // Blob URL (fs read) because module-fetching file:// URLs is CORS-hostile.
    try {
      const code = fs.readFileSync(path.join(__dirname, "pitchWorklet.js"), "utf8");
      const url = URL.createObjectURL(new Blob([code], { type: "text/javascript" }));
      try { await ctx.audioWorklet.addModule(url); }
      finally { URL.revokeObjectURL(url); }
      this.pitch = new AudioWorkletNode(ctx, "pulsor-pitch",
        { numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [2] });
      this.pitchAvailable = true;
    } catch (e) {
      console.log("[audio] pitch worklet unavailable — pitch disabled:", e);
    }

    const src = ctx.createMediaElementSource(el);

    for (const b of EQ_BANDS) {
      const f = ctx.createBiquadFilter();
      f.type = b.type;
      f.frequency.value = b.freq;
      if (b.q !== undefined) f.Q.value = b.q;
      f.gain.value = 0;
      this.eq.push(f);
    }

    this.analyser = ctx.createAnalyser(); // fftSize etc. set by BeatFeed.bind

    this.dry = ctx.createGain();
    this.wet = ctx.createGain();
    this.wet.gain.value = 0;
    const convolver = ctx.createConvolver();
    convolver.buffer = makeImpulse(ctx, 2.2, 2.8);

    let head: AudioNode = src;
    if (this.pitch) { src.connect(this.pitch); head = this.pitch; }
    for (const f of this.eq) { head.connect(f); head = f; }
    head.connect(this.analyser);
    this.analyser.connect(this.dry);
    this.dry.connect(ctx.destination);
    this.analyser.connect(convolver);
    convolver.connect(this.wet);
    this.wet.connect(ctx.destination);
  }

  /** −10..+20 dB — iOS's 5-band surgical shaping via bassGains(). */
  setBassDb(db: number) {
    const g = bassGains(db);
    this.eq.forEach((f, i) => { f.gain.value = g[i]; });
  }

  /** 0–1 reverb mix. Dry ducks slightly as wet rises so loudness stays sane. */
  setReverbMix(mix: number) {
    if (this.wet) this.wet.gain.value = mix * 0.9;
    if (this.dry) this.dry.gain.value = 1 - mix * 0.35;
  }

  /** ±12 st; 0 = exact passthrough. Local-only — iOS doesn't sync pitch. */
  setPitchSemitones(st: number) {
    const p = this.pitch?.parameters.get("semitones");
    if (p) p.value = st;
  }

  /** The play click is the user gesture — a suspended context would mute the
   *  routed element, so resume aggressively. */
  resume() {
    if (this.ctx?.state === "suspended") void this.ctx.resume();
  }
}
```

- [ ] **Step 2: Slim `BeatFeed` down to analysis** — `desktop/src/beat.ts`:

1. Delete `makeImpulse` (moved to audioGraph.ts) and the `// ── Web Audio feeder` graph plumbing.
2. In `BeatFeed`, delete fields `ctx`, `bass`, `dry`, `wet`; delete methods `attach`, `get attached`, `setBassDb`, `setReverbMix`, `resume`. Add field `private analyser?: AnalyserNode;` (kept), `private sampleRate = 48000;` and:

```ts
  /** Bind to the AudioGraph's analyser — a read-only tap. Idempotent. */
  bind(analyser: AnalyserNode, sampleRate: number) {
    if (this.analyser) return;
    analyser.fftSize = 2048;
    analyser.smoothingTimeConstant = 0; // engine + bins do their own smoothing
    this.analyser = analyser;
    this.sampleRate = sampleRate;
    this.freq = new Uint8Array(analyser.frequencyBinCount);
    this.prevLog = new Float32Array(analyser.frequencyBinCount);

    // Log-spaced band edges 40 Hz → 14 kHz for the display bins.
    const binHz = sampleRate / analyser.fftSize;
    const lo = Math.log(40), hi = Math.log(14_000);
    this.bandEdges = Array.from({ length: DISPLAY_BINS + 1 }, (_, i) => {
      const hz = Math.exp(lo + ((hi - lo) * i) / DISPLAY_BINS);
      return Math.max(1, Math.min(analyser.frequencyBinCount - 1, Math.round(hz / binHz)));
    });
  }

  get bound() { return !!this.analyser; }
```

3. In `tick()`, replace `const binHz = this.ctx!.sampleRate / a.fftSize;` with `const binHz = this.sampleRate / a.fftSize;`.
4. Update the file-header comment's BeatFeed line: it now *binds to* the shared graph's analyser instead of owning a graph.

- [ ] **Step 3: Rewire `ui.ts`**

1. Imports: add `import { AudioGraph } from "./audioGraph";` and after `const beatFeed = new BeatFeed();` add `const graph = new AudioGraph();`.
2. fx object — add pitch to the base + type:

```ts
const fx = ((): { volume: number; speed: number; pitch: number; bass: number;
                  reverb: number; bypass: boolean } => {
  const base = { volume: 1, speed: 1, pitch: 0, bass: 0, reverb: 0, bypass: false };
  try { return { ...base, ...JSON.parse(localStorage.getItem(FX_KEY) ?? "{}") }; }
  catch { return base; }
})();
```

3. `wire()` — after the `bindFx("fx-speed", …)` line add (pitch is local-only: **no** `pushSettingsDebounced`):

```ts
  bindFx("fx-pitch", v => { fx.pitch = v; });
```

4. `settingsSync.onRemote` — align the bass clamp to iOS (`SettingsSync.swift` applyRemote):

```ts
    fx.bass = Math.min(Math.max(s.bassDb, -10), 20);
```

5. `applyFx()` — replace the two `beatFeed.set…` calls and the bass label; add pitch:

```ts
  graph.setBassDb(fx.bypass ? 0 : fx.bass);
  graph.setReverbMix(fx.bypass ? 0 : fx.reverb);
  graph.setPitchSemitones(fx.bypass ? 0 : fx.pitch);
```

and in the label block:

```ts
  $("fx-pitch-val").textContent = `${fx.pitch > 0 ? "+" : ""}${fx.pitch}st`;
  $("fx-bass-val").textContent = `${fx.bass > 0 ? "+" : ""}${fx.bass}dB`;
```

6. `initFxSliders()` — add:

```ts
  ($("fx-pitch") as HTMLInputElement).value = String(fx.pitch);
```

7. `vizLoop()` — replace the attach block

```ts
  // First playing frame after a click — the gesture Web Audio needs.
  if (!beatFeed.attached) {
    beatFeed.attach(engine.player.element);
    applyFx(); // bass/reverb setters were no-ops before the graph existed
  }
  beatFeed.resume();
```

with:

```ts
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
```

- [ ] **Step 4: `index.html`** — in the `#fx` block: change the bass slider to `min="-10" max="20"`, and insert a Pitch row between Speed and Bass:

```html
          <div class="fx-row"><span>Pitch</span>
            <input id="fx-pitch" type="range" min="-12" max="12" value="0" step="0.5" />
            <span class="fx-val" id="fx-pitch-val">0st</span></div>
```

- [ ] **Step 5: Gate**

Run: `npx tsc --noEmit && npm run bundle`
Expected: green. tsc failing on any leftover `beatFeed.attach/setBassDb/setReverbMix/resume` call = a missed rewire site; fix until green.

- [ ] **Step 6: Commit**

```bash
git add desktop/src/audioGraph.ts desktop/src/beat.ts desktop/src/ui.ts desktop/index.html
git commit -m "arpi P4: one Web Audio graph — pitch worklet + iOS 5-band bass (-10..+20) + clamp fix (items 18-20)"
```

---

## Task 5: Per-track effect memory (`trackFx.ts`, item 21)

**Files:**
- Create: `desktop/src/trackFx.ts`
- Modify: `desktop/src/player.ts` (`onTrack` hook), `desktop/src/ui.ts` (restore/save wiring)
- Test: extend `desktop/_p4math.ts`-style throwaway: `desktop/_p4fx.ts`

**Interfaces:**
- Consumes: fx object + `applyFx`/`initFxSliders`/`pushSettingsDebounced` (Task 4 state of ui.ts).
- Produces: `interface TrackFx { speed: number; pitch: number; reverb: number; bass: number }`, `DEFAULT_FX: TrackFx`, `class TrackFxStore { constructor(storage: StorageLike, key?: string); get(id: string): TrackFx; set(id: string, fx: TrackFx): void }`; `LocalPlayer.onTrack?: (t: LocalTrack) => void`.

- [ ] **Step 1: Write the failing test** — `desktop/_p4fx.ts`:

```ts
// Throwaway P4 logic gate (per-track fx store).
import { TrackFxStore, DEFAULT_FX } from "./src/trackFx";

let pass = 0, fail = 0;
const eq = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);
function check(name: string, got: unknown, want: unknown) {
  if (eq(got, want)) pass++;
  else { fail++; console.log(`  FAIL ${name}\n    got  ${JSON.stringify(got)}\n    want ${JSON.stringify(want)}`); }
}

const mem = () => {
  const m = new Map<string, string>();
  return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v), dump: m };
};

// unknown track → defaults (twin of iOS applyTrackSettings' else-branch)
{
  const s = new TrackFxStore(mem());
  check("defaults", s.get("A1"), { speed: 1, pitch: 0, reverb: 0, bass: 0 });
}
// roundtrip + persistence across instances
{
  const st = mem();
  const s = new TrackFxStore(st);
  s.set("A1", { speed: 1.5, pitch: -2, reverb: 0.3, bass: 6 });
  check("roundtrip", s.get("A1"), { speed: 1.5, pitch: -2, reverb: 0.3, bass: 6 });
  const s2 = new TrackFxStore(st);
  check("persists", s2.get("A1"), { speed: 1.5, pitch: -2, reverb: 0.3, bass: 6 });
}
// id compare is case-insensitive (UUIDs arrive uppercase from iOS)
{
  const s = new TrackFxStore(mem());
  s.set("ab-CD", { speed: 2, pitch: 0, reverb: 0, bass: 0 });
  check("case-insensitive id", s.get("AB-cd").speed, 2);
}
// writing pure defaults prunes the entry (keeps the store lean)
{
  const st = mem();
  const s = new TrackFxStore(st);
  s.set("A1", { speed: 1.5, pitch: 0, reverb: 0, bass: 0 });
  s.set("A1", { ...DEFAULT_FX });
  check("defaults prune", st.dump.get("fx.tracks.v1"), "{}");
}
// corrupted storage → clean slate
{
  const st = mem();
  st.setItem("fx.tracks.v1", "{nope");
  check("corrupt json tolerated", new TrackFxStore(st).get("A1"), DEFAULT_FX);
}

console.log(fail ? `FAIL ${fail} (pass ${pass})` : `PASS ${pass}/${pass}`);
process.exit(fail ? 1 : 0);
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx esbuild _p4fx.ts --bundle --outfile=$CLAUDE_JOB_DIR/tmp/p4fx.js --platform=node --format=cjs && node $CLAUDE_JOB_DIR/tmp/p4fx.js`
Expected: esbuild ERROR — `Could not resolve "./src/trackFx"`.

- [ ] **Step 3: Implement** — `desktop/src/trackFx.ts`:

```ts
// Per-track effect memory — twin of AudioPlayerManager.TrackSettings
// (track_settings.json): speed/pitch/reverb/bass restore when a track plays.
// Local-only on BOTH platforms (never synced); volume and bypass stay global,
// also like iOS. Storage is injected so the store is Node-testable.

export interface TrackFx { speed: number; pitch: number; reverb: number; bass: number }
export const DEFAULT_FX: TrackFx = { speed: 1, pitch: 0, reverb: 0, bass: 0 };

interface StorageLike {
  getItem(k: string): string | null;
  setItem(k: string, v: string): void;
}

export class TrackFxStore {
  private map: Record<string, TrackFx>;

  constructor(private storage: StorageLike, private key = "fx.tracks.v1") {
    try { this.map = JSON.parse(storage.getItem(key) ?? "{}"); }
    catch { this.map = {}; }
  }

  /** Absent track → iOS defaults (1× / 0 st / 0 % / 0 dB). */
  get(id: string): TrackFx {
    return { ...DEFAULT_FX, ...this.map[id.toLowerCase()] };
  }

  set(id: string, fx: TrackFx) {
    const k = id.toLowerCase();
    if (fx.speed === DEFAULT_FX.speed && fx.pitch === DEFAULT_FX.pitch
        && fx.reverb === DEFAULT_FX.reverb && fx.bass === DEFAULT_FX.bass) {
      delete this.map[k]; // default settings = no entry, same restore outcome
    } else {
      this.map[k] = { ...fx };
    }
    this.storage.setItem(this.key, JSON.stringify(this.map));
  }
}
```

- [ ] **Step 4: Run to verify it passes** — same command; expected `PASS 6/6`.

- [ ] **Step 5: Player hook** — `desktop/src/player.ts`, in `LocalPlayer` add below `onChange?: () => void;`:

```ts
  /** Fires whenever play() starts a track — ui.ts restores per-track fx here
   *  (twin of iOS applyTrackSettings being called from play(_:)). */
  onTrack?: (t: LocalTrack) => void;
```

and in `play()` insert `this.onTrack?.(t);` immediately after `this.current = t;`.

- [ ] **Step 6: ui.ts wiring**

1. Import + instance (top, near other singletons):

```ts
import { TrackFxStore } from "./trackFx";
const trackFx = new TrackFxStore(localStorage);
```

2. In `wire()` (next to the other `engine.player` hookups in the rail section is fine; anywhere before first play):

```ts
  // Per-track fx restore — twin of iOS applyTrackSettings. Restoring also
  // republishes the (speed/bass/reverb) settings doc: like iOS, the sync
  // carries "whichever effective settings are currently audible".
  engine.player.onTrack = t => {
    const s = trackFx.get(t.id);
    fx.speed = s.speed; fx.pitch = s.pitch; fx.reverb = s.reverb; fx.bass = s.bass;
    initFxSliders(); // slider DOM + applyFx()
    pushSettingsDebounced();
  };
```

3. In `applyFx()`, before the `localStorage.setItem(FX_KEY, …)` line, save the audible values to the current track (mirrors iOS saveCurrentTrackSettings on every didSet):

```ts
  const cur = engine.player.current;
  if (cur) trackFx.set(cur.id, { speed: fx.speed, pitch: fx.pitch, reverb: fx.reverb, bass: fx.bass });
```

- [ ] **Step 7: Gate + commit**

Run: `npx tsc --noEmit && npm run bundle` — green. Delete `desktop/_p4fx.ts`.

```bash
git add desktop/src/trackFx.ts desktop/src/player.ts desktop/src/ui.ts
git commit -m "arpi P4: per-track effect memory (speed/pitch/reverb/bass, item 21)"
```

---

## Task 6: Crop editor + badge (item 22)

**Files:**
- Create: `desktop/src/cropSheet.ts`
- Modify: `desktop/src/replicator.ts` (`setCrop`), `desktop/src/ui.ts` (menu item, `editCrop`, badge), `desktop/index.html` (badge span + crop CSS)

**Interfaces:**
- Consumes: `clampCrop/clampStart/clampEnd/cropForSave/parseTime/fmtTime` (Task 1), `replicator.cropFor` (existing), `engine.player.setCrop` (existing).
- Produces: `showCropSheet(o: CropSheetOpts)`; `Replicator.setCrop(yt: string, r: { startMs: number; endMs: number } | null): Promise<void>`.

- [ ] **Step 1: Create `desktop/src/cropSheet.ts`**

```ts
// Crop editor modal — desktop twin of musicApp/CropSongSheet.swift.
// Preview runs on a second throwaway <audio> (like iOS's throwaway
// AVAudioPlayer) looping inside [start, end]; the main player is paused for
// the duration. Apply hands the window (or null = uncropped) to ui.ts, which
// writes the library doc. All DOM, no Firestore.
import { clampCrop, clampStart, clampEnd, cropForSave, parseTime, fmtTime } from "./fxMath";

export interface CropSheetOpts {
  name: string;
  fileUrl: string;
  crop: { startMs?: number; endMs?: number };
  volume: number;
  /** Pause the main player if it's playing here; return whether it was. */
  pauseMain: () => boolean;
  resumeMain: () => void;
  onApply: (r: { startMs: number; endMs: number } | null) => void;
}

export function showCropSheet(o: CropSheetOpts) {
  const overlay = document.createElement("div");
  overlay.className = "modal-overlay";
  overlay.innerHTML = `
    <div class="modal-card crop-card">
      <h4></h4>
      <div class="crop-meta"><span class="crop-full">Loading…</span><span class="crop-len"></span></div>
      <input class="crop-seek" type="range" min="0" max="1" value="0" step="0.1" />
      <div class="crop-times"><span class="crop-pos">0:00</span><span class="crop-rem">-0:00</span></div>
      <div class="crop-transport">
        <button class="row-btn crop-rew" title="Back 5s">−5s</button>
        <button class="pill crop-play">Play</button>
        <button class="row-btn crop-fwd" title="Forward 5s">+5s</button>
        <button class="row-btn crop-hear-end" title="Hear the last 3s">End</button>
      </div>
      <div class="crop-row"><span>Start</span>
        <input class="crop-start" type="range" min="0" max="1" step="0.1" />
        <button class="crop-chip crop-start-t">0:00</button></div>
      <div class="crop-row"><span>End</span>
        <input class="crop-end" type="range" min="0" max="1" step="0.1" />
        <button class="crop-chip crop-end-t">0:00</button></div>
      <div class="modal-actions">
        <button class="link crop-reset">Reset</button>
        <span class="spacer" style="flex:1"></span>
        <button class="link modal-cancel">Cancel</button>
        <button class="pill modal-ok">Apply Crop</button>
      </div>
    </div>`;

  const q = <T extends HTMLElement>(sel: string) => overlay.querySelector(sel) as T;
  q<HTMLElement>("h4").textContent = `Crop “${o.name}”`;

  const seek = q<HTMLInputElement>(".crop-seek");
  const startR = q<HTMLInputElement>(".crop-start");
  const endR = q<HTMLInputElement>(".crop-end");

  let full = 0, start = 0, end = 0;
  const wasPlaying = o.pauseMain();

  const audio = new Audio(o.fileUrl);
  audio.preload = "auto";
  audio.volume = o.volume;

  const fill = (el: HTMLInputElement, v: number) =>
    el.style.setProperty("--fill", `${full > 0 ? (v / full) * 100 : 0}%`);

  const syncUi = () => {
    q(".crop-len").textContent = `✂ ${fmtTime(Math.max(0, end - start))}`;
    startR.value = String(start);
    endR.value = String(end);
    q(".crop-start-t").textContent = fmtTime(start);
    q(".crop-end-t").textContent = fmtTime(end);
    fill(startR, start);
    fill(endR, end);
  };

  const tick = () => {
    if (audio.currentTime >= end && end > 0) audio.currentTime = start; // loop the window
    seek.value = String(audio.currentTime);
    fill(seek, audio.currentTime);
    q(".crop-pos").textContent = fmtTime(audio.currentTime);
    q(".crop-rem").textContent = `-${fmtTime(Math.max(0, end - audio.currentTime))}`;
    q(".crop-play").textContent = audio.paused ? "Play" : "Pause";
  };
  const loopTimer = setInterval(() => { if (!audio.paused) tick(); }, 40);

  const close = () => {
    clearInterval(loopTimer);
    audio.pause();
    audio.removeAttribute("src");
    overlay.remove();
    if (wasPlaying) o.resumeMain();
  };

  const playFrom = (t: number) => {
    audio.currentTime = Math.max(start, Math.min(t, end));
    if (audio.paused) void audio.play().catch(() => {});
    tick();
  };

  audio.onloadedmetadata = () => {
    full = Number.isFinite(audio.duration) ? audio.duration : 0;
    ({ start, end } = clampCrop((o.crop.startMs ?? 0) / 1000,
      o.crop.endMs != null ? o.crop.endMs / 1000 : full, full));
    seek.max = startR.max = endR.max = String(full);
    q(".crop-full").textContent = `Full ${fmtTime(full)}`;
    audio.currentTime = start;
    syncUi();
    tick();
  };
  audio.onerror = () => { q(".crop-full").textContent = "Unable to read this audio file"; };

  q(".crop-play").onclick = () => {
    if (audio.paused) playFrom(audio.currentTime > start ? audio.currentTime : start);
    else { audio.pause(); tick(); }
  };
  q(".crop-rew").onclick = () => playFrom(audio.currentTime - 5);
  q(".crop-fwd").onclick = () => playFrom(audio.currentTime + 5);
  q(".crop-hear-end").onclick = () => playFrom(end - 3);
  seek.oninput = () => playFrom(Number(seek.value));

  // Sliders clamp like the iOS ranges; releasing previews the boundary
  // (start → from start, end → the last 3 s), like iOS's editing-ended hooks.
  startR.oninput = () => { start = clampStart(Number(startR.value), end); syncUi(); };
  startR.onchange = () => playFrom(start);
  endR.oninput = () => { end = clampEnd(Number(endR.value), start, full); syncUi(); };
  endR.onchange = () => playFrom(end - 3);

  // Tappable time chips → inline "m:ss" input (twin of the iOS text fields).
  const editChip = (chip: HTMLButtonElement, apply: (secs: number) => void) => {
    chip.onclick = () => {
      const inp = document.createElement("input");
      inp.className = "crop-chip-input";
      inp.value = chip.textContent ?? "";
      chip.replaceWith(inp);
      inp.focus();
      inp.select();
      let done = false;
      const finish = (commit: boolean) => {
        if (done) return;
        done = true;
        const t = commit ? parseTime(inp.value) : undefined;
        inp.replaceWith(chip);
        if (t !== undefined) apply(t);
        syncUi();
      };
      inp.onkeydown = e => {
        if (e.key === "Enter") finish(true);
        if (e.key === "Escape") finish(false);
      };
      inp.onblur = () => finish(true);
    };
  };
  editChip(q<HTMLButtonElement>(".crop-start-t"), t => { start = clampStart(t, end); playFrom(start); });
  editChip(q<HTMLButtonElement>(".crop-end-t"), t => { end = clampEnd(t, start, full); playFrom(end - 3); });

  q(".crop-reset").onclick = () => { start = 0; end = full; syncUi(); playFrom(0); };
  q<HTMLButtonElement>(".modal-cancel").onclick = close;
  q<HTMLButtonElement>(".modal-ok").onclick = () => {
    if (!full) { close(); return; } // metadata never loaded — nothing to save
    o.onApply(cropForSave(start, end, full));
    close();
  };
  overlay.onmousedown = e => { if (e.target === overlay) close(); };

  document.body.appendChild(overlay);
}
```

- [ ] **Step 2: `Replicator.setCrop`** — `desktop/src/replicator.ts`: add `deleteField` to the firebase/firestore import list, then below `cropFor`:

```ts
  /** Push a crop window (null = uncropped) to the track's library doc — twin
   *  of iOS pushMeta's crop fields (absent = FieldValue.delete()). The
   *  snapshot echo re-applies it locally via onCropChanged. */
  async setCrop(yt: string, r: { startMs: number; endMs: number } | null) {
    if (!this.uid) return;
    const entry = [...this.meta.entries()].find(([, m]) => m.yt === yt && !m.deleted);
    if (!entry) return;
    await updateDoc(doc(this.db, "users", this.uid, "library", entry[0]), {
      cropStartMs: r ? r.startMs : deleteField(),
      cropEndMs: r ? r.endMs : deleteField(),
      metaAt: serverTimestamp(), metaBy: DEVICE_ID,
    }).catch(() => {});
  }
```

- [ ] **Step 3: ui.ts glue**

1. Import: `import { showCropSheet } from "./cropSheet";`
2. Below `redownloadTrack`, add:

```ts
/** Open the crop editor — twin of iOS CropSongSheet. Needs the cloud doc
 *  (crop is `cropStartMs/cropEndMs` on the library doc, keyed by yt). */
function editCrop(t: LocalTrack) {
  if (!t.yt || coord.demo) { showHint("Crop needs a cloud-synced track"); return; }
  showCropSheet({
    name: t.name,
    fileUrl: pathToFileURL(t.path).href,
    crop: replicator.cropFor(t.yt),
    volume: fx.volume,
    pauseMain: () => {
      const was = coord.role === "owner" && engine.player.playing;
      if (was) engine.pause();
      return was;
    },
    resumeMain: () => engine.play(),
    onApply: r => {
      void replicator.setCrop(t.yt!, r);
      // Twin of iOS applyCrop's restart-with-new-crop when it's the live track:
      // apply the window immediately (the doc echo re-applies it) and restart.
      if (coord.role === "owner" && engine.player.current?.yt === t.yt) {
        engine.player.setCrop(r?.startMs, r?.endMs);
        engine.seekMs(0);
        engine.publish();
      }
      renderNow();
      showHint(r ? "Crop saved" : "Crop removed");
    },
  });
}
```

3. `trackMenu` — after the `Rename…` item, add:

```ts
  if (t.yt && !coord.demo)
    items.push({ label: "Crop…", onClick: () => editCrop(t) });
```

4. `renderNow()` — after the `$("track-title").textContent = …` line, add the badge toggle (works for owner and follower — `cropFor` reads the synced meta):

```ts
  const badgeYt = pb?.track ? (resolve(pb.track, engine.library)?.yt ?? pb.track.yt) : undefined;
  const cw = badgeYt ? replicator.cropFor(badgeYt) : {};
  $("crop-badge").hidden = cw.startMs == null && cw.endMs == null;
```

- [ ] **Step 4: `index.html`**

1. Badge — inside `<div id="track-name">`, after the `#track-title` span:

```html
          <span id="crop-badge" class="chip" hidden>✂ Cropped</span>
```

2. CSS — append near the modal styles:

```css
    /* ── Crop editor modal (twin of iOS CropSongSheet) ──────────────────── */
    .crop-card { width: 480px; }
    .crop-meta { display: flex; justify-content: space-between; font-size: 12px;
                 color: var(--bone-dim); margin-bottom: 10px; }
    .crop-meta .crop-len { color: var(--red-light); font-weight: 600; }
    .crop-times { display: flex; justify-content: space-between; font-size: 11px;
                  font-variant-numeric: tabular-nums; color: var(--bone-dim); }
    .crop-transport { display: flex; align-items: center; justify-content: center;
                      gap: 12px; margin: 12px 0 16px; }
    .crop-transport .pill { width: auto; padding: 8px 26px; font-size: 14px; }
    .crop-transport .row-btn { opacity: 1; }
    .crop-row { display: grid; grid-template-columns: 40px 1fr 64px; gap: 10px;
                align-items: center; font-size: 12px; color: var(--bone-dim);
                margin-top: 8px; }
    .crop-chip { background: var(--smoke-raised); border: 1px solid var(--seam);
                 border-radius: 999px; color: var(--red-light); font: inherit;
                 font-size: 12px; font-variant-numeric: tabular-nums;
                 padding: 3px 10px; cursor: pointer; }
    .crop-chip-input { width: 64px; font: inherit; font-size: 12px;
                       color: var(--bone); background: var(--ink);
                       border: 1px solid var(--seam); border-radius: 999px;
                       padding: 3px 10px; outline: none; text-align: center; }
```

- [ ] **Step 5: Gate + commit**

Run: `npx tsc --noEmit && npm run bundle` — green. Delete `desktop/_p4math.ts` (Task 1's note).

```bash
git add desktop/src/cropSheet.ts desktop/src/replicator.ts desktop/src/ui.ts desktop/index.html
git commit -m "arpi P4: crop editor + CROPPED badge (item 22)"
```

---

## Task 7: Smoke checklist + NOTES

**Files:**
- Modify: `docs/arpi/smoke-test.md` (append Phase 4 section), `NOTES.md`

- [ ] **Step 1: Append to `docs/arpi/smoke-test.md`** (match the existing per-phase format):

```markdown
## Phase 4 — Web Audio rebuild (pitch, effects, crop)

Setup: connected desktop with a local library; phone nearby for the sync checks.

- [ ] Play a track; move **Pitch** to +7 — melody rises, tempo unchanged; back to 0 — bit-exact clean audio (passthrough).
- [ ] Pitch −12/+12: audible artifacts acceptable (granular), no dropouts/silence; beat viz keeps drawing.
- [ ] **Speed** at 1.5× with pitch 0 — chipmunk-free (preservesPitch), followers' progress bars track correctly.
- [ ] **Bass** slider now −10..+20: at +20 no mud (300 Hz scoop working); at −10 thinner, no boost artifacts. Phone → desktop: set bass +18 on iOS, desktop applies +18 (clamp fix).
- [ ] **Reverb** unchanged from P3 behavior; **fx bypass** (rail button) neutralizes speed+pitch+bass+reverb, sliders keep values.
- [ ] **Per-track memory**: set 1.5×/+3 st/+10 dB on song A; play song B (defaults); back to A — sliders + audio restore; relaunch app, play A — still restored.
- [ ] Track change while phone follows: desktop's restored speed/bass/reverb push to the phone (audible-settings sync), pitch does NOT appear on iOS.
- [ ] **Crop editor** (⋯ → Crop… on a YouTube track): sliders + m:ss chips clamp (start ≤ end−0.5); preview loops inside the window; −5s/+5s/End buttons; Reset; Apply.
- [ ] After Apply: rail shows ✂ CROPPED; playback duration = cropped length; iOS sees the same crop (doc round-trip); Reset+Apply removes crop + badge both sides.
- [ ] Crop the currently-playing track → it restarts inside the new window without a stall.
- [ ] Pitch worklet failure fallback: temporarily rename dist/pitchWorklet.js → app still plays, pitch slider disabled, everything else works.
```

- [ ] **Step 2: Update `NOTES.md`**

- DONE: add a **Phase 4** line (graph consolidation, pitch worklet, bass range+clamp, per-track fx, crop editor + badge; test counts).
- DECISIONS (append):
  - `2026-07-14 P4 pitch = hand-rolled streaming WSOLA granular shifter in an AudioWorklet (desktop/src/pitchShifter.ts), NOT vendored soundtouch-js — the npm worklet build wants a decoded buffer, not a MediaElementSource stream; pure core is Node-testable. Pitch is local-only (iOS doesn't sync it) and adds ~95 ms latency only while active (0 st = exact passthrough).`
  - `2026-07-14 P4 graph ownership moved beat.ts → audioGraph.ts; BeatFeed only binds the analyser. Speed stays on the element (playbackRate+preservesPitch) so follower extrapolation is untouched.`
  - `2026-07-14 P4 crop editor gated to yt-bearing tracks (crop lives on the yt-keyed library doc; local-only files have no doc to carry it) — recorded as a known iOS-parity edge.`
- OPEN: remove the two resolved items (pitch-library choice; crop preview player question).
- VERIFY STRATEGY: unchanged.

- [ ] **Step 3: Commit**

```bash
git add docs/arpi/smoke-test.md NOTES.md
git commit -m "arpi P4: done - smoke checklist + NOTES"
```

---

## Self-Review Notes

- **Coverage:** item 18 = Task 4 (AudioGraph + BeatFeed.bind); item 19 = Task 4 (slider range, clamp, bassGains); item 20 = Tasks 2–4 (DSP, worklet, wiring; local-only confirmed); item 21 = Task 5; item 22 = Task 6 (editor, doc write incl. field-delete, badge, live-track restart). Verification per phase plan = smoke checklist (Task 7) + logic gates (Tasks 1, 2, 5).
- **Types:** `bassGains` tuple consumed positionally by `AudioGraph.setBassDb`; `TrackFx` field names match the ui fx object subset; `showCropSheet` returns void and communicates via `onApply(cropForSave(...))` whose `{startMs,endMs}|null` matches `Replicator.setCrop`'s parameter.
- **Known accepted risks:** granular pitch quality < AVAudioUnitTimePitch (artifacts at extreme shifts — acceptable, noted in smoke list); analyser sees post-EQ signal (same as pre-P4 behavior); ~95 ms audio-path latency while pitch ≠ 0 (position clock unaffected).
