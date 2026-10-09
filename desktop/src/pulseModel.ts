// Pulse-trainer neural net — pure TS, no deps. A small MLP that looks at a
// ±0.48 s window of feature frames (dense near the centre, sparse further
// out) and regresses the user's tap curve at the centre frame. It runs
// OFFLINE over a whole song, so it may look ahead — the art can hit exactly
// on the beat instead of reacting to it.
//
// Serialized as plain JSON (PulseModelJSON) so the iOS side can port the
// ~30 k weights + forward pass later without any ML runtime.
import { FEATURE_DIM, FEATURE_VERSION, FeatureTrack } from "./pulseFeatures";
import {
  Calibration, Clip, NORMAL_H, STRONG_H, clipFrames, clipTargets, f1,
  pickPeaks, scoreCurve, baselineCurve, Score,
} from "./pulseCurve";

export const OFFSETS = [
  -24, -20, -16, -12, -10, -8, -6, -5, -4, -3, -2, -1, 0,
  1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24,
];
export const INPUT_DIM = OFFSETS.length * FEATURE_DIM;
const H1 = 48, H2 = 24;

export interface PulseModelJSON {
  kind: "pulse-mlp";
  version: 1;
  featureVersion: number;
  offsets: number[];
  sizes: number[];               // [INPUT_DIM, H1, H2, 1]
  weights: number[][];           // W1, b1, W2, b2, W3, b3 (row-major, out × in)
  cal: Calibration;
  metrics: TrainMetrics;
}

export interface TrainMetrics {
  valF1: number; baseF1: number; trainF1: number;
  songs: number; clips: number; taps: number; valSongs: number;
  epochs: number; trainedAt: number;
}

