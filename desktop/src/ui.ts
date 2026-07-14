// Fullscreen desktop UI. Three render paths: renderPosition() at rAF while
// playing (slider + clock only), renderNow() on the 500 ms extrapolation tick
// (cheap), renderLibrary() only on scan/search/queue changes (row building is
// the expensive part).
import { ipcRenderer } from "electron";
import { pathToFileURL } from "url";
import * as fs from "fs";
import * as path from "path";
import { db, bootstrapAuth } from "./firebase";
import { SessionCoordinator } from "./coordinator";
import { SyncEngine } from "./engine";
import { Replicator } from "./replicator";
import { leaseExpired, sameId, handoffActive } from "./protocol";
import { serverClock } from "./serverClock";
import { LocalTrack, norm, resolve } from "./player";
import { LyricsStore, LyricLine, parseLRC, activeIndex } from "./lyrics";
import { BeatFeed, BeatOutput } from "./beat";
import { downloadTrack } from "./download";
import { PlaylistSync, CloudPlaylist } from "./playlists";
import { SettingsSync } from "./settingsSync";
import { extractYtId } from "./urls";

const coord = new SessionCoordinator(db);
const engine = new SyncEngine(db, coord);
const replicator = new Replicator(db);
const lyricsStore = new LyricsStore(db);
const beatFeed = new BeatFeed();
const playlistSync = new PlaylistSync(db);
const settingsSync = new SettingsSync(db);

// Wire crop lookups so the player trims audio to the stored crop window and so
// changes pushed from another device take effect on the live track immediately.
engine.cropLookup = yt => replicator.cropFor(yt);
replicator.onCropChanged = yt => {
  if (engine.player.current?.yt === yt) { engine.refreshCurrentCrop(); renderNow(); }
};

// Propagate offset nudges from other devices to the live lyrics panel
// without reloading the full lyrics doc.
lyricsStore.onOffset = (trackId, offsetMs) => {
  if (lyricsTrackId && sameId(lyricsTrackId, trackId)) {
    lyricsOffsetMs = offsetMs;
    $("lyr-off").textContent =
      `${offsetMs >= 0 ? "+" : ""}${(offsetMs / 1000).toFixed(1)}s`;
    lyricsActiveIdx = -1;
    updateLyricsHighlight();
  }
};

const SECRET_KEY = "pulsor.secret";
const DIR_KEY = "sync.music.dir";

let error: string | undefined;
let busy = false;
let dragMs: number | null = null;
let musicDir: string | null = localStorage.getItem(DIR_KEY);
let watchTimer: ReturnType<typeof setTimeout> | null = null;
function watchMusicDir(dir: string) {
  try {
    fs.watch(dir, { recursive: true }, () => {
      if (watchTimer) clearTimeout(watchTimer);
      watchTimer = setTimeout(() => {
        engine.loadLibrary(dir);
        renderLibrary();
        replicator.syncUp();  // pump → reconcile pushes renames/moves/deletes
      }, 2000);
    });
  } catch { /* fs.watch unavailable — edits sync on next launch/download */ }
}
let searchTerm = "";
let lastArtYt: string | undefined | null = null; // null = uninitialized

// Lyrics panel state — lines come from the shared Firestore/LRCLIB cache.
let lyricsOpen = false;
let lyricsTrackId: string | null = null;
let lyricsLines: LyricLine[] | null = null;
let lyricsPlain: string | null = null;
let lyricsMsg = "";
let lyricsOffsetMs = 0;
let lyricsActiveIdx = -1;
let lyricsSeq = 0; // stale-response guard across track changes

const $ = (id: string) => document.getElementById(id)!;
const mmss = (ms: number) => {
  const s = Math.floor(Math.max(0, ms) / 1000);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
};

const ICON_PLAY =
  '<svg viewBox="0 0 24 24"><path d="M8 5.8v12.4c0 .8.9 1.3 1.6.9l9.9-6.2c.6-.4.6-1.4 0-1.8L9.6 4.9c-.7-.4-1.6.1-1.6.9z"/></svg>';
const ICON_PAUSE =
  '<svg viewBox="0 0 24 24"><path d="M7 5h3.4v14H7zM13.6 5H17v14h-3.4z"/></svg>';

// ── Connection ─────────────────────────────────────────────────────────────

// A hung stage must surface as an error, not an eternal spinner. The timeout
// doesn't cancel the underlying call — if it completes late, state heals.
const withTimeout = <T>(p: Promise<T>, label: string, ms = 25_000): Promise<T> =>
  Promise.race([
    p,
    new Promise<T>((_, rej) => setTimeout(() =>
      rej(new Error(`${label} timed out — check firewall/VPN, then retry`)), ms)),
  ]);

let connectStage = "";

async function connect(secret: string) {
  connectStage = "Signing in…"; renderNow();
  const uid = await withTimeout(bootstrapAuth(secret), "Sign-in");
  connectStage = "Opening session…"; renderNow();
  await withTimeout(coord.attach(uid), "Session load");
  connectStage = "";
  playlistSync.start(uid);
  settingsSync.start(uid);
  if (musicDir) {
    engine.loadLibrary(musicDir);
    watchMusicDir(musicDir);
    replicator.onChange = renderNow;
    replicator.start(uid, musicDir, () => engine.library, () => {
      engine.loadLibrary(musicDir!);
      renderLibrary();
    });
    engine.onLibraryChange = () => replicator.syncUp();
    replicator.syncUp();
  }
  localStorage.setItem(SECRET_KEY, secret);
}

function run(op: () => Promise<void>) {
  busy = true; error = undefined; renderNow();
  void (async () => {
    try { await op(); }
    catch (e) {
      error = e instanceof Error ? e.message : String(e);
      console.error("[pulsor]", e); // full detail in DevTools (Ctrl+Shift+I)
    }
    busy = false; renderNow();
  })();
}

// ── Wiring ─────────────────────────────────────────────────────────────────

