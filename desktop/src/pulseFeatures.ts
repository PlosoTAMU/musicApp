// Pulse-trainer audio features — pure (no DOM / Web Audio), so the trainer
// worker, the tests and the renderer all compute bit-identical frames.
//
// Input: mono PCM at FEATURE_SR (the renderer decodes through an
// OfflineAudioContext at that rate, which resamples for free). Output: one
// row of FEATURE_DIM floats per 20 ms frame, z-scored per song so loudness
// and mastering differences don't leak into the model:
//   0..15  log energy in 16 log-spaced bands (30 Hz – 10 kHz)
//   16..19 half-wave-rectified flux of those bands, grouped low→high in 4s
//   20     log RMS
//   21,22  tempo comb: flux summed at ±k·P (k=1..4) for the song's dominant
//          period P and P/2 — gives the net a beat grid that survives bars
//          where the kick drops out.

export const FEATURE_VERSION = 1;
export const FEATURE_SR = 22050;
export const FRAME_RATE = 50;                    // frames per second
export const HOP = FEATURE_SR / FRAME_RATE;      // 441 samples = 20 ms
export const FFT_SIZE = 1024;
export const N_BANDS = 16;
export const FEATURE_DIM = N_BANDS + 4 + 1 + 2;  // 23

export interface FeatureTrack {
  frames: number;          // row count
  dim: number;             // FEATURE_DIM
  data: Float32Array;      // frames × dim, row-major
  periodFrames: number;    // dominant beat period (frames, fractional), 0 if none
  flux: Float32Array;      // raw total flux per frame (baseline engine input)
  level: Float32Array;     // 0-1 loudness per frame (baseline engine gate)
}

// ── FFT (in-place radix-2, real input via complex buffer) ──────────────────

export function fftInPlace(re: Float64Array, im: Float64Array): void {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      let t = re[i]; re[i] = re[j]; re[j] = t;
      t = im[i]; im[i] = im[j]; im[j] = t;
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = (-2 * Math.PI) / len;
    const wr = Math.cos(ang), wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1, ci = 0;
      const half = len >> 1;
      for (let k = 0; k < half; k++) {
        const a = i + k, b = a + half;
        const xr = re[b] * cr - im[b] * ci;
        const xi = re[b] * ci + im[b] * cr;
        re[b] = re[a] - xr; im[b] = im[a] - xi;
        re[a] += xr; im[a] += xi;
        const ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr; cr = ncr;
      }
    }
  }
}

/** Strictly increasing FFT-bin edges for N_BANDS log bands. Pure. */
export function bandEdgeBins(): number[] {
  const binHz = FEATURE_SR / FFT_SIZE;
  const lo = Math.log(30), hi = Math.log(10_000);
  const edges: number[] = [];
  for (let i = 0; i <= N_BANDS; i++) {
    let b = Math.round(Math.exp(lo + ((hi - lo) * i) / N_BANDS) / binHz);
    if (i > 0 && b <= edges[i - 1]) b = edges[i - 1] + 1; // low bands: ≥1 bin each
    edges.push(Math.min(b, FFT_SIZE / 2));
  }
  return edges;
}

/** Dominant beat period in frames (fractional) from a flux envelope, via an
 *  autocorrelation with the same 120 BPM log-Gaussian tactus prior as
 *  BeatEngine. Returns 0 when the ACF is flat (no rhythm). */
export function estimatePeriod(flux: Float32Array): number {
  const n = flux.length;
  if (n < FRAME_RATE * 4) return 0;
  let mean = 0;
  for (let i = 0; i < n; i++) mean += flux[i];
  mean /= n;
  const minLag = Math.round(0.3 * FRAME_RATE), maxLag = Math.round(1.5 * FRAME_RATE);
  const acf = new Float64Array(maxLag + 2);
  for (let lag = minLag - 1; lag <= maxLag + 1; lag++) {
    let s = 0;
    for (let i = 0; i + lag < n; i++) s += (flux[i] - mean) * (flux[i + lag] - mean);
    acf[lag] = Math.max(0, s / (n - lag));
  }
  let best = 0, bestScore = 0, sum = 0;
  for (let lag = minLag; lag <= maxLag; lag++) {
    const prior = Math.exp(-0.5 * Math.pow(Math.log2(lag / FRAME_RATE / 0.5) / 0.9, 2));
    const harm = 2 * lag <= maxLag ? 0.45 * acf[2 * lag] : 0;
    const score = (acf[lag] + harm) * prior;
    sum += score;
    if (score > bestScore) { bestScore = score; best = lag; }
  }
  if (!best || bestScore <= 1.5 * (sum / (maxLag - minLag + 1))) return 0;
  // Parabolic refinement — 20 ms frames are too coarse to comb 4 beats out.
  const a = acf[best - 1], b = acf[best], c = acf[best + 1];
  const den = a - 2 * b + c;
  const off = den < 0 ? Math.max(-0.5, Math.min(0.5, 0.5 * (a - c) / den)) : 0;
  return best + off;
}

const sampleLinear = (x: Float32Array, t: number): number => {
  if (t < 0 || t > x.length - 1) return 0;
  const i = Math.floor(t), f = t - i;
  return i + 1 < x.length ? x[i] * (1 - f) + x[i + 1] * f : x[i];
};

