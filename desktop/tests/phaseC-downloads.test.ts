// Phase C logic gate — playlist/album download resolution (audit-2 items 10–11):
// URL routing, YouTube flat-playlist parsing, Spotify embed scraping.
import { parsePlaylistURL, isBarePlaylistURL } from "../src/urls";
import { parseFlatPlaylist, parseSpotifyEmbed, parseDlChunk } from "../src/download";

let n = 0;
function eq(name: string, got: unknown, want: unknown) {
  n++;
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) throw new Error(`${name}: got ${g}, want ${w}`);
}
function throws(name: string, fn: () => unknown) {
  n++;
  try { fn(); } catch { return; }
  throw new Error(`${name}: expected a throw`);
}

// ── parsePlaylistURL: only BARE sets, service + album flag ─────────────────
eq("YT bare playlist",
  parsePlaylistURL("https://www.youtube.com/playlist?list=PL123"),
  { service: "youtube", id: "PL123", isAlbum: false });
eq("YT watch?v=…&list=… is NOT a set (single video wins)",
  parsePlaylistURL("https://www.youtube.com/watch?v=abcdefghijk&list=PL123"), undefined);
eq("Spotify playlist",
  parsePlaylistURL("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M"),
  { service: "spotify", id: "37i9dQZF1DXcBWIGoYBM5M", isAlbum: false });
eq("Spotify album → isAlbum",
  parsePlaylistURL("https://open.spotify.com/album/1DFixLWuPkv3KT3TnV35m3"),
  { service: "spotify", id: "1DFixLWuPkv3KT3TnV35m3", isAlbum: true });
eq("Spotify track is NOT a set",
  parsePlaylistURL("https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT"), undefined);
eq("garbage → undefined", parsePlaylistURL("not a url"), undefined);
eq("isBarePlaylistURL agrees (YT set)",
  isBarePlaylistURL("https://www.youtube.com/playlist?list=PL123"), true);
eq("isBarePlaylistURL agrees (single track)",
  isBarePlaylistURL("https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT"), false);

// ── parseFlatPlaylist: id|title lines, dedupe, order, malformed skip ────────
eq("flat-playlist basic",
  parseFlatPlaylist("dQw4w9WgXcQ|Rick Astley - Never Gonna Give You Up\naaaaaaaaaaa|Song Two"),
  [
    { title: "Rick Astley - Never Gonna Give You Up", videoID: "dQw4w9WgXcQ",
      target: "https://www.youtube.com/watch?v=dQw4w9WgXcQ" },
    { title: "Song Two", videoID: "aaaaaaaaaaa",
      target: "https://www.youtube.com/watch?v=aaaaaaaaaaa" },
  ]);
eq("flat-playlist dedupes + drops malformed lines",
  parseFlatPlaylist("bbbbbbbbbbb|One\ngarbage line\nbbbbbbbbbbb|One again\nshort|x")
    .map(i => i.videoID),
  ["bbbbbbbbbbb"]);
eq("flat-playlist empty → []", parseFlatPlaylist(""), []);
eq("flat-playlist title falls back to id",
  parseFlatPlaylist("ccccccccccc|").map(i => i.title), ["ccccccccccc"]);

// ── parseSpotifyEmbed: __NEXT_DATA__ trackList → ytsearch targets ──────────
const embedHtml = (tracks: unknown) =>
  `<html><body><script id="__NEXT_DATA__" type="application/json">${
    JSON.stringify({ props: { pageProps: { state: { data: { entity: { trackList: tracks } } } } } })
  }</script></body></html>`;

eq("spotify embed → display + ytsearch target",
  parseSpotifyEmbed(embedHtml([
    { uri: "spotify:track:aaa", title: "Song A", subtitle: "Artist A" },
    { uri: "spotify:track:bbb", title: "Song B", subtitle: "" },
  ])),
  [
    { title: "Artist A - Song A", target: "ytsearch1:Artist A - Song A" },
    { title: "Song B", target: "ytsearch1:Song B" },
  ]);
eq("spotify embed dedupes by track id",
  parseSpotifyEmbed(embedHtml([
    { uri: "spotify:track:dup", title: "X", subtitle: "A" },
    { uri: "spotify:track:dup", title: "X", subtitle: "A" },
  ])).length, 1);
eq("spotify embed skips non-track uris",
  parseSpotifyEmbed(embedHtml([
    { uri: "spotify:episode:zzz", title: "Pod", subtitle: "Show" },
    { uri: "spotify:track:ttt", title: "Real", subtitle: "Band" },
  ])).map(i => i.title), ["Band - Real"]);
throws("spotify embed with no __NEXT_DATA__ throws", () => parseSpotifyEmbed("<html></html>"));
throws("spotify embed with empty trackList throws", () => parseSpotifyEmbed(embedHtml([])));

// ── parseDlChunk still extracts percent (regression) ───────────────────────
eq("parseDlChunk last percent wins",
  parseDlChunk("[download]  10.0%\r[download]  42.5%").pct, 43);

console.log(`phaseC-downloads: ${n}/${n} PASS`);
