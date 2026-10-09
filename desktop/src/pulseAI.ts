// Pulse-trainer service (renderer side). Owns the on-disk store, decodes
// audio, and talks to the worker:
//
//   <userData>/pulse-trainer/
//     sessions/<trackId>.json   tapped clips per song (the training data)
//     features/<trackId>.f<v>.bin  cached feature frames (see pulseFeatures)
//     events/<trackId>.<model>.json  model output: pulse events for playback
//     model.json                 the trained net (portable JSON)
//
// userData, not the music folder: that one is fs.watch'd and replicated.
import { ipcRenderer } from "electron";
import * as fs from "fs";
import * as path from "path";
import { FEATURE_SR, FEATURE_VERSION } from "./pulseFeatures";
import { PulseModelJSON, TrainMetrics } from "./pulseModel";
import { Clip, PulseEvent } from "./pulseCurve";
import type { WorkerReq } from "./pulseWorker";

export interface SongSession { id: string; name: string; path: string; clips: Clip[] }
export interface TrackLike { id: string; name: string; path: string }
export interface TrainProgress { epoch: number; loss: number; valF1: number; baseF1: number }

type Distribute<T> = T extends unknown ? Omit<T, "id"> : never;
type ReqBody = Distribute<WorkerReq>;

const PREFS = {
  enabled: "pulse.ai.enabled",
  offsetMs: "pulse.ai.offsetMs",
  tauMs: "pulse.ai.tauMs",
  gain: "pulse.ai.gain",
};

const readNum = (k: string, d: number) => {
  try { const v = Number(localStorage.getItem(k)); return localStorage.getItem(k) !== null && isFinite(v) ? v : d; }
  catch { return d; }
};

export class PulseAI {
  private root = "";
  private worker: Worker | null = null;
  private seq = 0;
  private pending = new Map<number, {
    res: (v: any) => void; rej: (e: Error) => void; onProgress?: (p: TrainProgress) => void;
  }>();
  readonly sessions = new Map<string, SongSession>();
  model: PulseModelJSON | null = null;
  private eventCache = new Map<string, PulseEvent[]>();
  private inflight = new Map<string, Promise<PulseEvent[] | null>>();
  /** Fired when a model is (re)loaded or trained — consumers drop caches. */
  onModelChange?: () => void;

  // Playback prefs (localStorage — per machine, never synced).
  enabled = localStorage.getItem(PREFS.enabled) === "1";
  offsetMs = readNum(PREFS.offsetMs, 0);
  tauMs = readNum(PREFS.tauMs, 110);
  gain = readNum(PREFS.gain, 0.08);

  savePrefs() {
    try {
      localStorage.setItem(PREFS.enabled, this.enabled ? "1" : "0");
      localStorage.setItem(PREFS.offsetMs, String(this.offsetMs));
      localStorage.setItem(PREFS.tauMs, String(this.tauMs));
      localStorage.setItem(PREFS.gain, String(this.gain));
    } catch { /* storage blocked — prefs stay for this run */ }
  }

  async init() {
    if (this.root) return;
    const ud: string = await ipcRenderer.invoke("user-data-dir");
    this.root = path.join(ud, "pulse-trainer");
    for (const d of ["sessions", "features", "events"]) fs.mkdirSync(path.join(this.root, d), { recursive: true });
    for (const f of fs.readdirSync(path.join(this.root, "sessions"))) {
      if (!f.endsWith(".json")) continue;
      try {
        const s = JSON.parse(fs.readFileSync(path.join(this.root, "sessions", f), "utf8")) as SongSession;
        if (s?.id && Array.isArray(s.clips)) this.sessions.set(s.id, s);
      } catch { /* corrupt session file — skip, don't block the trainer */ }
    }
    try {
      const m = JSON.parse(fs.readFileSync(path.join(this.root, "model.json"), "utf8")) as PulseModelJSON;
      if (m?.kind === "pulse-mlp" && m.featureVersion === FEATURE_VERSION) this.model = m;
    } catch { /* no model yet */ }
  }