function comb(flux: Float32Array, period: number, out: Float32Array) {
  if (period <= 0) { out.fill(0); return; }
  for (let t = 0; t < flux.length; t++) {
    let s = 0;
    for (let k = 1; k <= 4; k++) s += sampleLinear(flux, t - k * period) + sampleLinear(flux, t + k * period);
    out[t] = s / 8;
  }
}

/** Mono PCM at FEATURE_SR → per-song z-scored feature frames. Pure. */
export function extractFeatures(pcm: Float32Array): FeatureTrack {
  const frames = Math.max(0, Math.floor(pcm.length / HOP));
  const D = FEATURE_DIM;
  const data = new Float32Array(frames * D);
  const flux = new Float32Array(frames);
  const level = new Float32Array(frames);
  const edges = bandEdgeBins();
  const win = new Float64Array(FFT_SIZE);
  for (let i = 0; i < FFT_SIZE; i++) win[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / FFT_SIZE);
  const re = new Float64Array(FFT_SIZE), im = new Float64Array(FFT_SIZE);
  const prev = new Float64Array(N_BANDS);

  for (let f = 0; f < frames; f++) {
    // Window centred on the frame time (f · 20 ms), zero-padded at the edges.
    const start = f * HOP - FFT_SIZE / 2;
    let rms = 0;
    for (let i = 0; i < FFT_SIZE; i++) {
      const j = start + i;
      const v = j >= 0 && j < pcm.length ? pcm[j] : 0;
      rms += v * v;
      re[i] = v * win[i]; im[i] = 0;
    }
    fftInPlace(re, im);
    const row = f * D;
    let total = 0;
    for (let b = 0; b < N_BANDS; b++) {
      let p = 0;
      for (let k = edges[b]; k < edges[b + 1]; k++) p += re[k] * re[k] + im[k] * im[k];
      const l = Math.log10(1e-6 + p / (edges[b + 1] - edges[b]));
      data[row + b] = l;
      const d = f > 0 ? Math.max(0, l - prev[b]) : 0;
      data[row + N_BANDS + (b >> 2)] += d;
      total += d * (b < 4 ? 2 : b < 8 ? 1.5 : 1); // kick-weighted, like BeatFeed
      prev[b] = l;
    }
    rms = Math.sqrt(rms / FFT_SIZE);
    data[row + N_BANDS + 4] = Math.log10(1e-5 + rms);
    flux[f] = total;
    level[f] = Math.min(1, rms * 4);
  }

  const periodFrames = Math.fround(estimatePeriod(flux)); // float32: identical once cached
  const c1 = new Float32Array(frames), c2 = new Float32Array(frames);
  comb(flux, periodFrames, c1);
  comb(flux, periodFrames / 2, c2);
  for (let f = 0; f < frames; f++) {
    data[f * D + N_BANDS + 5] = c1[f];
    data[f * D + N_BANDS + 6] = c2[f];
  }

  // Per-song z-score per column, clamped so a single click can't dominate.
  for (let c = 0; c < D; c++) {
    let m = 0;
    for (let f = 0; f < frames; f++) m += data[f * D + c];
    m /= Math.max(1, frames);
    let v = 0;
    for (let f = 0; f < frames; f++) { const d = data[f * D + c] - m; v += d * d; }
    const sd = Math.sqrt(v / Math.max(1, frames)) || 1;
    for (let f = 0; f < frames; f++) {
      const z = (data[f * D + c] - m) / sd;
      data[f * D + c] = z > 5 ? 5 : z < -5 ? -5 : z;
    }
  }
  return { frames, dim: D, data, periodFrames, flux, level };
}

// ── Binary cache format: [magic, version, frames, dim, period] + data + flux + level

const MAGIC = 0x50554c53; // "PULS"

export function encodeFeatures(t: FeatureTrack): ArrayBuffer {
  const head = 5;
  const buf = new ArrayBuffer((head + t.data.length + 2 * t.frames) * 4);
  const u = new Uint32Array(buf, 0, 4);
  u[0] = MAGIC; u[1] = FEATURE_VERSION; u[2] = t.frames; u[3] = t.dim;
  new Float32Array(buf, 16, 1)[0] = t.periodFrames;
  const body = new Float32Array(buf, head * 4);
  body.set(t.data, 0);
  body.set(t.flux, t.data.length);
  body.set(t.level, t.data.length + t.frames);
  return buf;
}

export function decodeFeatures(buf: ArrayBuffer): FeatureTrack | null {
  if (buf.byteLength < 20) return null;
  const u = new Uint32Array(buf, 0, 4);
  if (u[0] !== MAGIC || u[1] !== FEATURE_VERSION || u[3] !== FEATURE_DIM) return null;
  const frames = u[2], dim = u[3];
  if (buf.byteLength !== (5 + frames * dim + 2 * frames) * 4) return null;
  const body = new Float32Array(buf, 20);
  return {
    frames, dim,
    periodFrames: new Float32Array(buf, 16, 1)[0],
    data: body.slice(0, frames * dim),
    flux: body.slice(frames * dim, frames * dim + frames),
    level: body.slice(frames * dim + frames),
  };
}
