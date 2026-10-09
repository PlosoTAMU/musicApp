// Pulse Trainer modal — you tap how the Now Playing art should pulse, a small
// net learns it (pulseModel.ts), and the player rides the learned pulse.
//
//   Home     stats, train, preview, playback prefs
//   Tap      random 30 s clip (+4 s lead-in). Space = pulse; hold Shift or K
//            with it (or press within 70 ms) = extra pulse. The art pulses
//            with your own taps, through the same envelope the AI will use.
//   Preview  AI pulse on a song, Tab flips to the old BeatEngine for A/B.
//
// Plays on its own throwaway <audio> (like the crop sheet); the main player
// is paused while open. Keys are captured so Space never hits the transport.
import { pathToFileURL } from "url";
import { PulseAI, SongSession, TrackLike, TrainProgress } from "./pulseAI";
import { Clip, Tap, PulseEvent, tapsToEvents, envelopeAt, baselineCurve } from "./pulseCurve";
import { decodeFeatures, FRAME_RATE } from "./pulseFeatures";
import type { TrainMetrics } from "./pulseModel";

export interface TrainerTrack extends TrackLike { yt?: string }

export interface TrainerOpts {
  ai: PulseAI;
  library: () => TrainerTrack[];
  volume: number;
  pauseMain: () => boolean;
  resumeMain: () => void;
  onPrefsChange: () => void;
}

const CLIP_S = 30, LEAD_S = 4, EXTRA_WINDOW_MS = 70;

const fmt = (s: number) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;
const pct = (v: number) => `${Math.round(v * 100)}%`;

