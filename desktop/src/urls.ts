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
  return !!parsePlaylistURL(url);
}

/** A bare playlist/album link decomposed into the facts the batch downloader
 *  needs: which service, the set id, and (Spotify) album-vs-playlist. Returns
 *  undefined for anything that isn't a whole-set link. Pure — Node-testable. */
export interface PlaylistLink {
  service: "youtube" | "spotify";
  id: string;
  isAlbum: boolean;   // Spotify only — picks the embed endpoint; false for YT
}

export function parsePlaylistURL(url: string): PlaylistLink | undefined {
  let u: URL;
  try { u = new URL(url.trim()); } catch { return undefined; }
  const h = u.hostname.toLowerCase();
  if (h.includes("youtube.com") || h.includes("youtu.be")) {
    const list = u.searchParams.get("list");
    if (list && !u.searchParams.has("v")) return { service: "youtube", id: list, isAlbum: false };
    return undefined;
  }
  if (h.includes("spotify.com")) {
    const parts = u.pathname.split("/").filter(Boolean);
    if (parts.includes("track")) return undefined;
    const i = parts.findIndex(p => p === "playlist" || p === "album");
    if (i >= 0 && parts[i + 1])
      return { service: "spotify", id: parts[i + 1], isAlbum: parts[i] === "album" };
  }
  return undefined;
}
