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
import { isBarePlaylistURL } from "./urls";

export interface DownloadProgress {
  label: string; // human status line: "Downloading… 42%"
}

const PROGRESS_RE = /\[download\]\s+([\d.]+)%/;
const ITEM_RE = /\[download\] Downloading item (\d+) of (\d+)/;

/** Pull percent / playlist-position facts out of a yt-dlp stdout chunk.
 *  Pure — Node-tested. Last match in the chunk wins (yt-dlp rewrites the
 *  progress line with \r). */
export function parseDlChunk(chunk: string): { pct?: number; item?: number; total?: number } {
  const out: { pct?: number; item?: number; total?: number } = {};
  for (const line of chunk.split(/\r?\n|\r/)) {
    const m = PROGRESS_RE.exec(line);
    if (m) out.pct = Math.round(parseFloat(m[1]));
    const it = ITEM_RE.exec(line);
    if (it) { out.item = parseInt(it[1], 10); out.total = parseInt(it[2], 10); }
  }
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

/** Downloads one track — or a whole set for a BARE playlist/album link
 *  (twin of iOS downloadPlaylist detection) — into `dir`, auto-fetching
 *  yt-dlp itself on first run if it's not already installed. */
export async function downloadTrack(
  url: string, dir: string, onProgress: (p: DownloadProgress) => void,
): Promise<void> {
  // Spotify sets can't ride the oEmbed→ytsearch1 trick — it resolves ONE
  // title (the playlist's name), which would fetch garbage. Point at the
  // YouTube equivalent instead of silently downloading the wrong thing.
  const wholeSet = isBarePlaylistURL(url);
  if (wholeSet && /open\.spotify\.com/.test(url)) {
    throw new Error(
      "Spotify playlist/album links aren't supported here yet — paste a YouTube playlist link");
  }

  const [target, bin] = await Promise.all([
    /open\.spotify\.com/.test(url) ? spotifyToSearch(url) : Promise.resolve(url),
    ensureYtDlp(onProgress),
  ]);

  const args = [
    // Quality over space on desktop (iOS deliberately keeps 128 kbps m4a for
    // space): plain bestaudio picks the highest-abr stream YouTube serves,
    // typically ~160 kbps VBR Opus in webm — Chromium + the scanner already
    // handle opus/webm natively.
    "-f", "bestaudio",
    wholeSet ? "--yes-playlist" : "--no-playlist",
    "-o", path.join(dir, "%(title)s [%(id)s].%(ext)s"),
    target,
  ];

  await new Promise<void>((resolve, reject) => {
    const p = spawn(bin, args, { windowsHide: true });

    let item = 0, total = 0;
    p.stdout.on("data", (b: Buffer) => {
      const f = parseDlChunk(b.toString());
      if (f.item) { item = f.item; total = f.total ?? total; }
      if (f.pct !== undefined) {
        onProgress({ label: total > 1
          ? `Track ${item}/${total} — ${f.pct}%`
          : `Downloading… ${f.pct}%` });
      }
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