  get ready() { return !!this.root; }
  get modelPath() { return path.join(this.root, "model.json"); }

  // ── Worker RPC ──────────────────────────────────────────────────────────

  private getWorker(): Worker {
    if (this.worker) return this.worker;
    // Blob URL (fs read), same as the pitch worklet: file:// workers are CORS-hostile.
    const code = fs.readFileSync(path.join(__dirname, "pulseWorker.js"), "utf8");
    const url = URL.createObjectURL(new Blob([code], { type: "text/javascript" }));
    const w = new Worker(url);
    w.onmessage = e => {
      const m = e.data;
      const p = this.pending.get(m.id);
      if (!p) return;
      if (m.progress) { p.onProgress?.(m.progress); return; }
      this.pending.delete(m.id);
      if (m.ok) p.res(m); else p.rej(new Error(m.error));
    };
    w.onerror = e => {
      for (const p of this.pending.values()) p.rej(new Error(e.message || "Worker crashed"));
      this.pending.clear();
      this.worker = null;
    };
    this.worker = w;
    return w;
  }

  private call(msg: ReqBody, transfer: Transferable[] = [], onProgress?: (p: TrainProgress) => void): Promise<any> {
    const id = ++this.seq;
    return new Promise((res, rej) => {
      this.pending.set(id, { res, rej, onProgress });
      this.getWorker().postMessage({ ...msg, id }, transfer);
    });
  }

  /** Kill a running training job (the loop is synchronous in the worker). */
  cancel() {
    this.worker?.terminate();
    this.worker = null;
    for (const p of this.pending.values()) p.rej(new Error("Cancelled"));
    this.pending.clear();
  }

  // ── Sessions ────────────────────────────────────────────────────────────

  saveClip(t: TrackLike, clip: Clip) {
    const s = this.sessions.get(t.id) ?? { id: t.id, name: t.name, path: t.path, clips: [] };
    s.name = t.name; s.path = t.path;
    s.clips.push(clip);
    this.sessions.set(t.id, s);
    this.writeSession(s);
  }

  /** Drop the most recent clip for a song (undo). */
  removeLastClip(id: string) {
    const s = this.sessions.get(id);
    if (!s || !s.clips.length) return;
    s.clips.pop();
    if (!s.clips.length) {
      this.sessions.delete(id);
      try { fs.unlinkSync(path.join(this.root, "sessions", `${id}.json`)); } catch { /* gone */ }
    } else this.writeSession(s);
  }

  private writeSession(s: SongSession) {
    const p = path.join(this.root, "sessions", `${s.id}.json`);
    fs.writeFileSync(p + ".tmp", JSON.stringify(s));
    fs.renameSync(p + ".tmp", p); // atomic: a crash never leaves half a session
  }

  stats() {
    let clips = 0, taps = 0, seconds = 0;
    for (const s of this.sessions.values()) for (const c of s.clips) {
      clips++; taps += c.taps.length; seconds += c.end - c.start;
    }
    return { songs: this.sessions.size, clips, taps, seconds };
  }

  // ── Features ────────────────────────────────────────────────────────────

  private featPath(id: string) { return path.join(this.root, "features", `${id}.f${FEATURE_VERSION}.bin`); }

