// Pulse trainer logic gate: FFT, tempo, feature cache, curve math, and an
// end-to-end learn test — synthetic songs (kick/snare/hats) where the
// simulated user taps ONLY the kicks (extra pulse on the downbeat). The net
// must learn that rule well enough to beat the old BeatEngine, which pulses
// on every onset, and must rank downbeats above beat 3.
import {
  fftInPlace, estimatePeriod, extractFeatures, encodeFeatures, decodeFeatures,
  FEATURE_SR, FRAME_RATE, FEATURE_DIM, bandEdgeBins,
} from "../src/pulseFeatures";
import {
  Clip, clipTargets, pickPeaks, matchCount, envelopeAt, tapsToEvents, curveToEvents, NORMAL_H,
} from "../src/pulseCurve";
import { PulseNet, trainPulseNet, rng, SongData, splitData } from "../src/pulseModel";

let n = 0;
function ok(name: string, cond: boolean, detail = "") {
  n++;
  if (!cond) throw new Error(`${name}: expected true ${detail}`);
}
const near = (a: number, b: number, tol: number) => Math.abs(a - b) <= tol;

// ── FFT vs naive DFT ───────────────────────────────────────────────────────
{
  const N = 64, r = rng(3);
  const x = Array.from({ length: N }, () => r() * 2 - 1);
  const re = Float64Array.from(x), im = new Float64Array(N);
  fftInPlace(re, im);
  let maxErr = 0;
  for (let k = 0; k < N; k++) {
    let sr = 0, si = 0;
    for (let t = 0; t < N; t++) { sr += x[t] * Math.cos(-2 * Math.PI * k * t / N); si += x[t] * Math.sin(-2 * Math.PI * k * t / N); }
    maxErr = Math.max(maxErr, Math.abs(sr - re[k]), Math.abs(si - im[k]));
  }
  ok("fft matches DFT", maxErr < 1e-9, `err ${maxErr}`);
  const e = bandEdgeBins();
  ok("band edges strictly increasing", e.every((v, i) => i === 0 || v > e[i - 1]));
}

// ── Synthetic songs ────────────────────────────────────────────────────────
interface Song { pcm: Float32Array; kicks: { t: number; down: boolean }[] }

function synth(bpm: number, seconds: number, seed: number): Song {
  const r = rng(seed);
  const sr = FEATURE_SR, pcm = new Float32Array(Math.floor(seconds * sr));
  const beat = 60 / bpm, phase0 = 0.3 + r() * 0.4;
  const add = (t0: number, dur: number, fn: (dt: number) => number) => {
    const s = Math.floor(t0 * sr), e = Math.min(pcm.length, s + Math.floor(dur * sr));
    for (let i = Math.max(0, s); i < e; i++) pcm[i] += fn((i - s) / sr);
  };
  const kicks: Song["kicks"] = [];
  for (let b = 0; phase0 + b * beat < seconds; b++) {
    const t = phase0 + b * beat, inBar = b % 4;
    if (inBar === 0 || inBar === 2) {
      const amp = inBar === 0 ? 0.9 : 0.6;
      add(t, 0.25, dt => amp * Math.exp(-dt * 14) * Math.sin(2 * Math.PI * (50 + 90 * Math.exp(-dt * 30)) * dt));
      kicks.push({ t, down: inBar === 0 });
      if (inBar === 0) add(t, 0.6, dt => 0.12 * Math.exp(-dt * 5) * (r() * 2 - 1)); // crash
    } else {
      add(t, 0.18, dt => 0.35 * Math.exp(-dt * 22) * (r() * 2 - 1));               // snare
    }
    add(t + beat / 2, 0.05, dt => 0.08 * Math.exp(-dt * 80) * (r() * 2 - 1));      // hat
  }
  for (let i = 0; i < pcm.length; i++) pcm[i] += 0.004 * (r() * 2 - 1);
  return { pcm, kicks };
}

/** Simulated user: taps kicks with ±15 ms jitter and +20 ms lag; extra on downbeats. */
function tapClip(s: Song, start: number, end: number, seed: number): Clip {
  const r = rng(seed);
  const taps = s.kicks.filter(k => k.t >= start && k.t < end)
    .map(k => ({ t: k.t + 0.02 + (r() - 0.5) * 0.03, strong: k.down }));
  return { start, end, taps, at: 0 };
}

// ── Tempo + features ───────────────────────────────────────────────────────
{
  const s = synth(120, 30, 11);
  const ft = extractFeatures(s.pcm);
  ok("frame count", ft.frames === Math.floor(s.pcm.length / (FEATURE_SR / FRAME_RATE)));
  ok("feature dim", ft.dim === FEATURE_DIM && ft.data.length === ft.frames * FEATURE_DIM);
  ok("all features finite", ft.data.every(Number.isFinite));
  // Kick period at 120 BPM is 2 beats = 1 s = 50 frames; the tactus prior may
  // also pick the 0.5 s beat (25). Either is a correct grid for the comb.
  const p = ft.periodFrames;
  ok("period estimate on beat grid", near(p, 25, 1) || near(p, 50, 1.5), `got ${p}`);
  const flat = estimatePeriod(new Float32Array(1000).fill(1));
  ok("flat flux → no period", flat === 0, `got ${flat}`);
  const back = decodeFeatures(encodeFeatures(ft));
  ok("cache round-trip", !!back && back.frames === ft.frames && back.periodFrames === ft.periodFrames
    && back.data.every((v, i) => v === ft.data[i]) && back.level.every((v, i) => v === ft.level[i]));
  ok("bad cache rejected", decodeFeatures(new ArrayBuffer(8)) === null);
}

