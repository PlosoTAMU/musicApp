// Twin of musicApp/BeatEngine.swift — predictive beat tracker.
//
// Tempo: autocorrelation of a ~6 s onset envelope with a log-Gaussian prior
// centred on 120 BPM and harmonic reinforcement; switches need 3 agreeing
// votes. Phase: a PLL — onsets near a predicted beat pull phase/period toward
// them, off-beat energy is ignored (no double-hits). Nod: sharp drop AT the
// beat, slow recovery, anticipatory lift; >150 BPM folds to half-time.
//
// BeatFeed adapts it to this client: Web Audio analyser on the player's
// <audio> element supplies kick-weighted log-spectral flux + an energy gate,
// and log-spaced display bins for the canvas visualizer.

export interface BeatOutput {
  nod: number;        // 0-1 head-nod displacement, phase-driven
  pulse: number;      // 0-1 per-beat pulse for bar/glow modulation
  confidence: number; // 0-1 lock quality
  bpm: number;
}

const N = 256; // onset envelope ring (~6 s at ~43 fps)

export class BeatEngine {
  private envelope = new Float32Array(N);
  private acfBuf = new Float32Array(N);
  private envIdx = 0;
  private filled = 0;

  private fluxMean = 0.01;
  private fluxDev = 0.01;

  private periodS = 0.5; // 120 BPM prior
  private phase = 0;
  private confidence = 0;
  private beatParity = false;

  private framesSinceEstimate = 0;
  private candidateLag = 0;
  private candidateVotes = 0;

  private emaDt = 1 / 43;
  private fluxPulse = 0;

  reset() {
    this.envelope.fill(0);
    this.envIdx = 0; this.filled = 0;
    this.fluxMean = 0.01; this.fluxDev = 0.01;
    this.periodS = 0.5; this.phase = 0; this.confidence = 0; this.beatParity = false;
    this.framesSinceEstimate = 0; this.candidateLag = 0; this.candidateVotes = 0;
    this.emaDt = 1 / 43;
    this.fluxPulse = 0;
  }

  process(onset: number, energyGate: number, dt: number): BeatOutput {
    this.emaDt += (Math.min(Math.max(dt, 0.005), 0.1) - this.emaDt) * 0.1;

    this.envelope[this.envIdx] = onset;
    this.envIdx = (this.envIdx + 1) % N;
    this.filled = Math.min(this.filled + 1, N);
    this.fluxMean += (onset - this.fluxMean) * 0.03;
    this.fluxDev += (Math.abs(onset - this.fluxMean) - this.fluxDev) * 0.03;

    this.phase += this.emaDt / Math.max(this.periodS, 0.1);
    if (this.phase >= 1) { this.phase -= 1; this.beatParity = !this.beatParity; }

    const threshold = this.fluxMean + 1.5 * this.fluxDev;
    if (onset > threshold && this.filled > 40) {
      const strength = Math.min(2, (onset - this.fluxMean) / Math.max(this.fluxDev, 1e-4)) / 2;
      // Signed distance from the nearest predicted beat, in beat units.
      const err = this.phase < 0.5 ? this.phase : this.phase - 1;
      if (Math.abs(err) < 0.22) {
        this.phase -= err * (0.3 + 0.25 * strength);
        if (this.phase < 0) { this.phase += 1; this.beatParity = !this.beatParity; }
        this.periodS *= 1 + err * 0.05;
        this.confidence = Math.min(1,
          this.confidence + ((0.22 - Math.abs(err)) / 0.22) * 0.09 * (0.5 + strength));
      } else {
        // Energy between beats: syncopation is normal, barely punish.
        this.confidence = Math.max(0, this.confidence - 0.015);
      }
      this.fluxPulse = Math.max(this.fluxPulse, strength);
    }

    // Idle decay — a lock that stops being confirmed fades in ~20 s.
    this.confidence *= energyGate > 0.1 ? 0.9992 : 0.996;
    this.fluxPulse *= 0.72;

    this.framesSinceEstimate += 1;
    if (this.framesSinceEstimate >= 32 && this.filled >= N / 2) {
      this.framesSinceEstimate = 0;
      this.estimateTempo();
    }

    // Half/double-time folding — people nod the tactus, not the hi-hats.
    let nodPhase = this.phase;
    const bpm = 60 / this.periodS;
    if (bpm > 150) {
      nodPhase = (this.beatParity ? this.phase + 1 : this.phase) / 2;
    } else if (bpm < 55) {
      nodPhase = this.phase * 2 > 1 ? this.phase * 2 - 1 : this.phase * 2;
    }

    const gate = this.confidence * this.confidence * Math.min(1, energyGate * 1.6);
    const attack = Math.exp(-5.5 * nodPhase);
    const lift = smoothstep(0.72, 1.0, nodPhase) * 0.38;
    const nod = (attack * 0.92 + lift) * gate;

    const phasePulse = Math.exp(-8 * this.phase) * gate;
    const pulse = Math.max(phasePulse, this.fluxPulse * 0.75 * Math.min(1, energyGate * 1.6));

    return {
      nod: Math.min(1, nod),
      pulse: Math.min(1, pulse),
      confidence: this.confidence,
      bpm,
    };
  }