function wire() {
  // Setup screen
  $("btn-setup-folder").onclick = async () => {
    const dir: string | undefined = await ipcRenderer.invoke("pick-folder");
    if (dir) {
      musicDir = dir;
      localStorage.setItem(DIR_KEY, dir);
      $("setup-folder-label").textContent = dir;
    }
  };
  $("btn-connect").onclick = () => {
    const secret = ($("secret-input") as HTMLInputElement).value.trim();
    if (secret.length < 4) { error = "Secret must be at least 4 characters"; renderNow(); return; }
    run(() => connect(secret));
  };
  ($("secret-input") as HTMLInputElement).onkeydown = e => {
    if (e.key === "Enter") ($("btn-connect") as HTMLButtonElement).click();
  };

  // Offline preview: no auth, no Firestore — full UI + local playback only.
  $("btn-demo").onclick = () => {
    coord.attachDemo();
    if (musicDir) engine.loadLibrary(musicDir);
    renderAll();
  };

  // Transport (command-bus bridge: local when owner, command doc otherwise)
  $("btn-prev").onclick = () => engine.prev();
  $("btn-next").onclick = () => engine.next();
  $("btn-toggle").onclick = toggleCmd;
  $("btn-back10").onclick = () => seekCmd(Math.max(0, currentPosMs() - 10_000));
  $("btn-fwd10").onclick = () => seekCmd(currentPosMs() + 10_000);
  $("btn-playhere").onclick = () => run(() => engine.takeOverHere());

  const slider = $("progress") as HTMLInputElement;
  slider.oninput = () => { dragMs = Number(slider.value); };
  slider.onchange = () => {
    if (dragMs !== null) { seekCmd(dragMs); dragMs = null; }
  };

  // Library
  ($("search-input") as HTMLInputElement).oninput = e => {
    searchTerm = (e.target as HTMLInputElement).value;
    renderLibrary();
  };
  $("btn-library").onclick = async () => {
    const dir: string | undefined = await ipcRenderer.invoke("pick-folder");
    if (dir) {
      musicDir = dir;
      localStorage.setItem(DIR_KEY, dir);
      engine.loadLibrary(dir);
      renderLibrary();
      watchMusicDir(dir);
      const secret = localStorage.getItem(SECRET_KEY);
      if (secret && coord.uid) replicator.start(coord.uid, dir, () => engine.library, () => {
        engine.loadLibrary(dir); renderLibrary();
      });
    }
  };

  // Forget home: clears the secret, back to setup.
  $("btn-forget").onclick = () => {
    localStorage.removeItem(SECRET_KEY);
    replicator.stop();
    playlistSync.stop();
    settingsSync.stop();
    coord.detach();
    renderNow();
  };

  // Playlists
  $("pl-new-btn").onclick = () => void createPlaylist();
  ($("pl-new-input") as HTMLInputElement).onkeydown = e => {
    if (e.key === "Enter") void createPlaylist();
  };
  playlistSync.onChange = renderAll;

  // Keyboard + hardware media keys
  window.addEventListener("keydown", e => {
    if ((e.target as HTMLElement).tagName === "INPUT") return;
    if (e.code === "Space") { e.preventDefault(); ($("btn-toggle") as HTMLButtonElement).click(); }
    if (e.code === "ArrowRight") seekCmd(currentPosMs() + 10_000);
    if (e.code === "ArrowLeft") seekCmd(Math.max(0, currentPosMs() - 10_000));
    if (e.code === "KeyL") ($("btn-lyrics") as HTMLButtonElement).click();
  });
  ipcRenderer.on("media", (_e, t: string) => {
    if (t === "toggle") ($("btn-toggle") as HTMLButtonElement).click();
    if (t === "next") engine.next();
    if (t === "prev") engine.prev();
  });

  // Lyrics
  $("btn-lyrics").onclick = () => {
    lyricsOpen = !lyricsOpen;
    $("lyrics-panel").hidden = !lyricsOpen;
    if (lyricsOpen) loadLyrics();
  };
  $("lyr-minus").onclick = () => nudgeLyrics(-500);
  $("lyr-plus").onclick = () => nudgeLyrics(500);

  // Rail action row (twin of the iOS Now Playing top bar).
  $("rail-loop").onclick = () => {
    engine.player.loop = !engine.player.loop;
    renderNow();
  };
  $("rail-fx").onclick = () => {
    fx.bypass = !fx.bypass;
    // Effective rate changed → owner must re-anchor followers (publish() is a
    // no-op for other roles), same as iOS republishing on $effectsBypass.
    applyFx(true);
    renderNow();
  };
  $("rail-lyrics").onclick = () => ($("btn-lyrics") as HTMLButtonElement).click();
  $("rail-addpl").onclick = () => {
    const ref = coord.remote?.playback.track;
    if (!ref) { showHint("Nothing playing"); return; }
    const open = openPlaylistId ? playlistSync.get(openPlaylistId) : undefined;
    if (!open) { showHint("Open a playlist below first — then this adds the current song"); return; }
    void playlistSync.addTrack(open.id,
      ref.yt ? { id: ref.id, name: ref.name, yt: ref.yt } : { id: ref.id, name: ref.name });
    showHint(`Added “${ref.name}” to “${open.name}”`);
  };

  // Effects — speed also republishes rate (followers extrapolate with it).
  bindFx("fx-volume", v => { fx.volume = v / 100; });
  bindFx("fx-speed", v => { fx.speed = v / 100; pushSettingsDebounced(); }, true);
  bindFx("fx-bass", v => { fx.bass = v; pushSettingsDebounced(); });
  bindFx("fx-reverb", v => { fx.reverb = v / 100; pushSettingsDebounced(); });

  settingsSync.onRemote = s => {
    fx.speed = Math.min(Math.max(s.speed, 0.5), 2.0);
    fx.bass = Math.min(Math.max(s.bassDb, 0), 12);
    fx.reverb = Math.min(Math.max(s.reverbPct, 0), 100) / 100;
    initFxSliders(); // updates slider DOM values + calls applyFx()
  };

  // Downloads
  $("btn-dl").onclick = () => void startDownload();
  ($("dl-input") as HTMLInputElement).onkeydown = e => {
    if (e.key === "Enter") void startDownload();
  };
  $("failed-clear").onclick = () => { failed.length = 0; renderFailed(); };

  // Bluetooth handoff banner (popup path)
  $("handoff-play").onclick = () => {
    hideHandoffBanner();
    run(() => engine.takeOverHere(true));
  };
  $("handoff-dismiss").onclick = hideHandoffBanner;

  coord.onChange = renderAll;
  engine.onChange = renderAll;
  setInterval(renderNow, 500);
}

const currentPosMs = () =>
  coord.role === "owner" ? engine.player.posMs : engine.mirrorPositionMs();

