// Fullscreen desktop UI. Two render paths: renderNow() on the 500 ms
// extrapolation tick (cheap), renderLibrary() only on scan/search/queue
// changes (row building is the expensive part).
import { ipcRenderer } from "electron";
import { pathToFileURL } from "url";
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

const coord = new SessionCoordinator(db);
const engine = new SyncEngine(db, coord);
const replicator = new Replicator(db);
const lyricsStore = new LyricsStore(db);
const beatFeed = new BeatFeed();
const playlistSync = new PlaylistSync(db);

const SECRET_KEY = "pulsor.secret";
const DIR_KEY = "sync.music.dir";

let error: string | undefined;
let busy = false;
let dragMs: number | null = null;
let musicDir: string | null = localStorage.getItem(DIR_KEY);
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

async function connect(secret: string) {
  const uid = await bootstrapAuth(secret);
  await coord.attach(uid);
  playlistSync.start(uid);
  if (musicDir) {
    engine.loadLibrary(musicDir);
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
    catch (e) { error = e instanceof Error ? e.message : String(e); }
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
  $("btn-toggle").onclick = () => {
    coord.remote?.playback.playing ? engine.pause() : engine.play();
  };
  $("btn-playhere").onclick = () => run(() => engine.takeOverHere());

  const slider = $("progress") as HTMLInputElement;
  slider.oninput = () => { dragMs = Number(slider.value); };
  slider.onchange = () => {
    if (dragMs !== null) { engine.seekMs(dragMs); dragMs = null; }
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
    if (e.code === "ArrowRight") engine.seekMs(currentPosMs() + 10_000);
    if (e.code === "ArrowLeft") engine.seekMs(Math.max(0, currentPosMs() - 10_000));
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

  // Effects — speed also republishes rate (followers extrapolate with it).
  bindFx("fx-volume", v => { fx.volume = v / 100; });
  bindFx("fx-speed", v => { fx.speed = v / 100; }, true);
  bindFx("fx-bass", v => { fx.bass = v; });
  bindFx("fx-reverb", v => { fx.reverb = v / 100; });

  // Downloads
  $("btn-dl").onclick = () => void startDownload();
  ($("dl-input") as HTMLInputElement).onkeydown = e => {
    if (e.key === "Enter") void startDownload();
  };

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

// ── Effects (element + Web Audio graph; persisted per install) ─────────────

const FX_KEY = "fx.v1";
const fx = ((): { volume: number; speed: number; bass: number; reverb: number } => {
  const base = { volume: 1, speed: 1, bass: 0, reverb: 0 };
  try { return { ...base, ...JSON.parse(localStorage.getItem(FX_KEY) ?? "{}") }; }
  catch { return base; }
})();

function applyFx(publishRate = false) {
  const el = engine.player.element;
  el.volume = fx.volume;
  el.defaultPlaybackRate = fx.speed; // survives src changes
  el.playbackRate = fx.speed;
  (el as HTMLAudioElement & { preservesPitch: boolean }).preservesPitch = true;
  beatFeed.setBassDb(fx.bass);
  beatFeed.setReverbMix(fx.reverb);
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
    status.textContent = e instanceof Error ? e.message : String(e);
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
    d.onclick = () => engine.seekMs(Math.max(0, line.timeMs + lyricsOffsetMs));
    body.appendChild(d);
  }
  updateLyricsHighlight();
}

/** 500 ms tick: move the highlight. LRC times are file-relative; desktop
 *  session positions are file-relative too EXCEPT when iOS owns playback of
 *  a cropped track (TrackRef carries no crop info) — then lines run early by
 *  cropStart, and the shared offsetMs nudge is the manual fix. */
function updateLyricsHighlight() {
  if (!lyricsLines) return;
  const idx = activeIndex(lyricsLines, currentPosMs(), lyricsOffsetMs) ?? -1;
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

function renderNow() {
  const connected = coord.role !== "none";
  $("setup").hidden = connected;
  $("main").hidden = !connected;
  $("error").textContent = error ?? "";
  $("busy").hidden = !busy;
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
  ($("btn-playhere") as HTMLButtonElement).hidden = coord.role === "owner";
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

  const live = currentPosMs();
  const dur = coord.role === "owner" ? engine.player.durMs : (pb?.dur ?? 0);
  const shown = dragMs ?? Math.min(live, dur);
  const slider = $("progress") as HTMLInputElement;
  slider.max = String(Math.max(dur, 1));
  if (dragMs === null) slider.value = String(shown);
  slider.style.setProperty("--fill", `${dur > 0 ? (shown / dur) * 100 : 0}%`);
  $("time-cur").textContent = mmss(shown);
  $("time-dur").textContent = mmss(dur);

  $("lib-status").textContent = `${engine.library.length} local tracks`;
  $("repl-status").textContent = replicator.status;

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
      else li.ondblclick = () => run(() => engine.playLocal(local));
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
      li.ondblclick = () => { openPlaylistId = p.id; renderLibrary(); };
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
    if (playingName && norm(playingName) === norm(t.name)) li.className = "playing";
    li.ondblclick = () => run(() => engine.playLocal(t));

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

    listEl.appendChild(li);
  }
}

// ── Boot: auto-connect — the whole point of the shared secret ──────────────

wire();
if (musicDir) engine.loadLibrary(musicDir);
renderAll();
requestAnimationFrame(vizLoop);
initFxSliders();
void outputSet().then(s => { knownOutputs = s; });
navigator.mediaDevices.addEventListener("devicechange", () => void handleDeviceChange());
const savedSecret = localStorage.getItem(SECRET_KEY);
if (savedSecret) run(() => connect(savedSecret));

export type { LocalTrack };