// ── Curve math ─────────────────────────────────────────────────────────────
{
  const clip: Clip = { start: 1, end: 3, taps: [{ t: 1.5, strong: false }, { t: 2.0, strong: true }], at: 0 };
  const { from, y } = clipTargets(clip, 500);
  ok("targets start at clip", from === 50 && y.length === 100);
  ok("normal tap peak", near(y[75 - from], NORMAL_H, 1e-6));
  ok("strong tap peak", near(y[100 - from], 1, 1e-6));
  const raw = new Float32Array(500);
  raw[75] = 0.5; raw[74] = 0.3; raw[76] = 0.3; raw[100] = 0.9; raw[102] = 0.85; // 102 is within MIN_GAP of 100
  const pk = pickPeaks(raw, 0.2);
  ok("peak picking merges close peaks", pk.length === 2 && near(pk[0].t, 1.5, 0.01) && near(pk[1].t, 2.0, 0.01),
    JSON.stringify(pk));
  ok("matching tolerance", matchCount([1.0, 2.05, 3.2], [1.03, 2.0, 3.0]) === 2);
  const ev = tapsToEvents(clip.taps);
  ok("envelope peaks at event", near(envelopeAt(ev, 1.5, 0.1), NORMAL_H, 1e-6));
  ok("envelope decays", near(envelopeAt(ev, 1.6, 0.1), NORMAL_H * Math.exp(-1), 1e-6));
  ok("envelope zero before", envelopeAt(ev, 1.0, 0.1) === 0);
  ok("strong overrides", near(envelopeAt(ev, 2.0, 0.1), 1, 1e-6));
}

// ── End-to-end: learn "kicks only, extra on the downbeat" ─────────────────
{
  const bpms = [96, 104, 110, 120, 124, 132, 140];
  const songs: SongData[] = [];
  const raw: Song[] = [];
  bpms.forEach((bpm, i) => {
    const s = synth(bpm, 40, 100 + i);
    raw.push(s);
    songs.push({ id: `song-${i}`, ft: extractFeatures(s.pcm), clips: [tapClip(s, 5, 35, 200 + i)] });
  });
  const split = splitData(songs);
  ok("song-level split with ≥6 songs", split.valSongs >= 1 && split.train.length + split.val.length === 7);

  const t0 = Date.now();
  const { net, json } = trainPulseNet(songs, { maxEpochs: 25, seed: 5 });
  const m = json.metrics;
  console.log(`  pulse e2e: AI F1 ${m.valF1.toFixed(3)} vs old engine ${m.baseF1.toFixed(3)} (train ${m.trainF1.toFixed(3)}, ${m.epochs} epochs, ${Date.now() - t0} ms)`);
  ok("AI learns the tap rule on held-out songs", m.valF1 >= 0.85, `valF1 ${m.valF1}`);
  ok("AI beats the old engine", m.valF1 > m.baseF1 + 0.05, `ai ${m.valF1} base ${m.baseF1}`);
  ok("extra pulses calibrate higher", net.cal.hStrong > net.cal.hNormal, JSON.stringify(net.cal));

  // Downbeats (extra) should come out with larger amplitude than beat 3.
  const vi = songs.findIndex(s => s.id === split.val[0].id);
  const events = curveToEvents(net.predict(songs[vi].ft), net.cal);
  const ampNear = (t: number) => events.filter(e => Math.abs(e.t - t) < 0.08).map(e => e.amp)[0] ?? 0;
  const ks = raw[vi].kicks.filter(k => k.t > 5 && k.t < 35);
  const avg = (a: number[]) => a.reduce((x, y) => x + y, 0) / Math.max(1, a.length);
  const down = avg(ks.filter(k => k.down).map(k => ampNear(k.t + 0.02)));
  const three = avg(ks.filter(k => !k.down).map(k => ampNear(k.t + 0.02)));
  ok("downbeats pulse harder than beat 3", down > three + 0.05, `down ${down.toFixed(2)} three ${three.toFixed(2)}`);

  // JSON round-trip predicts identically (the iOS port will read this file).
  const back = PulseNet.fromJSON(JSON.parse(JSON.stringify(json)))!;
  const a = net.predict(songs[0].ft, 300, 400), b = back.predict(songs[0].ft, 300, 400);
  let maxD = 0;
  for (let f = 300; f < 400; f++) maxD = Math.max(maxD, Math.abs(a[f] - b[f]));
  ok("model JSON round-trip", maxD < 1e-3, `max diff ${maxD}`);
  ok("stale model rejected", PulseNet.fromJSON({ ...json, featureVersion: 999 }) === null);
}

console.log(`pulseTrainer: ${n} checks passed`);