// ── Optimistic follower echo ───────────────────────────────────────────────
// A follower command round-trips 0.7–2 s; patch the mirror immediately — the
// next authoritative snapshot overwrites it wholesale (coordinator replaces
// coord.remote on every snapshot), so no rollback logic is needed.

function toggleCmd() {
  const pb = coord.remote?.playback;
  const playing = !!pb?.playing;
  playing ? engine.pause() : engine.play();
  if (!pb || coord.role === "owner") return;
  pb.pos = Math.round(currentPosMs()); // re-anchor at the shown position
  pb.anchor = serverClock.nowMs;
  pb.playing = !playing;
  renderNow();
}

function seekCmd(ms: number) {
  engine.seekMs(ms);
  const pb = coord.remote?.playback;
  if (!pb || coord.role === "owner") return;
  pb.pos = Math.round(ms);
  pb.anchor = serverClock.nowMs;
  renderNow();
}

// Transient statusline hint — borrows #repl-status for a few seconds; the
// 500 ms renderNow tick hands it back to the replicator automatically.
let hint = "";
let hintUntil = 0;
function showHint(text: string) {
  hint = text;
  hintUntil = Date.now() + 3_500;
  renderNow();
}

// ── Effects (element + Web Audio graph; persisted per install) ─────────────

const FX_KEY = "fx.v1";
// bypass mirrors iOS effectsBypass: mutes the applied effects without touching
// the stored slider values. Local-only on both platforms (not in the settings
// doc); volume is not an effect and stays live while bypassed.
const fx = ((): { volume: number; speed: number; bass: number; reverb: number;
                  bypass: boolean } => {
  const base = { volume: 1, speed: 1, bass: 0, reverb: 0, bypass: false };
  try { return { ...base, ...JSON.parse(localStorage.getItem(FX_KEY) ?? "{}") }; }
  catch { return base; }
})();

let settingsPushTimer: ReturnType<typeof setTimeout> | null = null;
function pushSettingsDebounced() {
  if (settingsPushTimer) clearTimeout(settingsPushTimer);
  settingsPushTimer = setTimeout(() => {
    settingsSync.push({ speed: fx.speed, bassDb: fx.bass, reverbPct: fx.reverb * 100 });
  }, 300);
}

function applyFx(publishRate = false) {
  const el = engine.player.element;
  el.volume = fx.volume;
  const rate = fx.bypass ? 1 : fx.speed;   // bypass → neutral, sliders keep values
  el.defaultPlaybackRate = rate; // survives src changes
  el.playbackRate = rate;
  (el as HTMLAudioElement & { preservesPitch: boolean }).preservesPitch = true;
  beatFeed.setBassDb(fx.bypass ? 0 : fx.bass);
  beatFeed.setReverbMix(fx.bypass ? 0 : fx.reverb);
  localStorage.setItem(FX_KEY, JSON.stringify(fx));
  $("fx-volume-val").textContent = `${Math.round(fx.volume * 100)}%`;
  $("fx-speed-val").textContent = `${fx.speed.toFixed(2)}×`;
  $("fx-bass-val").textContent = `+${fx.bass}dB`;
  $("fx-reverb-val").textContent = `${Math.round(fx.reverb * 100)}%`;
  // Rate feeds follower extrapolation — re-anchor immediately, not on the
  // next transition.
  if (publishRate) engine.publish();
}

function bindFx(id: string, set: (v: number) => void, publishRate = false) {
  const s = $(id) as HTMLInputElement;
  s.oninput = () => { set(Number(s.value)); applyFx(publishRate); };
}

function initFxSliders() {
  ($("fx-volume") as HTMLInputElement).value = String(Math.round(fx.volume * 100));
  ($("fx-speed") as HTMLInputElement).value = String(Math.round(fx.speed * 100));
  ($("fx-bass") as HTMLInputElement).value = String(fx.bass);
  ($("fx-reverb") as HTMLInputElement).value = String(Math.round(fx.reverb * 100));
  applyFx();
}

// ── Downloads (desktop ingest — yt-dlp) ────────────────────────────────────

async function startDownload() {
  const input = $("dl-input") as HTMLInputElement;
  const status = $("dl-status");
  const url = input.value.trim();
  if (!url) return;
  if (!musicDir) { status.textContent = "Choose a music folder first"; return; }
  // Duplicate guard (YouTube only — Spotify's yt id isn't known until it resolves).
  const yt = extractYtId(url);
  if (yt) {
    const dup = engine.library.find(t => t.yt === yt);
    if (dup) { status.textContent = `Already downloaded: ${dup.name}`; return; }
  }
  input.value = "";
  try {
    status.textContent = "Starting…";
    await downloadTrack(url, musicDir, p => { status.textContent = p.label; });
    status.textContent = "Done ✓";
    engine.loadLibrary(musicDir);   // pick the new file up locally…
    renderLibrary();
    replicator.syncUp();            // …and push it to the cloud → phone
    setTimeout(() => {
      if (status.textContent === "Done ✓") status.textContent = "";
    }, 4000);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    pushFailed("Download", msg);
    status.textContent = msg;
  }
}

// ── Bluetooth handoff (desktop half) ───────────────────────────────────────
//
// Output device REMOVED while we own playback → pause immediately + beacon a
// 60 s handoff window. Output ADDED: inside another device's window → seamless
// auto-takeover at the live position; window lapsed → banner asks first.

let pausedByRouteLoss = false;
let knownOutputs: Set<string> | null = null;
let bannerTimer: ReturnType<typeof setTimeout> | undefined;

async function outputSet(): Promise<Set<string>> {
  try {
    const devs = await navigator.mediaDevices.enumerateDevices();
    return new Set(devs.filter(d => d.kind === "audiooutput")
      .map(d => `${d.deviceId}|${d.groupId}`));
  } catch { return new Set(); }
}

async function handleDeviceChange() {
  const now = await outputSet();
  const prev = knownOutputs ?? now;
  knownOutputs = now;
  let added = false, removed = false;
  for (const id of now) if (!prev.has(id)) added = true;
  for (const id of prev) if (!now.has(id)) removed = true;
  if (removed) onOutputRemoved();
  if (added) onOutputAdded();
}

function onOutputRemoved() {
  if (coord.demo || coord.role !== "owner" || !engine.player.playing) return;
  engine.pause();               // spec: no speaker blast — pause instantly
  pausedByRouteLoss = true;
  void coord.postHandoff();
}

