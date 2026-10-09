// Pulse-trainer curve math — pure. Turns taps into training targets, model
// output into discrete pulse events, events into the 0-1 envelope the art
// rides, and scores predictions against taps (F1 with a ±70 ms window).
import { FRAME_RATE, FeatureTrack } from "./pulseFeatures";
import { BeatEngine } from "./beat";

export interface Tap { t: number; strong: boolean }          // song seconds
export interface Clip { start: number; end: number; taps: Tap[]; at: number }
export interface PulseEvent { t: number; amp: number }      // amp 0-1

/** Tap heights the net regresses to. Extra = full pulse; normal sits below
 *  so peak height alone encodes "pulse vs extra pulse". */
export const NORMAL_H = 0.6, STRONG_H = 1.0;
const SIGMA_FRAMES = 1.0;    // target bump width — ±20 ms is about human tap jitter
const MIN_GAP_FRAMES = 4;    // 80 ms: faster than anyone taps
export const MATCH_TOL_S = 0.07;

/** Clip → [firstFrame, endFrame) clamped to the song. */
export function clipFrames(c: Clip, frames: number): [number, number] {
  return [
    Math.max(0, Math.ceil(c.start * FRAME_RATE)),
    Math.min(frames, Math.floor(c.end * FRAME_RATE)),
  ];
}

/** Soft targets for the frames inside a clip: a Gaussian bump per tap. */
export function clipTargets(c: Clip, frames: number): { from: number; y: Float32Array } {
  const [from, to] = clipFrames(c, frames);
  const y = new Float32Array(Math.max(0, to - from));
  for (const tap of c.taps) {
    const h = tap.strong ? STRONG_H : NORMAL_H;
    const center = tap.t * FRAME_RATE;
    for (let f = Math.floor(center - 3); f <= Math.ceil(center + 3); f++) {
      if (f < from || f >= to) continue;
      const d = (f - center) / SIGMA_FRAMES;
      const v = h * Math.exp(-0.5 * d * d);
      if (v > y[f - from]) y[f - from] = v;
    }
  }
  return { from, y };
}

/** Local maxima ≥ thr, ≥ MIN_GAP apart, time refined by parabola. Returns
 *  { t seconds, h raw height }. Pure. */
export function pickPeaks(raw: Float32Array, thr: number, from = 0, to = raw.length): { t: number; h: number }[] {
  const out: { t: number; h: number }[] = [];
  let lastF = -1e9;
  for (let f = from; f < to; f++) {
    const v = raw[f];
    if (v < thr) continue;
    let isMax = true;
    for (let k = Math.max(from, f - MIN_GAP_FRAMES); k <= Math.min(to - 1, f + MIN_GAP_FRAMES); k++) {
      if (raw[k] > v || (raw[k] === v && k < f)) { isMax = false; break; }
    }
    if (!isMax || f - lastF < MIN_GAP_FRAMES) continue;
    const a = f > 0 ? raw[f - 1] : v, c = f + 1 < raw.length ? raw[f + 1] : v;
    const den = a - 2 * v + c;
    const off = den < 0 ? Math.max(-0.5, Math.min(0.5, 0.5 * (a - c) / den)) : 0;
    out.push({ t: (f + off) / FRAME_RATE, h: v });
    lastF = f;
  }
  return out;
}

/** Greedy one-to-one matching of predicted times to tap times. */
export function matchCount(pred: number[], truth: number[], tol = MATCH_TOL_S): number {
  const used = new Uint8Array(truth.length);
  let hits = 0;
  for (const p of pred) {
    let best = -1, bestD = tol;
    for (let i = 0; i < truth.length; i++) {
      if (used[i]) continue;
      const d = Math.abs(truth[i] - p);
      if (d <= bestD) { bestD = d; best = i; }
    }
    if (best >= 0) { used[best] = 1; hits++; }
  }
  return hits;
}

export interface Score { hits: number; pred: number; truth: number }
export const f1 = (s: Score) => (s.pred + s.truth ? (2 * s.hits) / (s.pred + s.truth) : 0);

/** Score a raw per-frame curve over a set of clips at one threshold. */
export function scoreCurve(raw: Float32Array, clips: Clip[], thr: number): Score {
  const s: Score = { hits: 0, pred: 0, truth: 0 };
  for (const c of clips) {
    const [from, to] = clipFrames(c, raw.length);
    const pred = pickPeaks(raw, thr, from, to).map(p => p.t);
    const truth = c.taps.map(t => t.t).filter(t => t >= c.start && t < c.end);
    s.hits += matchCount(pred, truth); s.pred += pred.length; s.truth += truth.length;
  }
  return s;
}

/** The current BeatEngine replayed over the feature track's flux at 50 fps —
 *  the "old visualizer" baseline the trainer reports the AI against. Its
 *  per-frame `pulse` output is what the art used to ride. */
export function baselineCurve(ft: FeatureTrack): Float32Array {
  const eng = new BeatEngine();
  const out = new Float32Array(ft.frames);
  let energy = 0;
  for (let f = 0; f < ft.frames; f++) {
    energy += (ft.level[f] - energy) * 0.1;
    out[f] = eng.process(ft.flux[f], energy, 1 / FRAME_RATE).pulse;
  }
  return out;
}

// ── Playback envelope ─────────────────────────────────────────────────────

export interface Calibration { thr: number; hNormal: number; hStrong: number }

/** Raw model curve → pulse events with amplitude mapped so a "normal"-sized
 *  prediction lands at NORMAL_H and an "extra" one at STRONG_H. */
export function curveToEvents(raw: Float32Array, cal: Calibration): PulseEvent[] {
  const span = Math.max(0.05, cal.hStrong - cal.hNormal);
  return pickPeaks(raw, cal.thr).map(p => ({
    t: p.t,
    amp: Math.max(0.3, Math.min(1, NORMAL_H + ((p.h - cal.hNormal) / span) * (STRONG_H - NORMAL_H))),
  }));
}

export const tapsToEvents = (taps: Tap[]): PulseEvent[] =>
  taps.map(t => ({ t: t.t, amp: t.strong ? STRONG_H : NORMAL_H })).sort((a, b) => a.t - b.t);

const ATTACK_S = 0.012;

/** 0-1 pulse at song time t: short ramp into each event, exponential decay
 *  (tau seconds) after; overlapping pulses take the max. Events sorted by t. */
export function envelopeAt(events: PulseEvent[], t: number, tau: number): number {
  // Last event that has started ramping by t.
  let lo = 0, hi = events.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (events[mid].t - ATTACK_S <= t) lo = mid + 1; else hi = mid;
  }
  let v = 0;
  for (let i = lo - 1; i >= 0; i--) {
    const dt = t - events[i].t;
    if (dt > tau * 7) break;
    const shape = dt < 0 ? 1 + dt / ATTACK_S : Math.exp(-dt / tau);
    const e = events[i].amp * shape;
    if (e > v) v = e;
  }
  return Math.min(1, v);
}
