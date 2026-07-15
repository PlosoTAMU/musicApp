// Pure list-reorder / shuffle / format helpers, split out of ui.ts so they are
// Node-testable without a DOM (mirrors the urls.ts pattern). No external imports.

/** Fisher-Yates copy — leaves the input untouched. Twin of iOS makeTracks(shuffle:). */
export function shuffle<T>(a: T[]): T[] {
  const b = [...a];
  for (let i = b.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [b[i], b[j]] = [b[j], b[i]];
  }
  return b;
}

/** m:ss, or h:mm:ss once past an hour. */
export function fmtDuration(sec: number): string {
  const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = Math.floor(sec % 60);
  return h > 0
    ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`
    : `${m}:${String(s).padStart(2, "0")}`;
}

/** Drag-to-reorder: move the item at `from` so it lands where the ORIGINAL item
 *  at `to` sat (i.e. just before it, or after it when dragging downward). Returns
 *  a fresh array; out-of-range or equal indices are returned unchanged. The
 *  drag source and drop target indices are resolved by the caller. */
export function moveIndex<T>(list: T[], from: number, to: number): T[] {
  if (from < 0 || to < 0 || from >= list.length || to >= list.length || from === to) {
    return list;
  }
  const out = [...list];
  const [item] = out.splice(from, 1);
  const dest = from < to ? to - 1 : to;   // removal shifted the target up
  out.splice(dest, 0, item);
  return out;
}

/** Case-insensitive name sort — twin of the iOS library ordering (desktop
 *  previously showed raw dir-walk order). */
export const byName = <T extends { name: string }>(a: T, b: T): number =>
  a.name.localeCompare(b.name, undefined, { sensitivity: "base" });