export function showPulseTrainer(o: TrainerOpts) {
  const ai = o.ai;
  const overlay = document.createElement("div");
  overlay.className = "modal-overlay";
  overlay.innerHTML = `
    <div class="modal-card trainer-card">
      <div class="tr-head">
        <h4>Pulse Trainer</h4>
        <button class="row-btn tr-close" title="Close (Esc)">✕</button>
      </div>
      <div class="tr-stage">
        <div class="tr-art"><span class="tr-art-fb">♫</span><img class="tr-art-img" hidden alt="" /></div>
      </div>
      <div class="tr-home">
        <p class="tr-stats"></p>
        <p class="tr-model"></p>
        <div class="tr-actions">
          <button class="pill tr-start">Start tapping</button>
          <button class="link tr-train">Train model</button>
          <button class="link tr-preview">Preview AI</button>
        </div>
        <div class="tr-train-box" hidden>
          <p class="tr-stage-msg"></p>
          <canvas class="tr-chart" width="420" height="110"></canvas>
          <button class="link tr-cancel">Cancel</button>
        </div>
        <div class="tr-prefs">
          <label class="tr-row"><input type="checkbox" class="tr-enabled" /> Use AI pulse in the player</label>
          <label class="tr-row"><span>Pulse size</span><input type="range" class="tr-gain" min="2" max="25" step="1" /><span class="tr-val tr-gain-v"></span></label>
          <label class="tr-row"><span>Decay</span><input type="range" class="tr-tau" min="50" max="350" step="10" /><span class="tr-val tr-tau-v"></span></label>
          <label class="tr-row"><span>Timing</span><input type="range" class="tr-off" min="-200" max="200" step="5" /><span class="tr-val tr-off-v"></span></label>
        </div>
        <p class="tr-help">Tapping: <b>Space</b> = pulse · hold <b>Shift</b> or <b>K</b> while tapping = extra pulse · <b>Backspace</b> = undo tap · <b>Esc</b> = stop.
          Size and decay apply to your taps and the AI alike, so what you see while tapping is what you get.</p>
      </div>
      <div class="tr-session" hidden>
        <p class="tr-song"></p>
        <p class="tr-phase"></p>
        <div class="tr-bar"><div class="tr-fill"></div><div class="tr-ticks"></div></div>
        <p class="tr-count"></p>
        <div class="tr-actions tr-review" hidden>
          <button class="pill tr-save">Save &amp; next (Enter)</button>
          <button class="link tr-replay">Replay (P)</button>
          <button class="link tr-redo">Redo (R)</button>
          <button class="link tr-skip">Skip song (S)</button>
          <button class="link tr-done">Done (Esc)</button>
        </div>
        <div class="tr-actions tr-pv" hidden>
          <button class="link tr-pv-next">Another song (N)</button>
          <button class="link tr-pv-ab">Switch AI / old (Tab)</button>
          <button class="link tr-pv-done">Done (Esc)</button>
        </div>
      </div>
    </div>`;
  document.body.appendChild(overlay);

  const q = <T extends HTMLElement>(sel: string) => overlay.querySelector(sel) as T;
  const art = q<HTMLDivElement>(".tr-art");
  const artImg = q<HTMLImageElement>(".tr-art-img");
  const audio = new Audio();
  audio.preload = "auto";
  audio.volume = o.volume;
  const wasPlaying = o.pauseMain();

  type Mode = "home" | "lead" | "tap" | "review" | "replay" | "preview";
  let mode: Mode = "home";
  let track: TrainerTrack | null = null;
  let clip: { start: number; end: number } | null = null;
  let taps: Tap[] = [];
  let tapEvents: PulseEvent[] = [];
  let extraKey = false;           // K held
  let lastSpaceAt = -1;           // performance.now() of the last pulse tap
  let previewEvents: PulseEvent[] | null = null;
  let previewBase: Float32Array | null = null;
  let previewOld = false;
  let training = false;
  let raf = 0;

  // ── Art ──────────────────────────────────────────────────────────────────

  const setArt = (t: TrainerTrack | null) => {
    if (t?.yt) {
      artImg.src = `https://i.ytimg.com/vi/${t.yt}/mqdefault.jpg`;
      artImg.hidden = false;
      artImg.onerror = () => { artImg.hidden = true; };
    } else artImg.hidden = true;
  };

  const pulseArt = (v: number) => {
    art.style.transform = `scale(${(1 + v * ai.gain).toFixed(4)})`;
    art.style.boxShadow = `0 ${Math.round(8 + v * 8)}px ${Math.round(22 + v * 40)}px rgba(241,43,38,${(0.15 + v * 0.45).toFixed(3)})`;
  };

  // ── Home ─────────────────────────────────────────────────────────────────

  const renderHome = () => {
    const st = ai.stats();
    const lib = o.library();
    const covered = lib.filter(t => ai.sessions.has(t.id)).length;
    q(".tr-stats").textContent =
      `${st.songs} songs tapped (${covered}/${lib.length} of your library) · ${st.clips} clips · ${st.taps} taps · ${fmt(st.seconds)} of audio`;
    const m = ai.model?.metrics;
    q(".tr-model").innerHTML = m
      ? `AI model: <b>${pct(m.valF1)}</b> match on ${m.valSongs ? `${m.valSongs} held-out song${m.valSongs === 1 ? "" : "s"}` : "held-out clip ends"} · old engine <b>${pct(m.baseF1)}</b> · trained on ${m.songs} songs, ${m.taps} taps`
      : st.clips >= 4 ? "No model yet — you have enough clips to train one."
        : "No model yet — tap at least 4 clips (20+ songs gives a much better model).";
    (q(".tr-train") as HTMLButtonElement).disabled = training || st.clips < 2;
    (q(".tr-preview") as HTMLButtonElement).disabled = training || !ai.model;
    (q(".tr-start") as HTMLButtonElement).disabled = training || !lib.length;
    (q(".tr-enabled") as HTMLInputElement).checked = ai.enabled;
    (q(".tr-enabled") as HTMLInputElement).disabled = !ai.model;
    (q(".tr-gain") as HTMLInputElement).value = String(Math.round(ai.gain * 100));
    (q(".tr-tau") as HTMLInputElement).value = String(ai.tauMs);
    (q(".tr-off") as HTMLInputElement).value = String(ai.offsetMs);
    q(".tr-gain-v").textContent = `${Math.round(ai.gain * 100)}%`;
    q(".tr-tau-v").textContent = `${ai.tauMs} ms`;
    q(".tr-off-v").textContent = `${ai.offsetMs > 0 ? "+" : ""}${ai.offsetMs} ms`;
  };

  const showMode = (m: Mode) => {
    mode = m;
    q(".tr-home").hidden = m !== "home";
    q(".tr-session").hidden = m === "home";
    q(".tr-review").hidden = m !== "review";
    q(".tr-pv").hidden = m !== "preview";
    if (m === "home") { audio.pause(); pulseArt(0); setArt(null); renderHome(); }
  };

  const prefInput = (sel: string, apply: (v: number) => void) => {
    q<HTMLInputElement>(sel).oninput = e => {
      apply(Number((e.target as HTMLInputElement).value));
      ai.savePrefs(); o.onPrefsChange(); renderHome();
    };
  };
  prefInput(".tr-gain", v => { ai.gain = v / 100; });
  prefInput(".tr-tau", v => { ai.tauMs = v; });
  prefInput(".tr-off", v => { ai.offsetMs = v; });
  q<HTMLInputElement>(".tr-enabled").onchange = e => {
    ai.enabled = (e.target as HTMLInputElement).checked;
    ai.savePrefs(); o.onPrefsChange();
  };

  // ── Clip selection ──────────────────────────────────────────────────────

  const loadAudio = (t: TrainerTrack) => new Promise<number>((res, rej) => {
    audio.onloadedmetadata = () => res(audio.duration);
    audio.onerror = () => rej(new Error("Can't play this file"));
    audio.src = pathToFileURL(t.path).href;
  });

  /** Least-tapped songs first, random among ties. */
  const pickSong = (exclude?: string): TrainerTrack | null => {
    const lib = o.library().filter(t => t.id !== exclude);
    if (!lib.length) return null;
    const count = (t: TrainerTrack) => ai.sessions.get(t.id)?.clips.length ?? 0;
    const min = Math.min(...lib.map(count));
    const pool = lib.filter(t => count(t) === min);
    return pool[Math.floor(Math.random() * pool.length)];
  };

  /** Random 30 s window, avoiding the intro and clips already tapped. */
  const pickWindow = (dur: number, prior: Clip[]): { start: number; end: number } => {
    if (dur <= CLIP_S + 8) return { start: Math.min(2, dur * 0.05), end: dur };
    const lo = Math.min(15, dur * 0.1), hi = dur - CLIP_S - 3;
    let best = { start: lo, end: lo + CLIP_S }, bestOverlap = Infinity;
    for (let i = 0; i < 10; i++) {
      const s = lo + Math.random() * Math.max(0, hi - lo);
      const overlap = prior.reduce((a, c) => a + Math.max(0, Math.min(c.end, s + CLIP_S) - Math.max(c.start, s)), 0);
      if (overlap < bestOverlap) { bestOverlap = overlap; best = { start: s, end: s + CLIP_S }; }
      if (!overlap) break;
    }
    return best;
  };

  const startClip = async (t: TrainerTrack | null, window?: { start: number; end: number }) => {
    if (!t) { showMode("home"); return; }
    track = t; taps = []; tapEvents = [];
    setArt(t);
    q(".tr-song").textContent = t.name;
    q(".tr-phase").textContent = "Loading…";
    q(".tr-count").textContent = "";
    q(".tr-ticks").innerHTML = "";
    showMode("lead");
    let dur: number;
    try { dur = await loadAudio(t); } catch {
      q(".tr-phase").textContent = "Couldn't play that file — picking another…";
      setTimeout(() => void startClip(pickSong(t.id)), 900);
      return;
    }
    if (track !== t) return;
    clip = window ?? pickWindow(dur, ai.sessions.get(t.id)?.clips ?? []);
    audio.currentTime = Math.max(0, clip.start - LEAD_S);
    await audio.play().catch(() => {});
  };

  // ── Taps ────────────────────────────────────────────────────────────────

  const audioTimeAt = (e: KeyboardEvent) =>
    audio.currentTime - Math.max(0, performance.now() - e.timeStamp) / 1000;

  const renderTicks = () => {
    if (!clip) return;
    const span = clip.end - clip.start;
    q(".tr-ticks").innerHTML = taps.map(t =>
      `<i class="${t.strong ? "big" : ""}" style="left:${(((t.t - clip!.start) / span) * 100).toFixed(2)}%"></i>`).join("");
    const strong = taps.filter(t => t.strong).length;
    q(".tr-count").textContent = `${taps.length} taps${strong ? ` · ${strong} extra` : ""}`;
  };

  const tap = (e: KeyboardEvent) => {
    const t = audioTimeAt(e);
    const strong = e.shiftKey || extraKey;
    lastSpaceAt = performance.now();
    if (mode === "lead") {           // feel-only during the lead-in
      tapEvents = [...tapEvents, { t, amp: strong ? 1 : 0.6 }];
      return;
    }
    if (mode !== "tap" || !clip || t < clip.start || t >= clip.end) return;
    taps.push({ t, strong });
    tapEvents = tapsToEvents(taps);
    renderTicks();
  };

  /** Extra key landing just after the pulse key upgrades that tap. */
  const extraPressed = () => {
    if (performance.now() - lastSpaceAt > EXTRA_WINDOW_MS) return;
    const last = taps[taps.length - 1];
    if (mode === "tap" && last && !last.strong) {
      last.strong = true;
      tapEvents = tapsToEvents(taps);
      renderTicks();
    }
  };

  const finishClip = () => {
    audio.pause();
    showMode("review");
    q(".tr-phase").textContent = taps.length ? "Clip done — keep it?" : "No taps recorded.";
    (q(".tr-save") as HTMLButtonElement).disabled = !taps.length;
  };

  const saveAndNext = () => {
    if (!track || !clip || !taps.length) return;
    ai.saveClip(track, { start: clip.start, end: clip.end, taps: taps.map(t => ({ ...t })), at: Date.now() });
    void startClip(pickSong(track.id));
  };

  // ── Preview (AI vs old engine) ──────────────────────────────────────────

  const startPreview = async (t: TrainerTrack | null) => {
    if (!t) { showMode("home"); return; }
    track = t; previewEvents = null; previewBase = null; previewOld = false;
    setArt(t);
    q(".tr-song").textContent = t.name;
    q(".tr-phase").textContent = "Analyzing…";
    q(".tr-count").textContent = "";
    q(".tr-ticks").innerHTML = "";
    showMode("preview");
    try {
      // Sequential: features() fills the disk cache that eventsFor() reads,
      // so the file is decoded once, not twice in parallel.
      const dur = await loadAudio(t);
      const feat = await ai.features(t);
      const events = await ai.eventsFor(t);
      if (track !== t || mode !== "preview") return;
      if (!events) throw new Error("the model couldn't run on this song");
      previewEvents = events;
      const ft = decodeFeatures(feat);
      previewBase = ft ? baselineCurve(ft) : null;
      clip = pickWindow(dur, []);
      audio.currentTime = clip.start;
      await audio.play().catch(() => {});
    } catch (e) {
      q(".tr-phase").textContent = `Preview failed: ${(e as Error).message}`;
    }
  };

  /** Songs you haven't tapped first — that's the honest test. */
  const pickPreviewSong = (exclude?: string) => {
    const lib = o.library().filter(t => t.id !== exclude);
    const fresh = lib.filter(t => !ai.sessions.has(t.id));
    const pool = fresh.length ? fresh : lib;
    return pool.length ? pool[Math.floor(Math.random() * pool.length)] : null;
  };

  // ── Training ────────────────────────────────────────────────────────────

  const history: TrainProgress[] = [];
  const drawChart = () => {
    const cv = q<HTMLCanvasElement>(".tr-chart");
    const c = cv.getContext("2d");
    if (!c) return;
    const w = cv.width, h = cv.height;
    c.clearRect(0, 0, w, h);
    c.font = "11px Segoe UI, sans-serif";
    const y = (v: number) => h - 14 - v * (h - 24);
    const n = Math.max(10, history.length);
    const x = (i: number) => 8 + (i / (n - 1)) * (w - 16);
    if (history.length) {
      c.strokeStyle = "rgba(244,237,234,.35)"; c.setLineDash([4, 4]);
      c.beginPath(); c.moveTo(8, y(history[0].baseF1)); c.lineTo(w - 8, y(history[0].baseF1)); c.stroke();
      c.setLineDash([]);
      c.fillStyle = "rgba(244,237,234,.55)";
      c.fillText(`old engine ${pct(history[0].baseF1)}`, 10, y(history[0].baseF1) - 4);
      c.strokeStyle = "#F12B26"; c.lineWidth = 2;
      c.beginPath();
      history.forEach((p, i) => (i ? c.lineTo(x(i), y(p.valF1)) : c.moveTo(x(i), y(p.valF1))));
      c.stroke();
      const last = history[history.length - 1];
      c.fillStyle = "#FF5E54";
      c.fillText(`AI ${pct(last.valF1)} (epoch ${last.epoch})`, w - 130, 12);
    }
  };

  const runTraining = async () => {
    if (training) return;
    training = true;
    history.length = 0;
    q(".tr-train-box").hidden = false;
    drawChart();
    renderHome();
    const lib = o.library();
    const resolvePath = (s: SongSession) =>
      (lib.find(t => t.id === s.id) ?? lib.find(t => t.name === s.name))?.path ?? null;
    try {
      const m: TrainMetrics = await ai.train(resolvePath,
        msg => { q(".tr-stage-msg").textContent = msg; },
        p => { history.push(p); drawChart(); q(".tr-stage-msg").textContent = `Training — epoch ${p.epoch}, loss ${p.loss.toFixed(3)}`; });
      q(".tr-stage-msg").textContent =
        `Done: AI ${pct(m.valF1)} vs old engine ${pct(m.baseF1)} on held-out data (train ${pct(m.trainF1)}).`;
      if (!ai.enabled) { ai.enabled = true; ai.savePrefs(); }
      o.onPrefsChange();
    } catch (e) {
      q(".tr-stage-msg").textContent = `Training stopped: ${(e as Error).message}`;
    } finally {
      training = false;
      renderHome();
    }
  };

  // ── Frame loop ──────────────────────────────────────────────────────────

  const frame = () => {
    raf = requestAnimationFrame(frame);
    if (mode === "home") return;
    const t = audio.currentTime;
    const tau = ai.tauMs / 1000;
    if (clip) {
      const p = Math.max(0, Math.min(1, (t - clip.start) / (clip.end - clip.start)));
      q<HTMLDivElement>(".tr-fill").style.width = `${(p * 100).toFixed(2)}%`;
    }
    if (mode === "lead" && clip) {
      const left = clip.start - t;
      q(".tr-phase").textContent = left > 0 ? `Get ready… ${Math.ceil(left)}` : "";
      if (left <= 0) { mode = "tap"; tapEvents = []; q(".tr-phase").textContent = "Tap the pulse"; }
      pulseArt(envelopeAt(tapEvents, t, tau));
    } else if (mode === "tap" && clip) {
      pulseArt(envelopeAt(tapEvents, t, tau));
      if (t >= clip.end || audio.ended) finishClip();
    } else if (mode === "replay" && clip) {
      pulseArt(envelopeAt(tapEvents, t, tau));
      if (t >= clip.end || audio.ended) { audio.pause(); showMode("review"); q(".tr-phase").textContent = "Keep it?"; }
    } else if (mode === "preview" && clip) {
      if (previewOld && previewBase) {
        const f = Math.min(previewBase.length - 1, Math.max(0, Math.round(t * FRAME_RATE)));
        pulseArt(previewBase[f]);
      } else if (previewEvents) {
        pulseArt(envelopeAt(previewEvents, t - ai.offsetMs / 1000, tau));
      }
      q(".tr-phase").textContent = previewEvents
        ? (previewOld ? "OLD engine — Tab for AI" : "AI pulse — Tab for the old engine")
        : q(".tr-phase").textContent;
      if (t >= clip.end || audio.ended) { audio.currentTime = clip.start; void audio.play().catch(() => {}); }
    }
  };
  raf = requestAnimationFrame(frame);

  // ── Keys + buttons ──────────────────────────────────────────────────────

  const close = () => {
    if (training) ai.cancel();
    cancelAnimationFrame(raf);
    audio.pause();
    audio.removeAttribute("src");
    document.removeEventListener("keydown", onKey, true);
    document.removeEventListener("keyup", onKeyUp, true);
    overlay.remove();
    if (wasPlaying) o.resumeMain();
  };

  const toHome = () => { track = null; clip = null; showMode("home"); };

  const onKey = (e: KeyboardEvent) => {
    // Swallow everything — Space etc. must never reach the main transport.
    e.stopPropagation();
    const k = e.code;
    if (k === "KeyK") { if (!e.repeat) { extraKey = true; extraPressed(); } e.preventDefault(); return; }
    if (k === "ShiftLeft" || k === "ShiftRight") { if (!e.repeat) extraPressed(); return; }
    if (k === "Space") {
      e.preventDefault();
      if (e.repeat) return;
      if (mode === "lead" || mode === "tap") tap(e);
      return;
    }
    if (k === "Escape") {
      e.preventDefault();
      if (mode === "home") close(); else toHome();
      return;
    }
    if (mode === "tap" && k === "Backspace") {
      e.preventDefault();
      taps.pop(); tapEvents = tapsToEvents(taps); renderTicks();
      return;
    }
    if (mode === "review") {
      if (k === "Enter") { e.preventDefault(); saveAndNext(); }
      else if (k === "KeyR" && track && clip) { e.preventDefault(); void startClip(track, clip); }
      else if (k === "KeyS") { e.preventDefault(); void startClip(pickSong(track?.id)); }
      else if (k === "KeyP") { e.preventDefault(); replay(); }
    } else if (mode === "preview") {
      if (k === "Tab") { e.preventDefault(); previewOld = !previewOld; }
      else if (k === "KeyN") { e.preventDefault(); void startPreview(pickPreviewSong(track?.id)); }
    }
  };
  const onKeyUp = (e: KeyboardEvent) => {
    if (e.code === "KeyK") extraKey = false;
    if (e.code === "Space") e.preventDefault();
    e.stopPropagation();
  };
  document.addEventListener("keydown", onKey, true);
  document.addEventListener("keyup", onKeyUp, true);

  const replay = () => {
    if (!clip) return;
    mode = "replay";
    q(".tr-review").hidden = true;
    q(".tr-phase").textContent = "Replaying your taps…";
    audio.currentTime = clip.start;
    void audio.play().catch(() => {});
  };

  q(".tr-close").onclick = close;
  q(".tr-start").onclick = () => void startClip(pickSong());
  q(".tr-train").onclick = () => void runTraining();
  q(".tr-cancel").onclick = () => ai.cancel();
  q(".tr-preview").onclick = () => void startPreview(pickPreviewSong());
  q(".tr-save").onclick = saveAndNext;
  q(".tr-replay").onclick = replay;
  q(".tr-redo").onclick = () => { if (track && clip) void startClip(track, clip); };
  q(".tr-skip").onclick = () => void startClip(pickSong(track?.id));
  q(".tr-done").onclick = toHome;
  q(".tr-pv-next").onclick = () => void startPreview(pickPreviewSong(track?.id));
  q(".tr-pv-ab").onclick = () => { previewOld = !previewOld; };
  q(".tr-pv-done").onclick = toHome;
  // Buttons keep focus after a click; blur so Space taps never "click" them.
  overlay.addEventListener("click", () => (document.activeElement as HTMLElement | null)?.blur?.());

  void ai.init().then(() => showMode("home")).catch(e => {
    q(".tr-stats").textContent = `Trainer storage unavailable: ${(e as Error).message}`;
  });
  showMode("home");
}