function onOutputAdded() {
  if (coord.demo || coord.role === "none") return;

  if (pausedByRouteLoss && coord.role === "owner") {
    // Our own headphones came back — just resume.
    pausedByRouteLoss = false;
    engine.play();
    void coord.clearHandoff();
    return;
  }
  const s = coord.remote;
  if (!s || coord.role === "owner") return;

  if (handoffActive(s, serverClock.nowMs)) {
    hideHandoffBanner();
    run(() => engine.takeOverHere(true));   // headphones hopped here — go
  } else if (s.playback.track) {
    showHandoffBanner(`Audio device connected — continue “${s.playback.track.name}” here?`);
  }
}

function showHandoffBanner(text: string) {
  $("handoff-text").textContent = text;
  $("handoff-banner").hidden = false;
  if (bannerTimer) clearTimeout(bannerTimer);
  bannerTimer = setTimeout(hideHandoffBanner, 20_000);
}

function hideHandoffBanner() {
  $("handoff-banner").hidden = true;
}

// ── Beat visualizer (owner-side only — mirrors have no local audio) ────────

let vizCtx: CanvasRenderingContext2D | null = null;
let vizTrackId: string | null = null;
let vizIdle = true;

function vizLoop(now: number) {
  requestAnimationFrame(vizLoop);
  const ownerPlaying = coord.role === "owner" && engine.player.playing;
  const btn = $("btn-toggle");
  const bpmChip = $("bpm");

  if (!ownerPlaying) {
    if (!vizIdle) {
      vizIdle = true;
      const cv = $("viz") as HTMLCanvasElement;
      vizCtx?.clearRect(0, 0, cv.clientWidth, cv.clientHeight);
      btn.style.transform = "";
      btn.style.boxShadow = "";
      bpmChip.hidden = true;
    }
    return;
  }
  vizIdle = false;

  // First playing frame after a click — the gesture Web Audio needs.
  if (!beatFeed.attached) {
    beatFeed.attach(engine.player.element);
    applyFx(); // bass/reverb setters were no-ops before the graph existed
  }
  beatFeed.resume();

  const curId = engine.player.current?.id ?? null;
  if (curId !== vizTrackId) {
    vizTrackId = curId;
    beatFeed.resetTrack(); // a new song is a new tempo — don't drag the old lock in
  }

  const out = beatFeed.tick(now);
  drawViz(out);

  // The play button IS the head-nod: scale rides the phase-locked nod curve,
  // glow flashes on real hits. Inline styles override the CSS at 60 fps.
  btn.style.transform = `scale(${(1 + out.nod * 0.07).toFixed(4)})`;
  btn.style.boxShadow =
    `0 6px ${Math.round(24 + out.pulse * 30)}px rgba(241,43,38,${(0.45 + out.pulse * 0.4).toFixed(3)})`;

  if (out.confidence > 0.5) {
    bpmChip.hidden = false;
    bpmChip.textContent = `${Math.round(out.bpm)} bpm`;
  } else {
    bpmChip.hidden = true;
  }
}

function drawViz(out: BeatOutput) {
  const cv = $("viz") as HTMLCanvasElement;
  const dpr = window.devicePixelRatio || 1;
  const w = cv.clientWidth, h = cv.clientHeight;
  if (!w || !h) return;
  if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) {
    cv.width = Math.round(w * dpr);
    cv.height = Math.round(h * dpr);
    vizCtx = cv.getContext("2d");
    vizCtx?.setTransform(dpr, 0, 0, dpr, 0, 0); // resize resets ctx state
  }
  vizCtx ??= cv.getContext("2d");
  const c = vizCtx;
  if (!c) return;

  c.clearRect(0, 0, w, h);
  const bins = beatFeed.bins;
  const bw = w / bins.length;
  for (let i = 0; i < bins.length; i++) {
    const v = bins[i];
    const bh = Math.max(1.5, v * (h - 4));
    // red → red-light with intensity; whole strip brightens on the beat pulse
    const alpha = Math.min(1, 0.25 + v * 0.6 + out.pulse * 0.15);
    c.fillStyle = `rgba(${Math.round(241 + 14 * v)},${Math.round(43 + 51 * v)},${Math.round(38 + 46 * v)},${alpha.toFixed(3)})`;
    c.fillRect(i * bw + 1, h - bh, bw - 2, bh);
  }
}

// ── Lyrics ─────────────────────────────────────────────────────────────────

/** Full-file duration (s) via a throwaway Audio element — feeds the LRCLIB
 *  duration guard. Resolves undefined when the file can't be probed. */
const fileDurationSec = (p: string): Promise<number | undefined> =>
  new Promise(res => {
    const a = new Audio();
    a.preload = "metadata";
    a.onloadedmetadata = () => {
      res(isFinite(a.duration) && a.duration > 0 ? Math.round(a.duration) : undefined);
      a.removeAttribute("src");
    };
    a.onerror = () => res(undefined);
    a.src = pathToFileURL(p).href;
  });

function loadLyrics() {
  const ref = coord.remote?.playback.track;
  const seq = ++lyricsSeq;
  lyricsTrackId = ref?.id ?? null;
  lyricsLines = null; lyricsPlain = null; lyricsActiveIdx = -1; lyricsOffsetMs = 0;
  lyricsMsg = ref ? "Loading…" : "Nothing playing";
  renderLyrics();
  if (!ref) return;

  void (async () => {
    // Local file → full duration for the guard; ghosts fetch duration-less
    // (exact /api/get only — fuzzy search stays off without the guard).
    const local = resolve(ref, engine.library);
    const dur = local ? await fileDurationSec(local.path) : undefined;
    const doc = await lyricsStore.get(coord.uid, ref.id, ref.name, dur);
    if (seq !== lyricsSeq) return; // panel moved on to another track

    lyricsOffsetMs = doc.offsetMs ?? 0;
    const lines = doc.synced ? parseLRC(doc.synced) : [];
    if (doc.instrumental) lyricsMsg = "Instrumental track";
    else if (lines.length) { lyricsLines = lines; lyricsMsg = ""; }
    else if (doc.plain) { lyricsPlain = doc.plain; lyricsMsg = ""; }
    else lyricsMsg = "No lyrics found";
    renderLyrics();
  })();
}

