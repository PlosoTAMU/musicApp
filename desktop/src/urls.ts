// Pure URL helpers — no DOM / electron deps, so they're Node-unit-testable.
// Twin of the id extraction in iOS ContentView.extractVideoID / YouTubeDownloadView.

/** YouTube video id from a pasted URL: watch?v=, youtu.be/, embed/, shorts/.
 *  Returns undefined for non-YouTube or unparseable input. */
export function extractYtId(url: string): string | undefined {
  let u: URL;
  try { u = new URL(url.trim()); } catch { return undefined; }
  const h = u.hostname.toLowerCase();
  if (h.includes("youtu.be")) return u.pathname.split("/").filter(Boolean)[0] || undefined;
  if (h.includes("youtube.com")) {
    const v = u.searchParams.get("v");
    if (v) return v;
    const parts = u.pathname.split("/").filter(Boolean);
    const i = parts.findIndex(p => p === "embed" || p === "shorts");
    if (i >= 0 && parts[i + 1]) return parts[i + 1];
  }
  return undefined;
}

/** True only for a BARE playlist/album link (no specific video/track) — the
 *  case where a whole-set download is intended. Twin of iOS isBarePlaylistURL. */
export function isBarePlaylistURL(url: string): boolean {
  let u: URL;
  try { u = new URL(url.trim()); } catch { return false; }
  const h = u.hostname.toLowerCase();
  if (h.includes("youtube.com") || h.includes("youtu.be")) {
    const hasVideo = u.searchParams.has("v");
    const hasList = u.searchParams.has("list");
    return hasList && !hasVideo;
  }
  if (h.includes("spotify.com")) {
    const parts = u.pathname.split("/").filter(Boolean);
    const isTrack = parts.includes("track");
    const isList = parts.includes("playlist") || parts.includes("album");
    return isList && !isTrack;
  }
  return false;
}
