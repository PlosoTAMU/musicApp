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
import { leaseExpired, sameId, handoffActive, TrackRef } from "./protocol";
import { serverClock } from "./serverClock";
import { LocalTrack, norm, resolve } from "./player";
import { LyricsStore, LyricLine, parseLRC, activeIndex } from "./lyrics";
import { BeatFeed, BeatOutput } from "./beat";
import { AudioGraph } from "./audioGraph";
import { downloadTrack, resolvePlaylist, downloadPlaylistItem } from "./download";
import { PlaylistSync, CloudPlaylist } from "./playlists";
import { SettingsSync } from "./settingsSync";
import { extractYtId, parsePlaylistURL, PlaylistLink } from "./urls";
import { shuffle, fmtDuration, moveIndex } from "./listOps";
import { TrackFxStore } from "./trackFx";
import { showCropSheet } from "./cropSheet";

const coord = new SessionCoordinator(db);
const engine = new SyncEngine(db, coord);
const replicator = new Replicator(db);
const lyricsStore = new LyricsStore(db);
const beatFeed = new BeatFeed();
const graph = new AudioGraph();
const trackFx = new TrackFxStore(localStorage);
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
// Custom drag payload for library→queue drops — kept distinct from the queue
// reorder drag's text/plain so the two gestures never cross (Phase B item 8).
const LIB_DRAG_TYPE = "application/x-pulsor-track";

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
  $("btn-playhere").onclick = () => run(() => engine.takeOverHere());

  // Seek ±10 with press-and-hold twins of the iOS Rewind/FastForward buttons:
  // a quick click jumps ±10 s; holding ⏪ scrubs back 0.5 s every 200 ms, and
  // holding ⏩ plays at 2× until release. The hold effects need the local audio
  // element, so they're owner-only; followers always get the ±10 s click.
  const ownerHold = () => coord.role === "owner";
  bindHoldButton("btn-back10", {
    enabled: ownerHold,
    click: () => seekCmd(Math.max(0, currentPosMs() - 10_000)),
    holdTick: () => engine.seekMs(Math.max(0, engine.player.posMs - 500)),
  });
  bindHoldButton("btn-fwd10", {
    enabled: ownerHold,
    click: () => seekCmd(currentPosMs() + 10_000),
    holdStart: () => {
      const el = engine.player.element;
      el.defaultPlaybackRate = 2; el.playbackRate = 2;  // survives a src swap mid-hold
      engine.publish();                                 // followers extrapolate at 2×
    },
    holdEnd: () => applyFx(true),                        // restore rate from fx state + republish
  });

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
  ($("search-input") as HTMLInputElement).onkeydown = e => {
    if (e.key === "Escape") (e.target as HTMLInputElement).blur();
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
    if (e.code === "Escape") closePop();
    if (e.code === "Slash" || (e.ctrlKey && e.code === "KeyF")) {
      e.preventDefault();
      ($("search-input") as HTMLInputElement).focus();
    }
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
  // Crop from the rail — twin of the iOS Now Playing ✂ button. Acts on the
  // current track when it resolves to a local yt-bearing file (editCrop guards
  // demo + local-only and shows its own hint) [#8].
  $("rail-crop").onclick = () => {
    const cur = currentLocalTrack();
    if (!cur) { showHint("Nothing here to crop"); return; }
    editCrop(cur);
  };
  // Add-to-playlist from the now-playing rail — opens the picker for any device's
  // current track (no need to open a playlist first, like iOS).
  $("rail-addpl").onclick = () => {
    const ref = coord.remote?.playback.track;
    if (!ref) { showHint("Nothing playing"); return; }
    const r = $("rail-addpl").getBoundingClientRect();
    addToPlaylistMenu(r.right, r.bottom,
      ref.yt ? { id: ref.id, name: ref.name, yt: ref.yt } : { id: ref.id, name: ref.name });
  };
  // Rename the current track — double-click the title (desktop idiom for the
  // iOS long-press). Only when it resolves locally [#8].
  $("track-title").ondblclick = () => {
    const cur = currentLocalTrack();
    if (!cur) { showHint("No local track to rename"); return; }
    showPrompt("Rename song", cur.name, v => renameTrack(cur, v));
  };

  // Effects — speed also republishes rate (followers extrapolate with it).
  // Pitch is LOCAL-ONLY (iOS doesn't sync it) — no settings push.
  bindFx("fx-volume", v => { fx.volume = v / 100; });
  bindFx("fx-speed", v => { fx.speed = v / 100; pushSettingsDebounced(); }, true);
  bindFx("fx-pitch", v => { fx.pitch = v; });
  bindFx("fx-bass", v => { fx.bass = v; pushSettingsDebounced(); });
  bindFx("fx-reverb", v => { fx.reverb = v / 100; pushSettingsDebounced(); });

  // fx resets — double-click a slider to reset just that control; "Reset all"
  // resets everything EXCEPT volume (twin of iOS per-slider Reset + Reset All).
  // Re-dispatching "input" reuses each slider's bindFx handler, so the fx state,
  // per-track memory, and settings push all fire exactly as a drag would.
  for (const id of Object.keys(FX_SLIDER_DEFAULT))
    ($(id) as HTMLInputElement).ondblclick = () => resetFxSlider(id);
  $("fx-reset-all").onclick = () => {
    for (const id of ["fx-speed", "fx-pitch", "fx-bass", "fx-reverb"]) resetFxSlider(id);
    showHint("Effects reset");
  };

  settingsSync.onRemote = s => {
    fx.speed = Math.min(Math.max(s.speed, 0.5), 2.0);
    fx.bass = Math.min(Math.max(s.bassDb, -10), 20); // iOS range — clamp fix [#14]
    fx.reverb = Math.min(Math.max(s.reverbPct, 0), 100) / 100;
    initFxSliders(); // updates slider DOM values + calls applyFx()
  };

  // Downloads
  $("btn-dl").onclick = () => void startDownload();
  ($("dl-input") as HTMLInputElement).onkeydown = e => {
    if (e.key === "Enter") void startDownload();
  };
  $("failed-clear").onclick = () => { failed.length = 0; renderFailed(); };
  $("queue-clear").onclick = () => engine.clearQueue();

  // Drag-to-queue drop target — the whole Up Next panel accepts library-row
  // drags (incl. the empty state). Library drags carry LIB_DRAG_TYPE; queue
  // reorder drags carry text/plain, which this handler ignores so the two
  // gestures don't cross. The queue ul persists across renders, so wiring once
  // here is enough.
  const queuePanel = $("upnext-panel");
  queuePanel.addEventListener("dragover", e => {
    if (!e.dataTransfer?.types.includes(LIB_DRAG_TYPE)) return;
    e.preventDefault();
    $("queue").classList.add("drop-hint");
  });
  queuePanel.addEventListener("dragleave", e => {
    if (!queuePanel.contains(e.relatedTarget as Node)) $("queue").classList.remove("drop-hint");
  });
  queuePanel.addEventListener("drop", e => {
    $("queue").classList.remove("drop-hint");
    const id = e.dataTransfer?.getData(LIB_DRAG_TYPE);
    if (!id) return;   // a queue-reorder drop (text/plain) — handled by the row
    e.preventDefault();
    const t = engine.library.find(x => sameId(x.id, id));
    if (t) { engine.queueLocal(t); showHint(`Queued “${t.name}”`); }
  });

  // Bluetooth handoff banner (popup path)
  $("handoff-play").onclick = () => {
    hideHandoffBanner();
    run(() => engine.takeOverHere(true));
  };
  $("handoff-dismiss").onclick = hideHandoffBanner;

  // Per-track fx restore — twin of iOS applyTrackSettings. Restoring also
  // republishes the (speed/bass/reverb) settings doc: like iOS, the sync
  // carries "whichever effective settings are currently audible".
  engine.player.onTrack = t => {
    const s = trackFx.get(t.id);
    fx.speed = s.speed; fx.pitch = s.pitch; fx.reverb = s.reverb; fx.bass = s.bass;
    initFxSliders(); // slider DOM + applyFx()
    pushSettingsDebounced();
  };

  coord.onChange = renderAll;
  engine.onChange = renderAll;
  setInterval(renderNow, 500);
}