/** Deterministic PRNG (mulberry32) — reproducible inits + shuffles in tests. */
export function rng(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export class PulseNet {
  W1 = new Float32Array(H1 * INPUT_DIM); b1 = new Float32Array(H1);
  W2 = new Float32Array(H2 * H1);        b2 = new Float32Array(H2);
  W3 = new Float32Array(H2);             b3 = new Float32Array(1);
  cal: Calibration = { thr: 0.3, hNormal: NORMAL_H * 0.7, hStrong: STRONG_H * 0.7 };

  // Scratch for one forward/backward pass.
  private x = new Float32Array(INPUT_DIM);
  private h1 = new Float32Array(H1); private h2 = new Float32Array(H2);
  private d1 = new Float32Array(H1); private d2 = new Float32Array(H2);

  get params(): Float32Array[] { return [this.W1, this.b1, this.W2, this.b2, this.W3, this.b3]; }

  init(seed = 1) {
    const r = rng(seed);
    const gauss = () => Math.sqrt(-2 * Math.log(r() + 1e-12)) * Math.cos(2 * Math.PI * r());
    const he = (w: Float32Array, fanIn: number) => {
      const s = Math.sqrt(2 / fanIn);
      for (let i = 0; i < w.length; i++) w[i] = gauss() * s;
    };
    he(this.W1, INPUT_DIM); he(this.W2, H1); he(this.W3, H2);
    this.b1.fill(0); this.b2.fill(0);
    this.b3[0] = -2.5; // pulses are rare — start predicting "no pulse"
    return this;
  }

  /** Gather the context window for frame f into this.x (zeros off the ends). */
  private gather(ft: FeatureTrack, f: number) {
    const D = FEATURE_DIM, x = this.x;
    for (let o = 0; o < OFFSETS.length; o++) {
      const g = f + OFFSETS[o], base = o * D;
      if (g < 0 || g >= ft.frames) { x.fill(0, base, base + D); continue; }
      const src = g * D;
      for (let d = 0; d < D; d++) x[base + d] = ft.data[src + d];
    }
  }

  /** Forward pass → logit; leaves activations in scratch for backward(). */
  private forward(ft: FeatureTrack, f: number): number {
    this.gather(ft, f);
    const { x, h1, h2, W1, b1, W2, b2, W3, b3 } = this;
    for (let j = 0; j < H1; j++) {
      let s = b1[j];
      const row = j * INPUT_DIM;
      for (let i = 0; i < INPUT_DIM; i++) s += W1[row + i] * x[i];
      h1[j] = s > 0 ? s : 0.01 * s; // leaky ReLU
    }
    for (let j = 0; j < H2; j++) {
      let s = b2[j];
      const row = j * H1;
      for (let i = 0; i < H1; i++) s += W2[row + i] * h1[i];
      h2[j] = s > 0 ? s : 0.01 * s;
    }
    let z = b3[0];
    for (let i = 0; i < H2; i++) z += W3[i] * h2[i];
    return z;
  }

  /** Accumulate gradients of weighted soft-BCE for one sample into g. */
  private backward(dz: number, g: Float32Array[]) {
    const { x, h1, h2, W2, W3, d1, d2 } = this;
    const [gW1, gb1, gW2, gb2, gW3, gb3] = g;
    gb3[0] += dz;
    for (let i = 0; i < H2; i++) {
      gW3[i] += dz * h2[i];
      d2[i] = dz * W3[i] * (h2[i] > 0 ? 1 : 0.01);
    }
    d1.fill(0);
    for (let j = 0; j < H2; j++) {
      const dj = d2[j];
      if (dj === 0) continue;
      gb2[j] += dj;
      const row = j * H1;
      for (let i = 0; i < H1; i++) { gW2[row + i] += dj * h1[i]; d1[i] += dj * W2[row + i]; }
    }
    for (let j = 0; j < H1; j++) {
      const dj = d1[j] * (h1[j] > 0 ? 1 : 0.01);
      if (dj === 0) continue;
      gb1[j] += dj;
      const row = j * INPUT_DIM;
      for (let i = 0; i < INPUT_DIM; i++) gW1[row + i] += dj * x[i];
    }
  }

  /** Sigmoid output for frames [from, to); 0 elsewhere. */
  predict(ft: FeatureTrack, from = 0, to = ft.frames): Float32Array {
    const out = new Float32Array(ft.frames);
    for (let f = Math.max(0, from); f < Math.min(ft.frames, to); f++) {
      out[f] = 1 / (1 + Math.exp(-this.forward(ft, f)));
    }
    return out;
  }

  /** One weighted-BCE training step on a minibatch; returns mean loss. */
  step(batch: { ft: FeatureTrack; f: number; y: number }[], opt: Adam): number {
    const g = this.params.map(p => new Float32Array(p.length));
    let loss = 0;
    for (const s of batch) {
      const z = this.forward(s.ft, s.f);
      const p = 1 / (1 + Math.exp(-z));
      const w = 1 + 3 * s.y; // taps are rare; make misses on them cost more
      loss += -w * (s.y * Math.log(p + 1e-7) + (1 - s.y) * Math.log(1 - p + 1e-7));
      this.backward(w * (p - s.y), g);
    }
    for (const gi of g) for (let i = 0; i < gi.length; i++) gi[i] /= batch.length;
    opt.update(this.params, g);
    return loss / batch.length;
  }

  toJSON(metrics: TrainMetrics): PulseModelJSON {
    return {
      kind: "pulse-mlp", version: 1, featureVersion: FEATURE_VERSION,
      offsets: OFFSETS, sizes: [INPUT_DIM, H1, H2, 1],
      weights: this.params.map(p => Array.from(p, v => Math.round(v * 1e6) / 1e6)),
      cal: this.cal, metrics,
    };
  }

  static fromJSON(j: PulseModelJSON): PulseNet | null {
    if (j?.kind !== "pulse-mlp" || j.featureVersion !== FEATURE_VERSION
        || j.sizes?.join() !== [INPUT_DIM, H1, H2, 1].join()
        || j.offsets?.join() !== OFFSETS.join()) return null;
    const n = new PulseNet();
    const ps = n.params;
    if (j.weights.length !== ps.length || j.weights.some((w, i) => w.length !== ps[i].length)) return null;
    j.weights.forEach((w, i) => ps[i].set(w));
    n.cal = j.cal;
    return n;
  }
}

export class Adam {
  private m: Float32Array[]; private v: Float32Array[]; private t = 0;
  constructor(params: Float32Array[], public lr = 1e-3, private wd = 1e-4) {
    this.m = params.map(p => new Float32Array(p.length));
    this.v = params.map(p => new Float32Array(p.length));
  }
  update(params: Float32Array[], grads: Float32Array[]) {
    this.t++;
    const b1 = 0.9, b2 = 0.999;
    const c1 = 1 - Math.pow(b1, this.t), c2 = 1 - Math.pow(b2, this.t);
    for (let k = 0; k < params.length; k++) {
      const p = params[k], g = grads[k], m = this.m[k], v = this.v[k];
      for (let i = 0; i < p.length; i++) {
        const gi = g[i] + this.wd * p[i];
        m[i] = b1 * m[i] + (1 - b1) * gi;
        v[i] = b2 * v[i] + (1 - b2) * gi * gi;
        p[i] -= (this.lr * (m[i] / c1)) / (Math.sqrt(v[i] / c2) + 1e-8);
      }
    }
  }
}

// ── Training orchestration ────────────────────────────────────────────────

export interface SongData { id: string; ft: FeatureTrack; clips: Clip[] }

export interface TrainOpts {
  maxEpochs?: number; patience?: number; batch?: number; seed?: number;
  negKeep?: number;   // fraction of near-zero frames sampled per epoch
  onProgress?: (p: { epoch: number; loss: number; valF1: number; baseF1: number }) => void;
  shouldStop?: () => boolean;
}

/** Song-level split when there are enough songs (honest generalization
 *  number); otherwise hold out the last quarter of every clip. */
export function splitData(songs: SongData[]): { train: SongData[]; val: SongData[]; valSongs: number } {
  const withTaps = songs.filter(s => s.clips.length);
  if (withTaps.length >= 6) {
    const hash = (s: string) => { let h = 2166136261; for (const c of s) h = Math.imul(h ^ c.charCodeAt(0), 16777619); return h >>> 0; };
    const sorted = [...withTaps].sort((a, b) => hash(a.id) - hash(b.id));
    const nVal = Math.max(1, Math.round(sorted.length * 0.2));
    return { val: sorted.slice(0, nVal), train: sorted.slice(nVal), valSongs: nVal };
  }
  const train: SongData[] = [], val: SongData[] = [];
  for (const s of withTaps) {
    const tr: Clip[] = [], va: Clip[] = [];
    for (const c of s.clips) {
      const cut = c.start + (c.end - c.start) * 0.75;
      tr.push({ ...c, end: cut, taps: c.taps.filter(t => t.t < cut) });
      va.push({ ...c, start: cut, taps: c.taps.filter(t => t.t >= cut) });
    }
    train.push({ ...s, clips: tr }); val.push({ ...s, clips: va });
  }
  return { train, val, valSongs: 0 };
}

function predictClips(net: PulseNet, s: SongData): Float32Array {
  const out = new Float32Array(s.ft.frames);
  for (const c of s.clips) {
    const [from, to] = clipFrames(c, s.ft.frames);
    const p = net.predict(s.ft, from - 5, to + 5);
    out.set(p.subarray(Math.max(0, from - 5), Math.min(s.ft.frames, to + 5)), Math.max(0, from - 5));
  }
  return out;
}

const sumScore = (a: Score, b: Score): Score =>
  ({ hits: a.hits + b.hits, pred: a.pred + b.pred, truth: a.truth + b.truth });

/** Best F1 over a threshold sweep for per-song curves. */
export function bestThreshold(curves: Float32Array[], songs: SongData[]): { thr: number; f1: number } {
  let best = { thr: 0.3, f1: -1 };
  for (let thr = 0.08; thr <= 0.8; thr += 0.02) {
    let s: Score = { hits: 0, pred: 0, truth: 0 };
    songs.forEach((song, i) => { s = sumScore(s, scoreCurve(curves[i], song.clips, thr)); });
    const v = f1(s);
    if (v > best.f1) best = { thr, f1: v };
  }
  return best;
}

/** Median raw peak height for matched normal / strong taps → amplitude map. */
function calibrateHeights(curves: Float32Array[], songs: SongData[], thr: number): { hNormal: number; hStrong: number } {
  const hn: number[] = [], hs: number[] = [];
  songs.forEach((s, i) => {
    for (const c of s.clips) {
      const [from, to] = clipFrames(c, curves[i].length);
      for (const p of pickPeaks(curves[i], thr, from, to)) {
        let best: { d: number; strong: boolean } | null = null;
        for (const t of c.taps) {
          const d = Math.abs(t.t - p.t);
          if (d <= 0.07 && (!best || d < best.d)) best = { d, strong: t.strong };
        }
        if (best) (best.strong ? hs : hn).push(p.h);
      }
    }
  });
  const med = (a: number[]) => { const s = [...a].sort((x, y) => x - y); return s[s.length >> 1]; };
  const hNormal = hn.length ? med(hn) : Math.max(thr, 0.4);
  const hStrong = hs.length >= 3 ? Math.max(med(hs), hNormal + 0.05) : hNormal + 0.25;
  return { hNormal, hStrong };
}

export function trainPulseNet(songs: SongData[], o: TrainOpts = {}): { net: PulseNet; json: PulseModelJSON } {
  const maxEpochs = o.maxEpochs ?? 30, patience = o.patience ?? 6, B = o.batch ?? 128;
  const negKeep = o.negKeep ?? 0.35;
  const r = rng(o.seed ?? 7);
  const { train, val, valSongs } = splitData(songs);
  const evalSet = val.some(s => s.clips.some(c => c.taps.length)) ? val : train;

  // All clip frames with targets.
  const samples: { ft: FeatureTrack; f: number; y: number }[] = [];
  for (const s of train) for (const c of s.clips) {
    const { from, y } = clipTargets(c, s.ft.frames);
    for (let i = 0; i < y.length; i++) samples.push({ ft: s.ft, f: from + i, y: y[i] });
  }
  if (!samples.length) throw new Error("No tapped clips to train on");

  // Baseline: the current BeatEngine, scored at its best threshold (generous).
  const baseCurves = evalSet.map(s => baselineCurve(s.ft));
  const baseF1 = bestThreshold(baseCurves, evalSet).f1;

  const net = new PulseNet().init(o.seed ?? 1);
  const opt = new Adam(net.params);
  let bestF1 = -1, bestParams = net.params.map(p => p.slice()), sinceBest = 0, epoch = 0;

  for (epoch = 1; epoch <= maxEpochs; epoch++) {
    if (o.shouldStop?.()) break;
    const ep = samples.filter(s => s.y > 0.05 || r() < negKeep);
    for (let i = ep.length - 1; i > 0; i--) { const j = Math.floor(r() * (i + 1)); [ep[i], ep[j]] = [ep[j], ep[i]]; }
    let loss = 0, n = 0;
    for (let i = 0; i < ep.length; i += B) { loss += net.step(ep.slice(i, i + B), opt); n++; }
    if (epoch === Math.round(maxEpochs * 0.6)) opt.lr *= 0.3;

    const curves = evalSet.map(s => predictClips(net, s));
    const { f1: vF1 } = bestThreshold(curves, evalSet);
    o.onProgress?.({ epoch, loss: loss / Math.max(1, n), valF1: vF1, baseF1 });
    if (vF1 > bestF1 + 1e-4) { bestF1 = vF1; bestParams = net.params.map(p => p.slice()); sinceBest = 0; }
    else if (++sinceBest >= patience) break;
  }
  net.params.forEach((p, i) => p.set(bestParams[i]));

  // Calibrate: threshold on the eval set; heights on everything tapped.
  const evalCurves = evalSet.map(s => predictClips(net, s));
  const { thr } = bestThreshold(evalCurves, evalSet);
  const all = songs.filter(s => s.clips.length);
  const allCurves = all.map(s => predictClips(net, s));
  net.cal = { thr, ...calibrateHeights(allCurves, all, thr) };
  const trainF1 = bestThreshold(train.map(s => predictClips(net, s)), train).f1;

  const json = net.toJSON({
    valF1: Math.max(0, bestF1), baseF1, trainF1,
    songs: all.length, clips: all.reduce((a, s) => a + s.clips.length, 0),
    taps: all.reduce((a, s) => a + s.clips.reduce((b, c) => b + c.taps.length, 0), 0),
    valSongs, epochs: Math.min(epoch, maxEpochs), trainedAt: Date.now(),
  });
  return { net, json };
}