function renderLyrics() {
  $("lyrics-sync").hidden = !lyricsLines;
  $("lyr-off").textContent =
    `${lyricsOffsetMs >= 0 ? "+" : ""}${(lyricsOffsetMs / 1000).toFixed(1)}s`;

  const body = $("lyrics-body");
  body.innerHTML = "";
  lyricsActiveIdx = -1;

  if (lyricsMsg) {
    const d = document.createElement("div");
    d.className = "lyr-msg"; d.textContent = lyricsMsg;
    body.appendChild(d);
    return;
  }
  if (lyricsPlain) {
    const d = document.createElement("div");
    d.className = "lyr-plain"; d.textContent = lyricsPlain;
    body.appendChild(d);
    return;
  }
  for (const line of lyricsLines ?? []) {
    const d = document.createElement("div");
    d.className = "lyr-line";
    d.textContent = line.text || "♪";
    d.onclick = () => seekCmd(Math.max(0, line.timeMs - lyricsCropStartMs() + lyricsOffsetMs));
    body.appendChild(d);
  }
  updateLyricsHighlight();
}

/** Returns the crop start (ms, file-absolute) for the currently playing track
 *  when this device is the owner. Followers get 0 — their posMs is the iOS
 *  crop-relative mirror value, so no additional shift is needed. */
function lyricsCropStartMs(): number {
  if (coord.role !== "owner") return 0;
  const yt = engine.player.current?.yt;
  return yt ? (replicator.cropFor(yt).startMs ?? 0) : 0;
}

/** 500 ms tick: move the highlight. LRC times are file-absolute; desktop
 *  posMs is crop-relative when this device owns a cropped track. We add
 *  the crop offset here so both sides land on the right line. */
function updateLyricsHighlight() {
  if (!lyricsLines) return;
  const idx = activeIndex(lyricsLines, currentPosMs() + lyricsCropStartMs(), lyricsOffsetMs) ?? -1;
  if (idx === lyricsActiveIdx) return;
  const body = $("lyrics-body");
  body.querySelector(".lyr-line.active")?.classList.remove("active");
  if (idx >= 0) {
    const el = body.children[idx] as HTMLElement | undefined;
    if (el) {
      el.classList.add("active");
      el.scrollIntoView({ block: "center", behavior: "smooth" });
    }
  }
  lyricsActiveIdx = idx;
}

function nudgeLyrics(deltaMs: number) {
  if (!lyricsTrackId || !lyricsLines) return;
  lyricsOffsetMs += deltaMs;
  $("lyr-off").textContent =
    `${lyricsOffsetMs >= 0 ? "+" : ""}${(lyricsOffsetMs / 1000).toFixed(1)}s`;
  lyricsActiveIdx = -1;
  updateLyricsHighlight();
  void lyricsStore.setOffset(coord.uid, lyricsTrackId, lyricsOffsetMs);
}

// ── Render: cheap path (position, chips, status) ───────────────────────────

/** Position-only update (slider + clock text) — cheap enough for the fast
 *  tick; renderNow calls it too so the two paths can't disagree. */
function renderPosition() {
  const pb = coord.remote?.playback;
  const live = currentPosMs();
  const dur = coord.role === "owner" ? engine.player.durMs : (pb?.dur ?? 0);
  const shown = dragMs ?? Math.min(live, dur);
  const slider = $("progress") as HTMLInputElement;
  slider.max = String(Math.max(dur, 1));
  if (dragMs === null) slider.value = String(shown);
  slider.style.setProperty("--fill", `${dur > 0 ? (shown / dur) * 100 : 0}%`);
  $("time-cur").textContent = mmss(shown);
  $("time-dur").textContent = mmss(dur);
}

// Fast position tick — rAF while playing (owner or mirror) so the slider
// moves smoothly; the full renderNow stays on its 500 ms interval.
function positionLoop() {
  requestAnimationFrame(positionLoop);
  if (coord.role === "none") return;
  const playing = coord.role === "owner"
    ? engine.player.playing : !!coord.remote?.playback.playing;
  if (playing) renderPosition();
}

function renderNow() {
  const connected = coord.role !== "none";
  $("setup").hidden = connected;
  $("main").hidden = !connected;
  $("error").textContent = error ?? "";
  $("busy").hidden = !busy;
  // Setup card gets its own status line — the tiny header error was invisible
  // when a connect failed, which read as "nothing happened".
  $("setup-status").textContent = error ?? (busy ? (connectStage || "Connecting…") : "");
  $("online").className = coord.online ? "dot" : "dot off";
  $("setup-folder-label").textContent = musicDir ?? "No folder chosen";

  const roleChip = $("role");
  roleChip.hidden = !connected;
  roleChip.textContent = coord.demo ? "Offline Preview"
    : coord.role === "owner" ? "Playing Here" : "Remote";
  roleChip.className = !coord.demo && coord.role === "owner" ? "chip owner" : "chip";
  if (!connected) return;

  const s = coord.remote;
  const pb = s?.playback;
  const idle = !s?.ownerDeviceID;
  $("owner-dead").hidden = !(coord.role !== "owner" && !idle && s && leaseExpired(s, serverClock.nowMs));

  // Full remote: while another device owns playback, the rail transport stays
  // LIVE (prev/next/toggle/seek route through the command bus). Instead of a
  // blocking cover we show a status banner + Play Here to take over — the
  // desktop is a true remote of the phone, like iOS is of the desktop.
  const remoteActive = coord.role !== "owner" && !idle;
  $("remote-banner").hidden = !remoteActive;
  $("remote-banner-text").textContent = remoteActive
    ? `Controlling your other device${pb?.track ? ` — ${pb.track.name}` : ""}`
    : "";
  ($("btn-playhere") as HTMLButtonElement).disabled = busy || !coord.online;

  $("track-title").textContent = pb?.track?.name ?? (idle ? "Pick a song →" : "Nothing playing");
  $("eq").hidden = !pb?.playing;
  $("btn-toggle").innerHTML = pb?.playing ? ICON_PAUSE : ICON_PLAY;

  // Hero art — YouTube thumb keyed by the track's yt id; cache the last id so
  // the 500 ms tick doesn't restart the image fetch.
  const artYt = pb?.track?.yt;
  if (artYt !== lastArtYt) {
    lastArtYt = artYt;
    const img = $("art-img") as HTMLImageElement;
    if (artYt) {
      img.src = `https://i.ytimg.com/vi/${artYt}/mqdefault.jpg`;
      img.hidden = false;
      $("art-fallback").hidden = true;
    } else {
      img.removeAttribute("src");
      img.hidden = true;
      $("art-fallback").hidden = false;
    }
  }

  renderPosition();

  // Rail action toggles — filled treatment matches the iOS top bar (fx button
  // is lit while effects are ACTIVE, i.e. not bypassed).
  $("rail-loop").classList.toggle("on", engine.player.loop);
  $("rail-fx").classList.toggle("on", !fx.bypass);
  $("rail-lyrics").classList.toggle("on", lyricsOpen);

  $("lib-status").textContent = `${engine.library.length} local tracks`;
  $("repl-status").textContent = Date.now() < hintUntil ? hint : replicator.status;

  if (lyricsOpen) {
    const cur = pb?.track?.id ?? null;
    const changed = cur === null || lyricsTrackId === null
      ? cur !== lyricsTrackId
      : !sameId(cur, lyricsTrackId);
    if (changed) loadLyrics();
    else updateLyricsHighlight();
  }
}