  /** Cached feature buffer for a track; decodes + extracts on a miss. */
  async features(t: TrackLike): Promise<ArrayBuffer> {
    const fp = this.featPath(t.id);
    try {
      const b = fs.readFileSync(fp);
      return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength);
    } catch { /* miss */ }
    const file = await fs.promises.readFile(t.path);
    const ab = file.buffer.slice(file.byteOffset, file.byteOffset + file.byteLength);
    // decodeAudioData resamples to the context's rate — FEATURE_SR for free.
    const ac = new OfflineAudioContext(1, 1, FEATURE_SR);
    const audio = await ac.decodeAudioData(ab);
    const pcm = new Float32Array(audio.length);
    for (let ch = 0; ch < audio.numberOfChannels; ch++) {
      const d = audio.getChannelData(ch);
      for (let i = 0; i < d.length; i++) pcm[i] += d[i] / audio.numberOfChannels;
    }
    const r = await this.call({ type: "features", pcm }, [pcm.buffer]);
    const buf = r.buf as ArrayBuffer;
    try { await fs.promises.writeFile(fp, Buffer.from(buf)); } catch { /* cache is best-effort */ }
    return buf;
  }

  // ── Training ────────────────────────────────────────────────────────────

  async train(
    resolvePath: (s: SongSession) => string | null,
    onStage: (msg: string) => void,
    onProgress: (p: TrainProgress) => void,
  ): Promise<TrainMetrics> {
    const songs: { id: string; feat: ArrayBuffer; clips: Clip[] }[] = [];
    const list = [...this.sessions.values()].filter(s => s.clips.length);
    let i = 0;
    for (const s of list) {
      onStage(`Analyzing audio ${++i}/${list.length} — ${s.name}`);
      const p = resolvePath(s);
      if (!p) continue; // file gone — its taps can't be trained on
      try { songs.push({ id: s.id, feat: await this.features({ ...s, path: p }), clips: s.clips }); }
      catch (e) { console.warn("[pulse] skip", s.name, e); }
    }
    if (!songs.length) throw new Error("No playable tapped songs found");
    onStage(`Training on ${songs.length} songs…`);
    const r = await this.call({ type: "train", songs }, [], onProgress);
    const model = r.model as PulseModelJSON;
    fs.writeFileSync(this.modelPath + ".tmp", JSON.stringify(model));
    fs.renameSync(this.modelPath + ".tmp", this.modelPath);
    this.model = model;
    // Old model's events are keyed by its trainedAt and can never hit again.
    const evDir = path.join(this.root, "events");
    for (const f of fs.readdirSync(evDir)) { try { fs.unlinkSync(path.join(evDir, f)); } catch { /* in use */ } }
    this.eventCache.clear();
    this.inflight.clear();
    this.onModelChange?.();
    return model.metrics;
  }

  // ── Inference for playback ──────────────────────────────────────────────

  private eventsKey(id: string) { return `${id}.${this.model?.metrics.trainedAt ?? 0}`; }

  /** Synchronous lookup — null until eventsFor() has resolved for this track. */
  cachedEvents(id: string): PulseEvent[] | null {
    return this.eventCache.get(this.eventsKey(id)) ?? null;
  }

  /** Pulse events for a whole track (disk cache → worker). Null without a model. */
  eventsFor(t: TrackLike): Promise<PulseEvent[] | null> {
    const model = this.model;
    if (!model || !this.root) return Promise.resolve(null);
    const key = this.eventsKey(t.id);
    const hit = this.eventCache.get(key);
    if (hit) return Promise.resolve(hit);
    const running = this.inflight.get(key);
    if (running) return running;
    const job = (async () => {
      const ep = path.join(this.root, "events", `${key}.json`);
      try {
        const ev = JSON.parse(fs.readFileSync(ep, "utf8")) as PulseEvent[];
        this.eventCache.set(key, ev);
        return ev;
      } catch { /* miss */ }
      const feat = await this.features(t);
      const r = await this.call({ type: "predict", model, feat });
      if (this.model !== model) return null; // retrained mid-flight
      const ev = r.events as PulseEvent[];
      this.eventCache.set(key, ev);
      try { await fs.promises.writeFile(ep, JSON.stringify(ev)); } catch { /* best-effort */ }
      return ev;
    })().catch(e => { console.warn("[pulse] inference failed", t.name, e); return null; })
      .finally(() => this.inflight.delete(key));
    this.inflight.set(key, job);
    return job;
  }
}
