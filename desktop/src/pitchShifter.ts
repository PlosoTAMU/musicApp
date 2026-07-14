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
  private read(ch: number, pos: number): number {
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
      for (let ch = 0; ch < 2; ch++) {
        const ola = this.ola[ch];
        for (let k = 0; k < GRAIN; k++) {
          ola[k] += this.read(ch, a + k * this.f) * this.win[k];
        }
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