const currentPosMs = () =>
  coord.role === "owner" ? engine.player.posMs : engine.mirrorPositionMs();

/** Press-and-hold button (twin of iOS RewindButton/FastForwardButton). A quick
 *  press fires `click`; holding past 400 ms starts the hold (`holdStart` once,
 *  then `holdTick` every 200 ms) and releasing runs `holdEnd` while suppressing
 *  the click. `enabled` gates whether a hold can begin at all — when it returns
 *  false the press is always a plain click. mouseup is on window so a release
 *  outside the button still ends the hold. */
function bindHoldButton(id: string, opts: {
  click: () => void;
  enabled?: () => boolean;
  holdStart?: () => void;
  holdTick?: () => void;
  holdEnd?: () => void;
}) {
  const btn = $(id);
  let holdTimer: ReturnType<typeof setTimeout> | null = null;
  let tickTimer: ReturnType<typeof setInterval> | null = null;
  let held = false, pressed = false;
  const stopTimers = () => {
    if (holdTimer) { clearTimeout(holdTimer); holdTimer = null; }
    if (tickTimer) { clearInterval(tickTimer); tickTimer = null; }
  };
  btn.addEventListener("mousedown", () => {
    pressed = true; held = false;
    if (opts.enabled && !opts.enabled()) return;   // hold disabled → plain click on release
    holdTimer = setTimeout(() => {
      held = true;
      opts.holdStart?.();
      if (opts.holdTick) { opts.holdTick(); tickTimer = setInterval(opts.holdTick, 200); }
    }, 400);
  });
  window.addEventListener("mouseup", () => {
    if (!pressed) return;
    pressed = false;
    stopTimers();
    if (held) { opts.holdEnd?.(); held = false; }
    else opts.click();
  });
}

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
const fx = ((): { volume: number; speed: number; pitch: number; bass: number;
                  reverb: number; bypass: boolean } => {
  // Fresh installs ship with effects BYPASSED, matching iOS effectsBypass=true
  // [#19]. A stored fx (existing installs) keeps whatever the user last set.
  const base = { volume: 1, speed: 1, pitch: 0, bass: 0, reverb: 0, bypass: true };
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
  graph.setBassDb(fx.bypass ? 0 : fx.bass);
  graph.setReverbMix(fx.bypass ? 0 : fx.reverb);
  graph.setPitchSemitones(fx.bypass ? 0 : fx.pitch);
  // Remember the audible values for this track — twin of iOS
  // saveCurrentTrackSettings firing on every effect didSet.
  const cur = engine.player.current;
  if (cur) trackFx.set(cur.id, { speed: fx.speed, pitch: fx.pitch, reverb: fx.reverb, bass: fx.bass });
  localStorage.setItem(FX_KEY, JSON.stringify(fx));
  $("fx-volume-val").textContent = `${Math.round(fx.volume * 100)}%`;
  $("fx-speed-val").textContent = `${fx.speed.toFixed(2)}×`;
  $("fx-pitch-val").textContent = `${fx.pitch > 0 ? "+" : ""}${fx.pitch}st`;
  $("fx-bass-val").textContent = `${fx.bass > 0 ? "+" : ""}${fx.bass}dB`;
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
  ($("fx-pitch") as HTMLInputElement).value = String(fx.pitch);
  ($("fx-bass") as HTMLInputElement).value = String(fx.bass);
  ($("fx-reverb") as HTMLInputElement).value = String(Math.round(fx.reverb * 100));
  applyFx();
}

// Slider-unit defaults (not fx-state units): volume 100%, speed 1.00× = 100,
// pitch 0 st, bass 0 dB, reverb 0%. Used by the double-click / Reset-all resets.
const FX_SLIDER_DEFAULT: Record<string, number> = {
  "fx-volume": 100, "fx-speed": 100, "fx-pitch": 0, "fx-bass": 0, "fx-reverb": 0,
};

/** Reset one fx slider to its default and replay its "input" event so the
 *  bound handler applies the change (fx state + per-track memory + sync push). */
function resetFxSlider(id: string) {
  const s = $(id) as HTMLInputElement;
  s.value = String(FX_SLIDER_DEFAULT[id]);
  s.dispatchEvent(new Event("input"));
}

/** The currently-playing track resolved to a local file on this device, or
 *  undefined when nothing plays / it isn't in this library. */
function currentLocalTrack(): LocalTrack | undefined {
  const ref = coord.remote?.playback.track;
  return ref ? resolve(ref, engine.library) : undefined;
}

// ── Downloads (desktop ingest — yt-dlp) ────────────────────────────────────

async function startDownload() {
  const input = $("dl-input") as HTMLInputElement;
  const status = $("dl-status");
  const url = input.value.trim();
  if (!url) return;
  if (!musicDir) { status.textContent = "Choose a music folder first"; return; }
  // Bare playlist/album link → per-track batch pipeline (YouTube or Spotify).
  const set = parsePlaylistURL(url);
  if (set) { input.value = ""; await downloadPlaylistBatch(set); return; }
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
    // Post-download prompt: offer to file the fresh track into a playlist,
    // twin of iOS's auto-prompt after a download completes.
    const newYt = extractYtId(url);
    const newT = newYt ? engine.library.find(t => t.yt === newYt) : undefined;
    if (newT && playlistSync.playlists.length) {
      const r = $("btn-dl").getBoundingClientRect();
      addToPlaylistMenu(r.left, r.bottom,
        newT.yt ? { id: newT.id, name: newT.name, yt: newT.yt } : { id: newT.id, name: newT.name });
    }
    setTimeout(() => {
      if (status.textContent === "Done ✓") status.textContent = "";
    }, 4000);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    pushFailed("Download", msg);
    status.textContent = msg;
  }
}