// ── Playlists (two-way cloud sync — twin of iOS PlaylistSync) ──────────────

let openPlaylistId: string | null = null;

const rowBtn = (label: string, title: string, onclick: () => void): HTMLButtonElement => {
  const b = document.createElement("button");
  b.className = "row-btn"; b.textContent = label; b.title = title; b.onclick = onclick;
  return b;
};

/** Single-click row handler that ignores clicks landing on the row's own action
 *  buttons (▶ ＋ ♪ ✕) — so a plain click on the row plays/opens, but the inline
 *  buttons still do their own thing. Fixes the "rows only respond to
 *  double-click" dead-click on desktop. */
const rowClick = (fn: () => void) => (e: MouseEvent) => {
  if ((e.target as HTMLElement).closest("button")) return;
  fn();
};

const titleSpan = (text: string): HTMLElement => {
  const s = document.createElement("span");
  s.className = "title"; s.textContent = text;
  return s;
};

const chipSpan = (text: string): HTMLElement => {
  const s = document.createElement("span");
  s.className = "chip"; s.textContent = text;
  return s;
};

/** YouTube thumb for rows; no yt id → neutral placeholder block. */
const thumbEl = (yt?: string): HTMLImageElement => {
  const img = document.createElement("img");
  img.className = "thumb";
  if (yt) img.src = `https://i.ytimg.com/vi/${yt}/default.jpg`;
  img.onerror = () => { img.style.visibility = "hidden"; };
  return img;
};

// ── Library management (rename / delete / info / redownload) ────────────────
// FS edits that the replicator then reconciles to the cloud — same shape as
// startDownload. Twins of the iOS row context menu + trash-with-undo.

const escapeHtml = (s: string) =>
  s.replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));