  private estimateTempo() {
    let mean = 0;
    for (let i = 0; i < N; i++) mean += this.envelope[i];
    mean /= N;
    for (let i = 0; i < N; i++) this.acfBuf[i] = this.envelope[i] - mean;

    const minLag = Math.max(4, Math.floor(0.30 / this.emaDt));          // 200 BPM
    const maxLag = Math.min(N / 2 - 1, Math.floor(1.35 / this.emaDt));  // ~44 BPM
    if (maxLag <= minLag + 2) return;

    const acf = (lag: number): number => {
      let s = 0;
      for (let i = 0; i < N - lag; i++) s += this.acfBuf[i] * this.acfBuf[i + lag];
      return Math.max(0, s);
    };

    let bestLag = 0, bestScore = 0, sumScore = 0;
    for (let lag = minLag; lag <= maxLag; lag++) {
      const period = lag * this.emaDt;
      // Log-Gaussian tactus prior centred on 0.5 s (120 BPM).
      const prior = Math.exp(-0.5 * Math.pow(Math.log2(period / 0.5) / 0.9, 2));
      let score = acf(lag) * prior;
      if (lag * 2 <= maxLag) score += 0.45 * acf(lag * 2) * prior; // harmonic support
      sumScore += score;
      if (score > bestScore) { bestScore = score; bestLag = lag; }
    }
    if (!bestLag || !sumScore) return;
    const salience = bestScore / (sumScore / (maxLag - minLag + 1) + 1e-6);
    if (salience <= 1.8) return; // flat ACF = no rhythm; keep coasting

    const measured = bestLag * this.emaDt;
    if (Math.abs(measured - this.periodS) / this.periodS < 0.12) {
      this.periodS = this.periodS * 0.85 + measured * 0.15; // refine the lock
      this.candidateVotes = 0;
    } else if (Math.abs(bestLag - this.candidateLag) <= 1) {
      if (++this.candidateVotes >= 3) {
        this.periodS = measured;
        this.confidence *= 0.5; // relock phase via PLL
        this.candidateVotes = 0;
      }
    } else {
      this.candidateLag = bestLag;
      this.candidateVotes = 1;
    }
  }
}

const smoothstep = (a: number, b: number, x: number): number => {
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
};

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

// ── Web Audio feeder ────────────────────────────────────────────────────────

const DISPLAY_BINS = 48;

export class BeatFeed {
  readonly engine = new BeatEngine();
  /** Log-spaced 0-1 display bins (fast attack, slow release) for the canvas. */
  readonly bins = new Float32Array(DISPLAY_BINS);

  private ctx?: AudioContext;
  private analyser?: AnalyserNode;
  private bass?: BiquadFilterNode;
  private dry?: GainNode;
  private wet?: GainNode;
  private freq?: Uint8Array<ArrayBuffer>; // getByteFrequencyData rejects ArrayBufferLike
  private prevLog?: Float32Array;
  private bandEdges: number[] = [];
  private energyEma = 0;
  private lastT = 0;

