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
    // lib.dom's AudioParamMap predates .get(); it's a live maplike at runtime.
    const params = this.pitch?.parameters as Map<string, AudioParam> | undefined;
    const p = params?.get("semitones");
    if (p) p.value = st;
  }

  /** The play click is the user gesture — a suspended context would mute the
   *  routed element, so resume aggressively. */
  resume() {
    if (this.ctx?.state === "suspended") void this.ctx.resume();
  }
}