/** Whole-set download — twin of iOS downloadPlaylist + its sequential queue.
 *  Resolve the set to tracks, skip ones already in the library, then download
 *  ONE AT A TIME with per-track progress; each failure lands its own row in the
 *  failed panel (not one aggregate error). The post-download playlist prompt is
 *  never raised here — this is the batch path (iOS isBatchDownloading). */
async function downloadPlaylistBatch(link: PlaylistLink) {
  const status = $("dl-status");
  let items;
  try {
    items = await resolvePlaylist(link, p => { status.textContent = p.label; });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    pushFailed(link.service === "spotify" ? "Spotify set" : "Playlist", msg);
    status.textContent = msg;
    return;
  }

  // Skip tracks already downloaded — YouTube by videoID (reliable), Spotify by
  // normalized title (best-effort; the yt-dlp filename differs, so a re-run may
  // re-fetch — a known edge, since desktop keys the library by YouTube id).
  const pending = items.filter(it => it.videoID
    ? !engine.library.some(t => t.yt === it.videoID)
    : !engine.library.some(t => norm(t.name) === norm(it.title)));
  const skipped = items.length - pending.length;
  if (!pending.length) {
    status.textContent = skipped
      ? `All ${skipped} track${skipped === 1 ? "" : "s"} already downloaded`
      : "Nothing to download";
    return;
  }

  let done = 0, failedCount = 0;
  for (let i = 0; i < pending.length; i++) {
    const it = pending[i];
    try {
      await downloadPlaylistItem(it, musicDir!,
        p => { status.textContent = `Track ${i + 1}/${pending.length} — ${p.label}`; });
      done++;
      engine.loadLibrary(musicDir!);   // surface each finished track immediately…
      renderLibrary();
      replicator.syncUp();             // …and push it toward the phone
    } catch (e) {
      failedCount++;
      pushFailed(it.title, e instanceof Error ? e.message : String(e));
    }
  }

  status.textContent = `Playlist done — ${done} added` +
    (skipped ? `, ${skipped} already had` : "") +
    (failedCount ? `, ${failedCount} failed` : "");
  setTimeout(() => {
    if (status.textContent?.startsWith("Playlist done")) status.textContent = "";
  }, 6000);
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
  const art = $("art");

  if (!ownerPlaying) {
    if (!vizIdle) {
      vizIdle = true;
      const cv = $("viz") as HTMLCanvasElement;
      vizCtx?.clearRect(0, 0, cv.clientWidth, cv.clientHeight);
      btn.style.transform = "";
      btn.style.boxShadow = "";
      art.style.transform = "";
      art.style.boxShadow = "";
      bpmChip.classList.add("off");
    }
    return;
  }
  vizIdle = false;

  // First playing frame after a click — the gesture Web Audio needs.
  // attach() is async (worklet module load); frames until then just skip.
  if (!graph.attached) {
    if (!graph.attaching) {
      void graph.attach(engine.player.element).then(() => {
        beatFeed.bind(graph.analyser!, graph.sampleRate);
        ($("fx-pitch") as HTMLInputElement).disabled = !graph.pitchAvailable;
        applyFx(); // graph setters were no-ops before the graph existed
      });
    }
    return;
  }
  graph.resume();

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

  // The thumbnail throbs on every beat — twin of the iOS PulsingThumbnailView,
  // with a shadow bloom that swells on the hit.
  art.style.transform = `scale(${(1 + out.pulse * 0.06).toFixed(4)})`;
  art.style.boxShadow =
    `0 ${Math.round(8 + out.pulse * 6)}px ${Math.round(22 + out.pulse * 26)}px rgba(0,0,0,${(0.45 + out.pulse * 0.35).toFixed(3)})`;

  if (out.confidence > 0.5) {
    bpmChip.classList.remove("off");
    bpmChip.textContent = `${Math.round(out.bpm)} bpm`;
  } else {
    bpmChip.classList.add("off");
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

function loadLyrics(force = false) {
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
    const doc = await lyricsStore.get(coord.uid, ref.id, ref.name, dur, force);
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
    // "Try Again" on the terminal not-found/instrumental states — twin of
    // iOS unavailableView. Forces a fresh LRCLIB fetch past both caches.
    if (lyricsMsg === "No lyrics found" || lyricsMsg === "Instrumental track") {
      const b = document.createElement("button");
      b.className = "pill lyr-retry";
      b.textContent = "Try Again";
      b.onclick = () => loadLyrics(true);
      body.appendChild(b);
    }
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
  roleChip.title = coord.demo ? "Offline preview — nothing syncs, playback is local only"
    : coord.role === "owner" ? "This device is playing the audio"
    : "Another device is playing — controls here act as a remote";
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

  const titleText = pb?.track?.name ?? (idle ? "Pick a song →" : "Nothing playing");
  const titleEl = $("track-title"), titleInner = $("track-title-text");
  if (titleInner.textContent !== titleText) {
    titleInner.textContent = titleText;
    // Marquee only when the name actually overflows — measured per change.
    const over = titleInner.scrollWidth - titleEl.clientWidth;
    titleEl.classList.toggle("marquee", over > 8);
    titleEl.style.setProperty("--marq", `${-Math.max(0, over)}px`);
  }
  // ✂ CROPPED badge — twin of the iOS Now Playing capsule. cropFor reads the
  // synced meta, so followers see it too.
  const badgeYt = pb?.track ? (resolve(pb.track, engine.library)?.yt ?? pb.track.yt) : undefined;
  const cw = badgeYt ? replicator.cropFor(badgeYt) : {};
  $("crop-badge").hidden = cw.startMs == null && cw.endMs == null;
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
  // is lit while effects are ACTIVE; bypassed adds a slash + says so) [U9].
  $("rail-loop").classList.toggle("on", engine.player.loop);
  const fxBtn = $("rail-fx");
  fxBtn.classList.toggle("on", !fx.bypass);
  fxBtn.classList.toggle("slash", fx.bypass);
  fxBtn.title = fx.bypass ? "Effects bypassed — click to re-enable"
                          : "Effects active — click to bypass";
  $("rail-lyrics").classList.toggle("on", lyricsOpen);
  // Crop is only meaningful for a local yt-bearing track on a synced session.
  const cropTrack = currentLocalTrack();
  ($("rail-crop") as HTMLButtonElement).disabled = !(cropTrack?.yt && !coord.demo);

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

/** Confirm modal — Electron has no window.confirm(). */
function showConfirm(message: string, onOk: () => void, okLabel = "Delete") {
  closePop();
  const overlay = document.createElement("div");
  overlay.className = "modal-overlay";
  overlay.innerHTML = `<div class="modal-card"><h4>${escapeHtml(message)}</h4>` +
    `<div class="modal-actions"><button class="link modal-cancel">Cancel</button>` +
    `<button class="pill modal-ok">${escapeHtml(okLabel)}</button></div></div>`;
  document.body.appendChild(overlay);
  const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") close(); };
  document.addEventListener("keydown", onKey, true);
  const close = () => { overlay.remove(); document.removeEventListener("keydown", onKey, true); };
  (overlay.querySelector(".modal-ok") as HTMLButtonElement).onclick = () => { close(); onOk(); };
  (overlay.querySelector(".modal-cancel") as HTMLButtonElement).onclick = close;
  overlay.onmousedown = e => { if (e.target === overlay) close(); };
}

/** Add-to-playlist picker — from a track's ⋯ menu or the now-playing rail.
 *  Twin of iOS AddToPlaylistSheet (works from anywhere, not just an open list). */
function addToPlaylistMenu(x: number, y: number, ref: { id: string; name: string; yt?: string }) {
  const items: MenuItem[] = playlistSync.playlists.map(p => ({
    label: p.name,
    onClick: () => { void playlistSync.addTrack(p.id, ref); showHint(`Added to “${p.name}”`); },
  }));
  if (items.length) items.push("sep");
  items.push({
    label: "New playlist…",
    onClick: () => showPrompt("New playlist", "", name => {
      void playlistSync.createWith(name, [ref]);
      showHint(`Added to “${name}”`);
    }),
  });
  showMenu(x, y, items);
}

/** Play a queued track now — resolve, drop it from the queue, play it
 *  (engine pushes the current track onto prev-history first, like iOS). */
function playFromQueue(ref: TrackRef) {
  const local = resolve(ref, engine.library);
  if (!local) { showHint("Not on this device yet"); return; }
  run(() => engine.playFromQueue(local, ref.id));
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

/** Bulk "Add songs" — a checkmark modal over the library (twin of iOS
 *  CreatePlaylistSheet's Add-Songs list). Multi-select, then add all at once to
 *  the given playlist. Tracks already in the playlist are shown pre-marked and
 *  aren't re-addable; a search box narrows a large library [#15]. */
function showSelectSongs(playlistId: string) {
  closePop();
  const pl = playlistSync.get(playlistId);
  if (!pl) return;
  const already = new Set(pl.tracks.map(t => t.id.toLowerCase()));
  const selected = new Set<string>();
  let term = "";

  const overlay = document.createElement("div");
  overlay.className = "modal-overlay";
  overlay.innerHTML =
    `<div class="modal-card select-card"><h4>Add songs to “${escapeHtml(pl.name)}”</h4>` +
    `<input class="modal-input sel-search" type="text" placeholder="Search your library…" />` +
    `<div class="sel-list"></div>` +
    `<div class="modal-actions"><span class="sel-count"></span>` +
    `<button class="link sel-cancel">Cancel</button>` +
    `<button class="pill sel-add" disabled>Add</button></div></div>`;
  document.body.appendChild(overlay);

  const listEl = overlay.querySelector(".sel-list") as HTMLElement;
  const countEl = overlay.querySelector(".sel-count") as HTMLElement;
  const searchEl = overlay.querySelector(".sel-search") as HTMLInputElement;
  const addBtn = overlay.querySelector(".sel-add") as HTMLButtonElement;

  const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") close(); };
  document.addEventListener("keydown", onKey, true);
  const close = () => { overlay.remove(); document.removeEventListener("keydown", onKey, true); };

  const updateCount = () => {
    countEl.textContent = selected.size ? `${selected.size} selected` : "";
    addBtn.disabled = selected.size === 0;
  };

  const renderRows = () => {
    const t = norm(term);
    const rows = engine.library
      .filter(x => !t || norm(x.name).includes(t) || norm(x.folder).includes(t))
      .slice(0, 500);
    listEl.innerHTML = "";
    if (!rows.length) {
      listEl.innerHTML = `<div class="list-empty">${
        engine.library.length ? "No matches" : "Library is empty"}</div>`;
      return;
    }
    for (const x of rows) {
      const inPl = already.has(x.id.toLowerCase());
      const row = document.createElement("div");
      row.className = "sel-row" + ((inPl || selected.has(x.id)) ? " on" : "") + (inPl ? " done" : "");
      const check = document.createElement("span");
      check.className = "sel-check";
      check.textContent = (inPl || selected.has(x.id)) ? "✓" : "";
      row.appendChild(check);
      row.appendChild(thumbEl(x.yt));
      const name = document.createElement("span");
      name.className = "title"; name.textContent = x.name;
      row.appendChild(name);
      if (inPl) {
        const c = document.createElement("span");
        c.className = "chip"; c.textContent = "added";
        row.appendChild(c);
      } else {
        row.onclick = () => {
          const nowOn = !selected.has(x.id);
          nowOn ? selected.add(x.id) : selected.delete(x.id);
          row.classList.toggle("on", nowOn);
          check.textContent = nowOn ? "✓" : "";
          updateCount();
        };
      }
      listEl.appendChild(row);
    }
  };

  searchEl.oninput = () => { term = searchEl.value; renderRows(); };
  (overlay.querySelector(".sel-cancel") as HTMLButtonElement).onclick = close;
  addBtn.onclick = () => {
    const n = selected.size;
    for (const id of selected) {
      const x = engine.library.find(t => sameId(t.id, id));
      if (x) void playlistSync.addTrack(playlistId,
        x.yt ? { id: x.id, name: x.name, yt: x.yt } : { id: x.id, name: x.name });
    }
    close();
    showHint(`Added ${n} song${n === 1 ? "" : "s"} to “${pl.name}”`);
  };
  overlay.onmousedown = e => { if (e.target === overlay) close(); };

  renderRows();
  updateCount();
  searchEl.focus();
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

/** Open the crop editor — twin of iOS CropSongSheet. Needs the cloud doc
 *  (crop is `cropStartMs/cropEndMs` on the library doc, keyed by yt). */
function editCrop(t: LocalTrack) {
  if (!t.yt || coord.demo) { showHint("Crop needs a cloud-synced track"); return; }
  showCropSheet({
    name: t.name,
    fileUrl: pathToFileURL(t.path).href,
    crop: replicator.cropFor(t.yt),
    volume: fx.volume,
    pauseMain: () => {
      const was = coord.role === "owner" && engine.player.playing;
      if (was) engine.pause();
      return was;
    },
    resumeMain: () => engine.play(),
    onApply: r => {
      void replicator.setCrop(t.yt!, r);
      // Twin of iOS applyCrop's restart-with-new-crop when it's the live track:
      // apply the window immediately (the doc echo re-applies it) and restart.
      if (coord.role === "owner" && engine.player.current?.yt === t.yt) {
        engine.player.setCrop(r?.startMs, r?.endMs);
        engine.seekMs(0);
        engine.publish();
      }
      renderNow();
      showHint(r ? "Crop saved" : "Crop removed");
    },
  });
}

let lastMenuXY = { x: 0, y: 0 };
/** Row action menu for a library track (twin of the iOS row context menu). */
function trackMenu(x: number, y: number, t: LocalTrack) {
  lastMenuXY = { x, y };
  const items: MenuItem[] = [
    { label: "Play", onClick: () => run(() => engine.playLocal(t)) },
    { label: "Add to queue", onClick: () => engine.queueLocal(t) },
    { label: "Add to playlist…", onClick: () => addToPlaylistMenu(lastMenuXY.x, lastMenuXY.y,
        t.yt ? { id: t.id, name: t.name, yt: t.yt } : { id: t.id, name: t.name }) },
    "sep",
    { label: "Rename…", onClick: () => showPrompt("Rename song", t.name, v => renameTrack(t, v)) },
    { label: "Song info", onClick: () => showInfoPop(lastMenuXY.x, lastMenuXY.y, t) },
  ];
  if (t.yt && !coord.demo)
    items.push({ label: "Crop…", onClick: () => editCrop(t) });
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

// Playlist play is queue-based with a 2 s double-tap confirm — twin of the
// live iOS PlaylistActionButtons. First activation enqueues the whole list
// into the SHARED queue (visible/reorderable on every device) without
// interrupting; the button flips to "Play now?"/"Shuffle now?", and a second
// activation within 2 s injects those same tracks at the queue front and
// plays immediately. The captured track order is reused by the second tap,
// so a shuffle confirms with the order the user just heard about.
let plPending: { plId: string; kind: "play" | "shuffle"; tracks: LocalTrack[] } | null = null;
let plPendingTimer: ReturnType<typeof setTimeout> | null = null;

function clearPlPending() {
  if (plPendingTimer) clearTimeout(plPendingTimer);
  plPendingTimer = null;
  plPending = null;
}

const isPlPending = (plId: string, kind: "play" | "shuffle") =>
  !!plPending && plPending.plId === plId && plPending.kind === kind;

function playPlaylist(p: CloudPlaylist, doShuffle = false) {
  const kind = doShuffle ? "shuffle" : "play";
  if (isPlPending(p.id, kind)) {
    const tracks = plPending!.tracks;
    clearPlPending();
    run(() => engine.injectAtFront(tracks));
    renderLibrary();
    return;
  }
  clearPlPending();   // starting Play resets a pending Shuffle and vice versa
  let locals = p.tracks
    .map(tr => resolve({ id: tr.id, name: tr.name, folder: "", yt: tr.yt }, engine.library))
    .filter((t): t is LocalTrack => !!t);
  if (!locals.length) {
    error = "None of these songs are on this device yet";
    renderNow();
    return;
  }
  if (doShuffle) locals = shuffle(locals);
  run(() => engine.queueMany(locals));
  plPending = { plId: p.id, kind, tracks: locals };
  plPendingTimer = setTimeout(() => { clearPlPending(); renderLibrary(); }, 2000);
  showHint(`Queued ${locals.length} song${locals.length === 1 ? "" : "s"} — click again to play now`);
  renderLibrary();
}

// Per-playlist total duration, probed lazily and cached (twin of iOS's
// per-card duration line). Cache records the track count it was computed for,
// so an add/remove invalidates it. Shown on every card now [#16], not just the
// open list.
const plDurationCache = new Map<string, { count: number; seconds: number }>();
const plDurationPending = new Set<string>();

/** Cached total seconds for a playlist, or undefined while it (re)computes.
 *  Kicks off the probe on a cache miss / stale count. */
function playlistDuration(p: CloudPlaylist): number | undefined {
  const c = plDurationCache.get(p.id);
  if (c && c.count === p.tracks.length) return c.seconds;
  if (!plDurationPending.has(p.id)) void computePlaylistDuration(p);
  return undefined;
}

function openPlaylist(id: string) {
  openPlaylistId = id;
  renderLibrary();
}

async function computePlaylistDuration(p: CloudPlaylist) {
  plDurationPending.add(p.id);
  const count = p.tracks.length;
  let total = 0;
  for (const tr of p.tracks) {
    const local = resolve({ id: tr.id, name: tr.name, folder: "", yt: tr.yt }, engine.library);
    if (local) { const d = await fileDurationSec(local.path); if (d) total += d; }
  }
  plDurationPending.delete(p.id);
  plDurationCache.set(p.id, { count, seconds: total });
  renderPlaylists();   // refresh whichever cards/open header are showing "…"
}

/** Playlist card context menu (right-click / ⋯): open, play, shuffle, rename, delete. */
function playlistMenu(x: number, y: number, p: CloudPlaylist) {
  showMenu(x, y, [
    { label: "Open", onClick: () => openPlaylist(p.id) },
    { label: isPlPending(p.id, "play") ? "Play now?" : "Play all",
      onClick: () => playPlaylist(p) },
    { label: isPlPending(p.id, "shuffle") ? "Shuffle now?" : "Shuffle all",
      onClick: () => playPlaylist(p, true) },
    "sep",
    { label: "Rename…", onClick: () => showPrompt("Rename playlist", p.name, v => void playlistSync.rename(p.id, v)) },
    { label: "Delete", danger: true, onClick: () => showConfirm(`Delete playlist “${p.name}”?`, () => {
        if (openPlaylistId === p.id) openPlaylistId = null;
        void playlistSync.remove(p.id);
      }) },
  ]);
}

/** Play/Shuffle button for a playlist — flips to "Play now?"/"Shuffle now?"
 *  while its 2 s confirm window is open (twin of the iOS capsule buttons). */
function plActionBtn(p: CloudPlaylist, kind: "play" | "shuffle"): HTMLButtonElement {
  const pending = isPlPending(p.id, kind);
  const b = rowBtn(
    pending ? (kind === "play" ? "Play now?" : "Shuffle now?") : (kind === "play" ? "▶" : "🔀"),
    pending ? "Click again to play immediately"
      : kind === "play" ? "Play all — adds to the queue" : "Shuffle all — adds to the queue",
    () => playPlaylist(p, kind === "shuffle"));
  if (pending) b.classList.add("confirm");
  return b;
}

function renderPlaylists() {
  const n = playlistSync.playlists.length;
  $("pl-count").textContent = n ? String(n) : "";
  const listEl = $("pl-list");
  listEl.innerHTML = "";
  const playingRef = coord.remote?.playback.track;
  const playingLocal = playingRef ? resolve(playingRef, engine.library) : undefined;

  const open = openPlaylistId ? playlistSync.get(openPlaylistId) : undefined;
  if (openPlaylistId && !open) openPlaylistId = null; // deleted elsewhere

  if (open) {
    // Detail: back / name / count·duration / add-songs / shuffle / play-all /
    // rename / delete, then the tracks (drag to reorder).
    const dur = playlistDuration(open);
    const head = document.createElement("li");
    head.appendChild(rowBtn("←", "All playlists", () => { openPlaylistId = null; renderLibrary(); }));
    head.appendChild(titleSpan(open.name));
    head.appendChild(chipSpan(`${open.tracks.length} · ${dur != null ? fmtDuration(dur) : "…"}`));
    head.appendChild(rowBtn("＋", "Add songs", () => showSelectSongs(open.id)));
    head.appendChild(plActionBtn(open, "play"));
    head.appendChild(plActionBtn(open, "shuffle"));
    head.appendChild(rowBtn("✎", "Rename playlist",
      () => showPrompt("Rename playlist", open.name, v => void playlistSync.rename(open.id, v))));
    head.appendChild(rowBtn("🗑", "Delete playlist", () => showConfirm(
      `Delete playlist “${open.name}”?`, () => { openPlaylistId = null; void playlistSync.remove(open.id); })));
    listEl.appendChild(head);

    if (!open.tracks.length) {
      const d = document.createElement("div");
      d.className = "list-empty";
      d.textContent = "Empty — use ＋ Add songs, ♪ on a library row, or ⋯ → Add to playlist";
      listEl.appendChild(d);
    }
    for (const tr of open.tracks) {
      const local = resolve({ id: tr.id, name: tr.name, folder: "", yt: tr.yt }, engine.library);
      const li = document.createElement("li");
      if (!local) li.className = "ghost";
      // Drag to reorder — persists via playlistSync.reorder.
      li.draggable = true;
      li.ondragstart = e => e.dataTransfer?.setData("text/plain", tr.id);
      li.ondragover = e => e.preventDefault();
      li.ondrop = e => {
        e.preventDefault();
        const dragId = e.dataTransfer?.getData("text/plain");
        if (!dragId || sameId(dragId, tr.id)) return;
        const from = open.tracks.findIndex(x => sameId(x.id, dragId));
        const to = open.tracks.findIndex(x => sameId(x.id, tr.id));
        const arr = moveIndex(open.tracks, from, to);
        if (arr !== open.tracks) void playlistSync.reorder(open.id, arr);
      };
      li.appendChild(thumbEl(tr.yt));
      li.appendChild(titleSpan(tr.name));
      if (!local) li.appendChild(chipSpan("not here yet"));
      // Clicking the playing track's row toggles pause/resume (iOS handleTap);
      // any other row plays that track.
      else if (playingLocal && sameId(playingLocal.id, local.id)) {
        li.classList.add("playing");
        li.onclick = rowClick(toggleCmd);
      }
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
      li.oncontextmenu = e => { e.preventDefault(); playlistMenu(e.clientX, e.clientY, p); };
      li.appendChild(thumbEl(p.tracks.find(t => t.yt)?.yt));   // cover = first art
      li.appendChild(titleSpan(p.name));
      // Count + duration on every card, like iOS PlaylistCardLabel [#16].
      const dur = playlistDuration(p);
      li.appendChild(chipSpan(`${p.tracks.length} · ${dur != null ? fmtDuration(dur) : "…"}`));
      li.appendChild(plActionBtn(p, "play"));
      li.appendChild(plActionBtn(p, "shuffle"));
      const moreBtn = document.createElement("button");
      moreBtn.className = "row-btn"; moreBtn.textContent = "⋯"; moreBtn.title = "More actions";
      moreBtn.onclick = () => { const r = moreBtn.getBoundingClientRect(); playlistMenu(r.right, r.bottom, p); };
      li.appendChild(moreBtn);
      li.onclick = rowClick(() => openPlaylist(p.id));
      listEl.appendChild(li);
    }
  }
}

// ── Render: expensive path (queue + library rows) ──────────────────────────

function renderAll() { renderNow(); renderLibrary(); }

function renderLibrary() {
  if (coord.role === "none") return;
  renderPlaylists();

  // "Playing" highlight + pause/resume toggle match by resolved id, not name —
  // duplicate titles no longer double-highlight [U12].
  const playingRef = coord.remote?.playback.track;
  const playingLocal = playingRef ? resolve(playingRef, engine.library) : undefined;

  // Up Next — from REMOTE refs (session truth); ghosts flagged, not hidden.
  const queueEl = $("queue");
  queueEl.innerHTML = "";
  const q = coord.remote?.queue ?? [];
  $("upnext-count").textContent = q.length ? String(q.length) : "";

  // Previously Played — owner-local history, oldest→newest so the most recent
  // sits at the bottom (twin of iOS "Previous"). Muted; click replays. A
  // follower's history is empty, so this is owner-only.
  const prev = coord.role === "owner" ? engine.previousTracks : [];
  if (prev.length) {
    const head = document.createElement("li");
    head.className = "queue-section";
    head.textContent = "Previously Played";
    queueEl.appendChild(head);
    for (const t of prev) {
      const li = document.createElement("li");
      li.className = "previous";
      li.appendChild(thumbEl(t.yt));
      li.appendChild(titleSpan(t.name));
      li.onclick = rowClick(() => run(() => engine.playFromHistory(t)));
      li.oncontextmenu = e => { e.preventDefault(); trackMenu(e.clientX, e.clientY, t); };
      queueEl.appendChild(li);
    }
  }

  // Status strip — "PLAYING FROM QUEUE · N songs" (previous + current + queue),
  // shown whenever something is playing. Twin of the iOS QueueView strip.
  const hasCurrent = !!playingRef;
  $("queue-status").hidden = !hasCurrent;
  $("queue-status-count").textContent =
    `${prev.length + (hasCurrent ? 1 : 0) + q.length} songs`;

  $("queue-clear").hidden = q.length === 0 && prev.length === 0;
  if (q.length === 0) {
    const d = document.createElement("div");
    d.className = "list-empty";
    d.textContent = "Queue is empty — hover a library song and press ＋, or drag songs in";
    queueEl.appendChild(d);
  }
  q.forEach((ref, i) => {
    const ghost = engine.isGhost(ref);
    const syncing = ghost && replicator.status.includes(ref.name);
    const li = document.createElement("li");
    li.className = syncing ? "ghost syncing" : ghost ? "ghost" : "";
    // Drag to reorder — place the dragged item just before this row (afterId =
    // the row above it; null when this is the head → moves to front).
    li.draggable = true;
    li.ondragstart = e => e.dataTransfer?.setData("text/plain", ref.id);
    li.ondragover = e => e.preventDefault();
    li.ondrop = e => {
      e.preventDefault();
      const dragId = e.dataTransfer?.getData("text/plain");
      if (!dragId || sameId(dragId, ref.id)) return;
      const afterId = i > 0 ? q[i - 1].id : null;
      // Dropping onto the row just below the source is a no-op: the anchor above
      // the target *is* the dragged row, and rebase can't anchor to a row it just
      // removed — it would otherwise fling the item to the tail.
      if (afterId && sameId(afterId, dragId)) return;
      engine.queueMove(dragId, afterId);
    };
    li.appendChild(thumbEl(ref.yt));
    const t = document.createElement("span");
    t.className = "title"; t.textContent = ref.name;
    li.appendChild(t);
    // A resolvable queued track plays on click (drops out of the queue) —
    // unless it IS the playing track (a duplicate), then click toggles. It also
    // gets the full row context menu (rename/redownload/…) [#14].
    if (!ghost) {
      const localQ = resolve(ref, engine.library);
      li.onclick = rowClick(
        localQ && playingLocal && sameId(playingLocal.id, localQ.id)
          ? toggleCmd : () => playFromQueue(ref));
      if (localQ)
        li.oncontextmenu = e => { e.preventDefault(); trackMenu(e.clientX, e.clientY, localQ); };
    }
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
  });

  // Library — filtered, capped for DOM sanity (cap surfaced below [U6]).
  const listEl = $("library-list");
  listEl.innerHTML = "";
  const term = norm(searchTerm);
  const filtered = engine.library
    .filter(t => !term || norm(t.name).includes(term) || norm(t.folder).includes(term));
  const rows = filtered.slice(0, 500);
  if (rows.length === 0) {
    listEl.innerHTML = `<div class="list-empty">${
      engine.library.length === 0 ? "Choose a music folder below" : "No matches"}</div>`;
  }
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

    // Clicking the playing track's row = pause/resume toggle, like tapping the
    // current row on iOS (DownloadRow.handleTap); other rows play fresh.
    const isCurrent = !!playingLocal && sameId(playingLocal.id, t.id);
    if (isCurrent) li.className = "playing";
    li.onclick = rowClick(isCurrent ? toggleCmd : () => run(() => engine.playLocal(t)));
    li.oncontextmenu = e => { e.preventDefault(); trackMenu(e.clientX, e.clientY, t); };

    // Draggable into the queue panel — carries the custom LIB_DRAG_TYPE so the
    // queue's reorder gesture (text/plain) doesn't pick it up [#10].
    li.draggable = true;
    li.ondragstart = e => {
      e.dataTransfer?.setData(LIB_DRAG_TYPE, t.id);
      if (e.dataTransfer) e.dataTransfer.effectAllowed = "copy";
    };

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

  // Cap indicator — the 500-row slice used to be silent [U6].
  if (filtered.length > rows.length) {
    const d = document.createElement("div");
    d.className = "list-empty";
    d.textContent = `Showing ${rows.length} of ${filtered.length} — search to narrow`;
    listEl.appendChild(d);
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
