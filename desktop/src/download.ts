// Desktop-side ingest — yt-dlp wrapper. Full parity with the phone: paste a
// YouTube or Spotify link, the file lands in the music dir named
// "<title> [<videoId>].<ext>" (the scanner's yt-tag convention, so identity
// resolution and cloud replication pick it up with zero extra plumbing).
//
// Spotify links resolve via the public oEmbed title → yt-dlp "ytsearch1:" —
// the same strategy the iOS pipeline uses. No ffmpeg dependency: bestaudio in
// its native container — highest-abr stream, usually opus/webm — which the
// scanner + Chromium already handle.
import { spawn } from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { PlaylistLink } from "./urls";

export interface DownloadProgress {
  label: string; // human status line: "Downloading… 42%"
}

/** One resolved track in a playlist/album set. `target` is what yt-dlp fetches:
 *  a watch URL (YouTube) or a "ytsearch1:<query>" (Spotify, resolved by title).
 *  `videoID` is present for YouTube only — the library dedupe key. */
export interface PlaylistItem {
  title: string;
  videoID?: string;
  target: string;
}

const PROGRESS_RE = /\[download\]\s+([\d.]+)%/;

/** Pull the download percent out of a yt-dlp stdout chunk. Pure — Node-tested.
 *  Last match in the chunk wins (yt-dlp rewrites the progress line with \r). */
export function parseDlChunk(chunk: string): { pct?: number } {
  const out: { pct?: number } = {};
  for (const line of chunk.split(/\r?\n|\r/)) {
    const m = PROGRESS_RE.exec(line);
    if (m) out.pct = Math.round(parseFloat(m[1]));
  }
  return out;
}

/** Parse `yt-dlp --flat-playlist --print "%(id)s|%(title)s"` output into items.
 *  Pure — Node-tested. Skips malformed lines and de-dupes by id, preserving
 *  order (twin of the iOS YouTube playlist scraper's seen-set). */
export function parseFlatPlaylist(stdout: string): PlaylistItem[] {
  const out: PlaylistItem[] = [];
  const seen = new Set<string>();
  for (const line of stdout.split(/\r?\n/)) {
    const i = line.indexOf("|");
    if (i < 0) continue;
    const id = line.slice(0, i).trim();
    const title = line.slice(i + 1).trim();
    if (!/^[A-Za-z0-9_-]{11}$/.test(id) || seen.has(id)) continue;
    seen.add(id);
    out.push({ title: title || id, videoID: id,
      target: `https://www.youtube.com/watch?v=${id}` });
  }
  return out;
}

/** Extract tracks from a Spotify embed page's `__NEXT_DATA__` blob — twin of
 *  the iOS EmbeddedPython Spotify scraper (props→pageProps→state→data→entity→
 *  trackList). Each item becomes a "ytsearch1:<artist> - <title>" target, the
 *  same query iOS feeds yt-dlp. Pure — Node-tested. Throws on an unreadable
 *  page so the caller can surface a real error. */
export function parseSpotifyEmbed(html: string): PlaylistItem[] {
  const m = /<script\s+id="__NEXT_DATA__"[^>]*>([\s\S]+?)<\/script>/.exec(html);
  if (!m) throw new Error("Couldn't read the Spotify page (embed markup changed?)");
  let data: unknown;
  try { data = JSON.parse(m[1]); }
  catch { throw new Error("Couldn't parse the Spotify page data"); }
  const entity = (data as any)?.props?.pageProps?.state?.data?.entity;
  const list = entity?.trackList;
  if (!Array.isArray(list) || !list.length)
    throw new Error("Spotify returned no tracks for this set");
  const out: PlaylistItem[] = [];
  const seen = new Set<string>();
  for (const item of list) {
    const uri: string = item?.uri ?? "";
    const parts = uri.split(":");
    if (parts.length !== 3 || parts[1] !== "track" || seen.has(parts[2])) continue;
    seen.add(parts[2]);
    const title: string = item?.title ?? "Unknown";
    const subtitle: string = item?.subtitle ?? "";
    const display = subtitle ? `${subtitle} - ${title}` : title;
    out.push({ title: display, target: `ytsearch1:${display}` });
  }
  if (!out.length) throw new Error("Spotify returned no playable tracks");
  return out;
}

async function spotifyToSearch(url: string): Promise<string> {
  const res = await fetch(
    `https://open.spotify.com/oembed?url=${encodeURIComponent(url)}`);
  if (!res.ok) throw new Error("Spotify lookup failed");
  const title = ((await res.json()) as { title?: string }).title;
  if (!title) throw new Error("Spotify lookup returned no title");
  return `ytsearch1:${title}`;
}

// ── yt-dlp resolution: PATH if already installed, else a one-time download
// cached under the user's home dir. No Python/package manager assumed —
// yt-dlp ships self-contained platform binaries on GitHub releases.
const YTDLP_DIR = path.join(os.homedir(), ".pulsor");
const YTDLP_BIN = path.join(YTDLP_DIR, process.platform === "win32" ? "yt-dlp.exe" : "yt-dlp");
const YTDLP_ASSET: Record<string, string> = {
  win32: "yt-dlp.exe",
  darwin: "yt-dlp_macos",   // standalone, no system Python required
  linux: "yt-dlp_linux",    // standalone, no system Python required
};

let ytdlpPath: Promise<string> | undefined;

function isOnPath(): Promise<boolean> {
  return new Promise(resolve => {
    const p = spawn("yt-dlp", ["--version"], { windowsHide: true });
    p.on("error", () => resolve(false));
    p.on("close", code => resolve(code === 0));
  });
}