  /** Idempotent — createMediaElementSource throws on a second call, and once
   *  attached the element's audio routes through this context permanently.
   *
   *  Graph (analysis + DSP share one chain, twin of the iOS effect stack):
   *    src → bass(lowshelf) → analyser → dry ─────────┐
   *                              └─→ convolver → wet ─┴→ destination */
  attach(el: HTMLAudioElement) {
    if (this.ctx) return;
    this.ctx = new AudioContext();
    const src = this.ctx.createMediaElementSource(el);

    this.bass = this.ctx.createBiquadFilter();
    this.bass.type = "lowshelf";
    this.bass.frequency.value = 120;
    this.bass.gain.value = 0;

    this.analyser = this.ctx.createAnalyser();
    this.analyser.fftSize = 2048;
    this.analyser.smoothingTimeConstant = 0; // engine + bins do their own smoothing

    this.dry = this.ctx.createGain();
    this.wet = this.ctx.createGain();
    this.wet.gain.value = 0;
    const convolver = this.ctx.createConvolver();
    convolver.buffer = makeImpulse(this.ctx, 2.2, 2.8);

    src.connect(this.bass);
    this.bass.connect(this.analyser);
    this.analyser.connect(this.dry);
    this.dry.connect(this.ctx.destination);
    this.analyser.connect(convolver);
    convolver.connect(this.wet);
    this.wet.connect(this.ctx.destination);

    this.freq = new Uint8Array(this.analyser.frequencyBinCount);
    this.prevLog = new Float32Array(this.analyser.frequencyBinCount);

    // Log-spaced band edges 40 Hz → 14 kHz for the display bins.
    const binHz = this.ctx.sampleRate / this.analyser.fftSize;
    const lo = Math.log(40), hi = Math.log(14_000);
    this.bandEdges = Array.from({ length: DISPLAY_BINS + 1 }, (_, i) => {
      const hz = Math.exp(lo + ((hi - lo) * i) / DISPLAY_BINS);
      return Math.max(1, Math.min(this.analyser!.frequencyBinCount - 1, Math.round(hz / binHz)));
    });
  }

  get attached() { return !!this.ctx; }

  /** 0–12 dB low-shelf boost below 120 Hz — twin of the iOS bass boost. */
  setBassDb(db: number) {
    if (this.bass) this.bass.gain.value = db;
  }

  /** 0–1 reverb mix. Dry ducks slightly as wet rises so loudness stays sane. */
  setReverbMix(mix: number) {
    if (this.wet) this.wet.gain.value = mix * 0.9;
    if (this.dry) this.dry.gain.value = 1 - mix * 0.35;
  }

  /** The play click is the user gesture — a suspended context would mute the
   *  routed element, so resume aggressively. */
  resume() {
    if (this.ctx?.state === "suspended") void this.ctx.resume();
  }

  resetTrack() {
    this.engine.reset();
    this.prevLog?.fill(0);
    this.energyEma = 0;
  }

  /** One animation frame: spectral flux → engine; also refreshes `bins`. */
  tick(nowMs: number): BeatOutput {
    const a = this.analyser;
    if (!a || !this.freq || !this.prevLog) {
      return { nod: 0, pulse: 0, confidence: 0, bpm: 0 };
    }
    const dt = this.lastT ? (nowMs - this.lastT) / 1000 : 1 / 60;
    this.lastT = nowMs;

    a.getByteFrequencyData(this.freq);

    // Kick-weighted half-wave-rectified log-spectral flux + loudness gate.
    const binHz = this.ctx!.sampleRate / a.fftSize;
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
    for (let b = 0; b < DISPLAY_BINS; b++) {
      let peak = 0;
      for (let i = this.bandEdges[b]; i < this.bandEdges[b + 1]; i++) {
        if (this.freq[i] > peak) peak = this.freq[i];
      }
      const v = peak / 255;
      this.bins[b] += (v - this.bins[b]) * (v > this.bins[b] ? 0.55 : 0.16);
    }

    return this.engine.process(flux / nBins, this.energyEma, dt);
  }
}
