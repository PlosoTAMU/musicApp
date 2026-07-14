// Windows-side local playback + library. Replaces AudioPlayerManager for this
// client: HTMLAudioElement (Electron's Chromium ships AAC/MP3/Opus decoders).
// Library = user-picked folder, scanned recursively; identity resolution mirrors
// LibraryTrackResolver in Swift: id → yt → name+folder → name.
import * as fs from "fs";
import * as path from "path";
import * as crypto from "crypto";
import { pathToFileURL } from "url";
import { TrackRef, sameId } from "./protocol";
import { byName } from "./listOps";

export interface LocalTrack {
  id: string;          // deterministic UUID from absolute path (stable across scans)
  name: string;        // filename sans extension — the cross-device match key
  folder: string;      // parent dir name
  yt?: string;         // "[<11-char id>]" filename convention when present
  path: string;
}

const AUDIO_EXT = new Set([".mp3", ".m4a", ".aac", ".opus", ".ogg", ".webm", ".wav", ".flac"]);

/** Deterministic UUID-v4-shaped id from a path — same file, same id, every scan. */
function pathId(p: string): string {
  const h = crypto.createHash("sha1").update(p.toLowerCase()).digest("hex");
  return (
    `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-` +
    `${((parseInt(h[16], 16) & 0x3) | 0x8).toString(16)}${h.slice(17, 20)}-${h.slice(20, 32)}`
  ).toUpperCase();
}

function ytFromName(base: string): string | undefined {
  const m = /\[([A-Za-z0-9_-]{11})\]/.exec(base);
  return m?.[1];
}

/** Replicated files carry a trailing " [videoId]" tag — strip it from the
 *  display/match name so it matches the mobile side's original title. */
const stripTag = (base: string) =>
  base.replace(/\s*\[[A-Za-z0-9_-]{11}\]\s*$/, "").trim();

/** Windows-illegal chars were replaced with "_" at replication time; compare
 *  names through the same lens so "What? Song" matches "What_ Song". */
const norm = (s: string) => s.replace(/[<>:"/\\|?*]/g, "_").trim().toLowerCase();

export function scanLibrary(root: string): LocalTrack[] {
  const out: LocalTrack[] = [];
  const walk = (dir: string) => {
    let entries: fs.Dirent[];
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) walk(full);
      else if (AUDIO_EXT.has(path.extname(e.name).toLowerCase())) {
        const base = path.basename(e.name, path.extname(e.name));
        out.push({
          id: pathId(full), name: stripTag(base), folder: path.basename(dir),
          yt: ytFromName(base), path: full,
        });
      }
    }
  };
  walk(root);
  return out.sort(byName); // case-insensitive, like the iOS library
}

export function resolve(ref: TrackRef, lib: LocalTrack[]): LocalTrack | undefined {
  return (
    lib.find(t => sameId(t.id, ref.id)) ??
    (ref.yt ? lib.find(t => t.yt === ref.yt) : undefined) ??
    lib.find(t => t.name === ref.name && t.folder === ref.folder) ??
    lib.find(t => t.name === ref.name) ??
    lib.find(t => norm(t.name) === norm(ref.name))
  );
}

export { norm };

export const toRef = (t: LocalTrack): TrackRef =>
  t.yt ? { id: t.id, name: t.name, folder: t.folder, yt: t.yt }
       : { id: t.id, name: t.name, folder: t.folder };

export class LocalPlayer {
  private el = new Audio();
  current?: LocalTrack;
  queue: LocalTrack[] = [];
  /** Repeat the current track at end-of-track — local-only, like iOS
   *  isLoopEnabled (neither side syncs it). Honored in engine.trackEnded. */
  loop = false;
  onEnded?: () => void;
  onChange?: () => void;
  /** Fires whenever play() starts a track — ui.ts restores per-track fx here
   *  (twin of iOS applyTrackSettings being called from play(_:)). */
  onTrack?: (t: LocalTrack) => void;

  // Crop window (metadata — the file is untouched). All public positions are
  // crop-relative: 0 == cropStart, durMs == cropEnd - cropStart. This matches
  // what iOS publishes for cropped tracks (protocol dur = "cropped length").
  private cropStartMs = 0;
  private cropEndMs?: number;
  private endFired = false;

  setCrop(startMs?: number, endMs?: number) {
    this.cropStartMs = startMs ?? 0;
    this.cropEndMs = endMs;
    this.endFired = false;
  }

  constructor() {
    // "auto" so a paused handover still buffers + honors the queued seek —
    // assigning src already triggers an implicit load().
    this.el.preload = "auto";
    this.el.addEventListener("ended", () => this.onEnded?.());
    this.el.addEventListener("play", () => this.onChange?.());
    this.el.addEventListener("pause", () => this.onChange?.());
    this.el.addEventListener("timeupdate", () => {
      if (this.cropEndMs !== undefined && this.current && !this.endFired
          && this.el.currentTime * 1000 >= this.cropEndMs) {
        this.endFired = true;
        this.onEnded?.();
      }
    });
  }

  /** Exposed for the Web Audio analyser tap (BeatFeed) — read-only use. */
  get element(): HTMLAudioElement { return this.el; }

  get playing() { return !!this.current && !this.el.paused; }
  get posMs() { return Math.max(0, this.el.currentTime * 1000 - this.cropStartMs); }
  get durMs() {
    const raw = Number.isFinite(this.el.duration) ? this.el.duration * 1000 : 0;
    if (!raw) return 0;
    return Math.max(0, Math.min(this.cropEndMs ?? raw, raw) - this.cropStartMs);
  }
  get rateX1000() { return Math.round(this.el.playbackRate * 1000); }

  /** Handover-capable entry point — twin of play(_:at:startPaused:).
   *  NOTE: no explicit load() here — load() resets the element and would
   *  discard the queued pre-metadata seek, so paused handovers landed at 0:00. */
  play(t: LocalTrack, atMs = 0, startPaused = false) {
    this.current = t;
    this.onTrack?.(t);
    this.endFired = false;
    this.el.src = pathToFileURL(t.path).href;  // implicit load()
    this.el.currentTime = (atMs + this.cropStartMs) / 1000;  // crop-relative → absolute
    if (!startPaused) void this.el.play().catch(e => console.log("[player] play failed:", e));
    this.onChange?.();
  }

  resume() { if (this.current) void this.el.play().catch(() => {}); }
  pause() { this.el.pause(); }
  seekMs(ms: number) {
    this.el.currentTime = (ms + this.cropStartMs) / 1000;
    this.endFired = false;
    this.onChange?.();
  }
  stop() { this.el.pause(); this.el.removeAttribute("src"); this.current = undefined; this.onChange?.(); }
}