async function downloadYtDlpBinary(onProgress: (p: DownloadProgress) => void): Promise<void> {
  const asset = YTDLP_ASSET[process.platform] ?? YTDLP_ASSET.linux;
  const url = `https://github.com/yt-dlp/yt-dlp/releases/latest/download/${asset}`;
  onProgress({ label: "Downloading yt-dlp…" });
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Could not download yt-dlp (${res.status})`);
  fs.mkdirSync(YTDLP_DIR, { recursive: true });
  fs.writeFileSync(YTDLP_BIN, Buffer.from(await res.arrayBuffer()), { mode: 0o755 });
}

/** Resolves to a runnable yt-dlp command: "yt-dlp" if it's on PATH, else the
 *  cached download (fetched once, reused after). Memoized per app run. */
function ensureYtDlp(onProgress: (p: DownloadProgress) => void): Promise<string> {
  if (!ytdlpPath) ytdlpPath = (async () => {
    if (fs.existsSync(YTDLP_BIN)) return YTDLP_BIN;
    if (await isOnPath()) return "yt-dlp";
    await downloadYtDlpBinary(onProgress);
    return YTDLP_BIN;
  })().catch(e => { ytdlpPath = undefined; throw e; }); // let a failed fetch retry next call
  return ytdlpPath;
}

/** Download ONE resolved yt-dlp target (a watch URL or "ytsearch1:…") into
 *  `dir`. `--no-playlist` keeps a "watch?v=…&list=…" link to the single video. */
function runYtDlp(
  target: string, bin: string, dir: string, onProgress: (p: DownloadProgress) => void,
): Promise<void> {
  const args = [
    // Quality over space on desktop (iOS deliberately keeps 128 kbps m4a for
    // space): plain bestaudio picks the highest-abr stream YouTube serves,
    // typically ~160 kbps VBR Opus in webm — Chromium + the scanner already
    // handle opus/webm natively.
    "-f", "bestaudio",
    "--no-playlist",
    "-o", path.join(dir, "%(title)s [%(id)s].%(ext)s"),
    target,
  ];
  return new Promise<void>((resolve, reject) => {
    const p = spawn(bin, args, { windowsHide: true });
    p.stdout.on("data", (b: Buffer) => {
      const f = parseDlChunk(b.toString());
      if (f.pct !== undefined) onProgress({ label: `Downloading… ${f.pct}%` });
    });
    let stderr = "";
    p.stderr.on("data", (b: Buffer) => { stderr += b.toString(); });
    p.on("error", (e: NodeJS.ErrnoException) => {
      reject(e.code === "ENOENT"
        ? new Error("yt-dlp not found and auto-download failed — check your connection")
        : e);
    });
    p.on("close", code => {
      if (code === 0) resolve();
      else reject(new Error(`yt-dlp failed (${code}): ${stderr.slice(-200)}`));
    });
  });
}

/** Downloads one track into `dir`, auto-fetching yt-dlp itself on first run if
 *  it's not already installed. Spotify track links resolve via oEmbed title →
 *  ytsearch1 (the iOS strategy). Bare playlist/album links go through
 *  resolvePlaylist + downloadPlaylistItem instead (see ui.ts). */
export async function downloadTrack(
  url: string, dir: string, onProgress: (p: DownloadProgress) => void,
): Promise<void> {
  const [target, bin] = await Promise.all([
    /open\.spotify\.com/.test(url) ? spotifyToSearch(url) : Promise.resolve(url),
    ensureYtDlp(onProgress),
  ]);
  await runYtDlp(target, bin, dir, onProgress);
}

/** Download one already-resolved playlist item (batch pipeline). yt-dlp is
 *  memoized, so calling this per track only pays the ensure cost once. */
export async function downloadPlaylistItem(
  item: PlaylistItem, dir: string, onProgress: (p: DownloadProgress) => void,
): Promise<void> {
  const bin = await ensureYtDlp(onProgress);
  await runYtDlp(item.target, bin, dir, onProgress);
}

const SPOTIFY_UA =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/** Resolve a bare playlist/album link to its track list WITHOUT downloading —
 *  twin of iOS fetchYouTubePlaylistTracks / fetchSpotifyPlaylistTracks.
 *  YouTube: yt-dlp --flat-playlist enumeration. Spotify: the public embed page
 *  (no auth), the same endpoint the iOS embedded-python script scrapes. */
export async function resolvePlaylist(
  link: PlaylistLink, onProgress: (p: DownloadProgress) => void,
): Promise<PlaylistItem[]> {
  if (link.service === "spotify") {
    onProgress({ label: "Reading Spotify set…" });
    const endpoint = link.isAlbum ? "album" : "playlist";
    const res = await fetch(`https://open.spotify.com/embed/${endpoint}/${link.id}`, {
      headers: { "User-Agent": SPOTIFY_UA, "Accept-Language": "en-US,en;q=0.9" },
    });
    if (!res.ok) throw new Error(`Spotify page returned HTTP ${res.status}`);
    return parseSpotifyEmbed(await res.text());
  }

  onProgress({ label: "Reading playlist…" });
  const bin = await ensureYtDlp(onProgress);
  const url = `https://www.youtube.com/playlist?list=${link.id}`;
  const stdout = await new Promise<string>((resolve, reject) => {
    const p = spawn(bin, ["--flat-playlist", "--print", "%(id)s|%(title)s", url],
      { windowsHide: true });
    let out = "", err = "";
    p.stdout.on("data", (b: Buffer) => { out += b.toString(); });
    p.stderr.on("data", (b: Buffer) => { err += b.toString(); });
    p.on("error", reject);
    p.on("close", code => code === 0 ? resolve(out)
      : reject(new Error(`Could not read playlist (${code}): ${err.slice(-200)}`)));
  });
  const items = parseFlatPlaylist(stdout);
  if (!items.length) throw new Error("That playlist looks empty or private");
  return items;
}
