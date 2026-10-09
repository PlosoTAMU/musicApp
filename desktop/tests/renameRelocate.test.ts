// Rename refresh gate: after a rescan, a held track (now playing, history)
// must re-point at its renamed file so Now Playing shows the new name.
import { relocate, LocalTrack } from "../src/player";

let n = 0;
function ok(name: string, cond: boolean) { n++; if (!cond) throw new Error(`${name}: expected true`); }

const tr = (id: string, name: string, p: string, yt?: string): LocalTrack =>
  ({ id, name, folder: "Music", path: p, ...(yt ? { yt } : {}) });

const old = tr("A", "Old Name", "C:\\m\\Old Name.mp3");
const oldYt = tr("B", "Old Tagged", "C:\\m\\Old Tagged [abcdefghijk].m4a", "abcdefghijk");
const lib = [
  tr("A2", "New Name", "C:\\m\\New Name.mp3"),
  tr("B2", "New Tagged", "C:\\m\\New Tagged [abcdefghijk].m4a", "abcdefghijk"),
  tr("C", "Same", "C:\\m\\Same.mp3"),
];

ok("unchanged path keeps entry", relocate(tr("C", "Same", "C:\\m\\Same.mp3"), lib)?.id === "C");
ok("local rename via moved map", relocate(old, lib, new Map([[old.path, "C:\\m\\New Name.mp3"]]))?.name === "New Name");
ok("untagged rename without map is lost", relocate(old, lib) === undefined);
ok("tagged rename (sync / explorer) via yt", relocate(oldYt, lib)?.name === "New Tagged");
ok("deleted file → undefined", relocate(tr("Z", "Gone", "C:\\m\\Gone.mp3"), lib) === undefined);

console.log(`renameRelocate: ${n} assertions passed`);