/** Illegal-char lens matching the replicator's sanitize — names round-trip. */
const sanitizeName = (s: string) => s.replace(/[<>:"/\\|?*]/g, "_").trim();

// Popover / menu (single instance; click-away closes).
let openPop: HTMLElement | null = null;
function closePop() {
  openPop?.remove(); openPop = null;
  document.removeEventListener("mousedown", onPopAway, true);
}
function onPopAway(e: MouseEvent) {
  if (openPop && !openPop.contains(e.target as Node)) closePop();
}
function placePop(el: HTMLElement, x: number, y: number) {
  el.style.left = "0"; el.style.top = "0";
  document.body.appendChild(el);
  const r = el.getBoundingClientRect();
  el.style.left = `${Math.max(8, Math.min(x, window.innerWidth - r.width - 8))}px`;
  el.style.top = `${Math.max(8, Math.min(y, window.innerHeight - r.height - 8))}px`;
  openPop = el;
  setTimeout(() => document.addEventListener("mousedown", onPopAway, true), 0);
}

type MenuItem = { label: string; danger?: boolean; onClick: () => void } | "sep";
function showMenu(x: number, y: number, items: MenuItem[]) {
  closePop();
  const m = document.createElement("div");
  m.className = "ctx-menu";
  for (const it of items) {
    if (it === "sep") { const s = document.createElement("div"); s.className = "sep"; m.appendChild(s); continue; }
    const b = document.createElement("button");
    if (it.danger) b.className = "danger";
    b.textContent = it.label;
    b.onclick = () => { closePop(); it.onClick(); };
    m.appendChild(b);
  }
  placePop(m, x, y);
}

/** Song-info popover — twin of iOS SongInfoSheet. */
function showInfoPop(x: number, y: number, t: LocalTrack) {
  closePop();
  const crop = t.yt ? replicator.cropFor(t.yt) : {};
  const rows: [string, string][] = [
    ["Title", t.name],
    ["Source", t.yt ? "YouTube" : "Local file"],
    ["Folder", t.folder || "—"],
    ["Video ID", t.yt ?? "—"],
    ["File", path.basename(t.path)],
    ["Path", t.path],
  ];
  if (crop.startMs != null || crop.endMs != null)
    rows.push(["Crop", `${((crop.startMs ?? 0) / 1000).toFixed(2)}s – ${
      crop.endMs != null ? (crop.endMs / 1000).toFixed(2) + "s" : "end"}`]);
  const pop = document.createElement("div");
  pop.className = "info-pop";
  pop.innerHTML = `<h4>Song info</h4><dl>${
    rows.map(([k, v]) => `<dt>${k}</dt><dd>${escapeHtml(v)}</dd>`).join("")}</dl>`;
  placePop(pop, x, y);
}

/** Text-input modal — Electron has no window.prompt(). Reused for playlists. */
function showPrompt(title: string, initial: string, onOk: (v: string) => void) {
  closePop();
  const overlay = document.createElement("div");
  overlay.className = "modal-overlay";
  overlay.innerHTML = `<div class="modal-card"><h4>${escapeHtml(title)}</h4>` +
    `<input class="modal-input" type="text" /><div class="modal-actions">` +
    `<button class="link modal-cancel">Cancel</button>` +
    `<button class="pill modal-ok">OK</button></div></div>`;
  document.body.appendChild(overlay);
  const input = overlay.querySelector(".modal-input") as HTMLInputElement;
  input.value = initial; input.focus(); input.select();
  const close = () => overlay.remove();
  const ok = () => { const v = input.value.trim(); close(); if (v) onOk(v); };
  (overlay.querySelector(".modal-ok") as HTMLButtonElement).onclick = ok;
  (overlay.querySelector(".modal-cancel") as HTMLButtonElement).onclick = close;
  overlay.onmousedown = e => { if (e.target === overlay) close(); };
  input.onkeydown = e => {
    if (e.key === "Enter") ok();
    if (e.key === "Escape") close();
  };
}

const pendingDeletes = new Map<string, ReturnType<typeof setTimeout>>();

function renameTrack(t: LocalTrack, raw: string) {
  if (!musicDir) return;
  const clean = sanitizeName(raw);
  if (!clean || clean === t.name) return;
  const dir = path.dirname(t.path), ext = path.extname(t.path);
  const tag = t.yt ? ` [${t.yt}]` : "";
  const target = path.join(dir, `${clean}${tag}${ext}`);
  if (fs.existsSync(target)) { showHint("A file with that name already exists"); return; }
  try { fs.renameSync(t.path, target); }
  catch { showHint("Rename failed (file may be in use)"); return; }
  engine.loadLibrary(musicDir); renderLibrary(); replicator.syncUp();
}

function deleteTrack(t: LocalTrack) {
  if (pendingDeletes.has(t.id)) return;
  pendingDeletes.set(t.id, setTimeout(() => commitDelete(t), 5000));
  renderLibrary();
}
function undoDelete(id: string) {
  const timer = pendingDeletes.get(id);
  if (timer) clearTimeout(timer);
  pendingDeletes.delete(id);
  renderLibrary();
}
function commitDelete(t: LocalTrack) {
  pendingDeletes.delete(t.id);
  if (!musicDir) return;
  try { if (fs.existsSync(t.path)) fs.unlinkSync(t.path); }
  catch { showHint("Delete failed (file may be in use)"); renderLibrary(); return; }
  if (engine.player.current?.id === t.id) { engine.player.stop(); engine.publish(); }
  engine.loadLibrary(musicDir); renderLibrary();
  replicator.syncUp(); // reconcile tombstones the cloud doc (local gone + shadow)
}

async function redownloadTrack(t: LocalTrack) {
  if (!t.yt || !musicDir) { showHint("Can't redownload a local-only file"); return; }
  const status = $("dl-status");
  try {
    status.textContent = `Redownloading “${t.name}”…`;
    await downloadTrack(`https://www.youtube.com/watch?v=${t.yt}`, musicDir,
      p => { status.textContent = `${t.name} — ${p.label}`; });
    status.textContent = "Done ✓";
    engine.loadLibrary(musicDir); renderLibrary(); replicator.syncUp();
    setTimeout(() => { if (status.textContent === "Done ✓") status.textContent = ""; }, 4000);
  } catch (e) {
    pushFailed(t.name, e instanceof Error ? e.message : String(e));
    status.textContent = "";
  }
}

let lastMenuXY = { x: 0, y: 0 };
/** Row action menu for a library track (twin of the iOS row context menu). */
function trackMenu(x: number, y: number, t: LocalTrack) {
  lastMenuXY = { x, y };
  const items: MenuItem[] = [
    { label: "Play", onClick: () => run(() => engine.playLocal(t)) },
    { label: "Add to queue", onClick: () => engine.queueLocal(t) },
    "sep",
    { label: "Rename…", onClick: () => showPrompt("Rename song", t.name, v => renameTrack(t, v)) },
    { label: "Song info", onClick: () => showInfoPop(lastMenuXY.x, lastMenuXY.y, t) },
  ];
  if (t.yt) items.push({ label: "Redownload", onClick: () => void redownloadTrack(t) });
  items.push("sep", { label: "Delete", danger: true, onClick: () => deleteTrack(t) });
  showMenu(x, y, items);
}

// Failed downloads (manual + redownload + replicator) — twin of FailedDownloadsBanner.
const failed: { name: string; error: string }[] = [];
function pushFailed(name: string, error: string) {
  failed.unshift({ name, error });
  if (failed.length > 20) failed.pop();
  renderFailed();
}
function renderFailed() {
  const panel = $("failed-panel");
  panel.hidden = failed.length === 0;
  if (!failed.length) return;
  $("failed-title").textContent =
    `${failed.length} download${failed.length === 1 ? "" : "s"} failed`;
  const body = $("failed-body");
  body.innerHTML = "";
  for (const f of failed) {
    const d = document.createElement("div");
    d.className = "fp-item";
    d.innerHTML = `<b>${escapeHtml(f.name)}</b> — ${escapeHtml(f.error)}`;
    body.appendChild(d);
  }
}

async function createPlaylist() {
  const input = $("pl-new-input") as HTMLInputElement;
  const name = input.value.trim();
  if (!name) return;
  input.value = "";
  await playlistSync.create(name);
}

function playPlaylist(p: CloudPlaylist) {
  const locals = p.tracks
    .map(tr => resolve({ id: tr.id, name: tr.name, folder: "", yt: tr.yt }, engine.library))
    .filter((t): t is LocalTrack => !!t);
  if (!locals.length) {
    error = "None of these songs are on this device yet";
    renderNow();
    return;
  }
  run(() => engine.playAll(locals));
}

function renderPlaylists() {
  const n = playlistSync.playlists.length;
  $("pl-count").textContent = n ? String(n) : "";
  const listEl = $("pl-list");
  listEl.innerHTML = "";

  const open = openPlaylistId ? playlistSync.get(openPlaylistId) : undefined;
  if (openPlaylistId && !open) openPlaylistId = null; // deleted elsewhere

  if (open) {
    // Detail: back / name / play-all / delete, then the tracks.
    const head = document.createElement("li");
    head.appendChild(rowBtn("←", "All playlists", () => { openPlaylistId = null; renderLibrary(); }));
    head.appendChild(titleSpan(open.name));
    head.appendChild(rowBtn("▶", "Play all", () => playPlaylist(open)));
    head.appendChild(rowBtn("✕", "Delete playlist", () => {
      openPlaylistId = null;
      void playlistSync.remove(open.id);
    }));
    listEl.appendChild(head);

    if (!open.tracks.length) {
      const d = document.createElement("div");
      d.className = "list-empty";
      d.textContent = "Empty — use ♪ on a library row to add songs";
      listEl.appendChild(d);
    }
    for (const tr of open.tracks) {
      const local = resolve({ id: tr.id, name: tr.name, folder: "", yt: tr.yt }, engine.library);
      const li = document.createElement("li");
      if (!local) li.className = "ghost";
      li.appendChild(thumbEl(tr.yt));
      li.appendChild(titleSpan(tr.name));
      if (!local) li.appendChild(chipSpan("not here yet"));
      else li.onclick = rowClick(() => run(() => engine.playLocal(local)));
      li.appendChild(rowBtn("✕", "Remove from playlist",
        () => void playlistSync.removeTrack(open.id, tr.id)));
      listEl.appendChild(li);
    }
  } else {
    if (!n) {
      const d = document.createElement("div");
      d.className = "list-empty";
      d.textContent = "No playlists yet";
      listEl.appendChild(d);
    }
    for (const p of playlistSync.playlists) {
      const li = document.createElement("li");
      li.appendChild(titleSpan(p.name));
      li.appendChild(chipSpan(String(p.tracks.length)));
      li.appendChild(rowBtn("▶", "Play all", () => playPlaylist(p)));
      li.appendChild(rowBtn("›", "Open", () => { openPlaylistId = p.id; renderLibrary(); }));
      li.onclick = rowClick(() => { openPlaylistId = p.id; renderLibrary(); });
      listEl.appendChild(li);
    }
  }
}

// ── Render: expensive path (queue + library rows) ──────────────────────────

function renderAll() { renderNow(); renderLibrary(); }

function renderLibrary() {
  if (coord.role === "none") return;
  renderPlaylists();

  // Up Next — from REMOTE refs (session truth); ghosts flagged, not hidden.
  const queueEl = $("queue");
  queueEl.innerHTML = "";
  const q = coord.remote?.queue ?? [];
  $("upnext-count").textContent = q.length ? String(q.length) : "";
  if (q.length === 0) {
    queueEl.innerHTML = `<div class="list-empty">Queue is empty</div>`;
  }
  for (const ref of q) {
    const ghost = engine.isGhost(ref);
    const syncing = ghost && replicator.status.includes(ref.name);
    const li = document.createElement("li");
    li.className = syncing ? "ghost syncing" : ghost ? "ghost" : "";
    li.appendChild(thumbEl(ref.yt));
    const t = document.createElement("span");
    t.className = "title"; t.textContent = ref.name;
    li.appendChild(t);
    if (ghost) {
      const chip = document.createElement("span");
      chip.className = "chip";
      chip.textContent = syncing ? "syncing" : "not here yet";
      li.appendChild(chip);
    }
    const rm = document.createElement("button");
    rm.className = "row-btn"; rm.textContent = "✕"; rm.title = "Remove";
    rm.onclick = () => { engine.queueRemove(ref.id); };
    li.appendChild(rm);
    queueEl.appendChild(li);
  }

  // Library — filtered, capped for DOM sanity.
  const listEl = $("library-list");
  listEl.innerHTML = "";
  const term = norm(searchTerm);
  const rows = engine.library
    .filter(t => !term || norm(t.name).includes(term) || norm(t.folder).includes(term))
    .slice(0, 500);
  if (rows.length === 0) {
    listEl.innerHTML = `<div class="list-empty">${
      engine.library.length === 0 ? "Choose a music folder below" : "No matches"}</div>`;
  }
  const playingName = coord.remote?.playback.track?.name;
  for (const t of rows) {
    const li = document.createElement("li");

    // Delete-in-progress row: muted, with an Undo (5 s window). Twin of iOS
    // "Tap to undo (5s)".
    if (pendingDeletes.has(t.id)) {
      li.className = "deleting";
      li.appendChild(thumbEl(t.yt));
      li.appendChild(titleSpan(t.name));
      li.appendChild(chipSpan("deleting…"));
      li.appendChild(rowBtn("Undo", "Undo delete", () => undoDelete(t.id)));
      listEl.appendChild(li);
      continue;
    }

    if (playingName && norm(playingName) === norm(t.name)) li.className = "playing";
    li.onclick = rowClick(() => run(() => engine.playLocal(t)));
    li.oncontextmenu = e => { e.preventDefault(); trackMenu(e.clientX, e.clientY, t); };

    li.appendChild(thumbEl(t.yt));

    const title = document.createElement("span");
    title.className = "title"; title.textContent = t.name;
    li.appendChild(title);

    const folder = document.createElement("span");
    folder.className = "chip"; folder.textContent = t.folder;
    li.appendChild(folder);

    const playBtn = document.createElement("button");
    playBtn.className = "row-btn"; playBtn.innerHTML = "▶"; playBtn.title = "Play here now";
    playBtn.onclick = () => run(() => engine.playLocal(t));
    li.appendChild(playBtn);

    const addBtn = document.createElement("button");
    addBtn.className = "row-btn"; addBtn.textContent = "＋"; addBtn.title = "Add to queue";
    addBtn.onclick = () => { engine.queueLocal(t); };
    li.appendChild(addBtn);

    // With a playlist open, rows grow a one-tap "add to that playlist".
    if (openPlaylistId) {
      li.appendChild(rowBtn("♪", "Add to open playlist", () => {
        void playlistSync.addTrack(openPlaylistId!,
          t.yt ? { id: t.id, name: t.name, yt: t.yt } : { id: t.id, name: t.name });
      }));
    }

    // ⋯ = rename / info / redownload / delete (also on right-click).
    const moreBtn = document.createElement("button");
    moreBtn.className = "row-btn"; moreBtn.textContent = "⋯"; moreBtn.title = "More actions";
    moreBtn.onclick = () => { const r = moreBtn.getBoundingClientRect(); trackMenu(r.right, r.bottom, t); };
    li.appendChild(moreBtn);

    listEl.appendChild(li);
  }
}

// ── Boot: auto-connect — the whole point of the shared secret ──────────────

wire();
if (musicDir) engine.loadLibrary(musicDir);
renderAll();
requestAnimationFrame(vizLoop);
requestAnimationFrame(positionLoop);
initFxSliders();
void outputSet().then(s => { knownOutputs = s; });
navigator.mediaDevices.addEventListener("devicechange", () => void handleDeviceChange());
const savedSecret = localStorage.getItem(SECRET_KEY);
if (savedSecret) run(() => connect(savedSecret));

export type { LocalTrack };
