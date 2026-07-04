// Desktop-side ingest — yt-dlp wrapper. Full parity with the phone: paste a
// YouTube or Spotify link, the file lands in the music dir named
// "<title> [<videoId>].<ext>" (the scanner's yt-tag convention, so identity
// resolution and cloud replication pick it up with zero extra plumbing).
//
// Spotify links resolve via the public oEmbed title → yt-dlp "ytsearch1:" —
// the same strategy the iOS pipeline uses. No ffmpeg dependency: bestaudio in
// its native container (m4a/webm/opus), all of which the scanner + Chromium
// already handle.
import { spawn } from "child_process";
import * as path from "path";

export interface DownloadProgress {
  label: string; // human status line: "Downloading… 42%"
}

const PROGRESS_RE = /\[download\]\s+([\d.]+)%/;

async function spotifyToSearch(url: string): Promise<string> {
  const res = await fetch(
    `https://open.spotify.com/oembed?url=${encodeURIComponent(url)}`);
  if (!res.ok) throw new Error("Spotify lookup failed");
  const title = ((await res.json()) as { title?: string }).title;
  if (!title) throw new Error("Spotify lookup returned no title");
  return `ytsearch1:${title}`;
}

/** Downloads one track into `dir`. Rejects with a readable message when
 *  yt-dlp is missing so the UI can say so instead of failing silently. */
export async function downloadTrack(
  url: string, dir: string, onProgress: (p: DownloadProgress) => void,
): Promise<void> {
  const target = /open\.spotify\.com/.test(url) ? await spotifyToSearch(url) : url;

  const args = [
    "-f", "bestaudio[ext=m4a]/bestaudio",
    "--no-playlist",
    "-o", path.join(dir, "%(title)s [%(id)s].%(ext)s"),
    target,
  ];

  await new Promise<void>((resolve, reject) => {
    const p = spawn("yt-dlp", args, { windowsHide: true });

    p.stdout.on("data", (b: Buffer) => {
      const m = PROGRESS_RE.exec(b.toString());
      if (m) onProgress({ label: `Downloading… ${Math.round(parseFloat(m[1]))}%` });
    });

    let stderr = "";
    p.stderr.on("data", (b: Buffer) => { stderr += b.toString(); });

    p.on("error", (e: NodeJS.ErrnoException) => {
      reject(e.code === "ENOENT"
        ? new Error("yt-dlp not found — install it and add it to PATH")
        : e);
    });
    p.on("close", code => {
      if (code === 0) resolve();
      else reject(new Error(`yt-dlp failed (${code}): ${stderr.slice(-200)}`));
    });
  });
}
