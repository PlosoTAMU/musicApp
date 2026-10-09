// Pure helpers over the users/{uid}/library doc set — Node-testable, no
// Firestore. Twin of the canonical-doc logic in LibraryReplicator.swift
// (canonicalDocId(forYT:) / tombstoneDocId(forYT:)); pinned by
// tests/audit6-sync.test.ts.
import { TrackMeta } from "./protocol";

/** `metaAt` as epoch ms — 0 when absent (legacy doc) or still a pending
 *  server timestamp (the SDK hands those back as null until committed). */
export function metaAtMs(m: TrackMeta): number {
  const t = m.metaAt as { toMillis?: () => number } | null | undefined;
  return typeof t?.toMillis === "function" ? t.toMillis() : 0;
}

/** yt → the docId that speaks for it. Several LIVE docs can carry one yt (a
 *  duplicate minted by the pre-fix upload race on either end); the most
 *  recently edited wins, ties broken by the smaller docId so both ends pick
 *  the same one. Tombstones never win: a yt with only tombstones is absent. */
export function canonicalByYt(entries: Iterable<[string, TrackMeta]>): Map<string, string> {
  const best = new Map<string, { id: string; at: number }>();
  for (const [id, m] of entries) {
    if (!m.yt || m.deleted) continue;
    const at = metaAtMs(m);
    const b = best.get(m.yt);
    if (!b || at > b.at || (at === b.at && id < b.id)) best.set(m.yt, { id, at });
  }
  const out = new Map<string, string>();
  for (const [yt, b] of best) out.set(yt, b.id);
  return out;
}

/** Live docs that lost the canonical vote — safe to delete once their crop
 *  (the only field the canonical might lack) has been merged over. Deleting
 *  (not tombstoning) matters: a tombstone is "remove the song everywhere",
 *  a removed doc is just "this record is gone". */
export function duplicateDocIds(
  entries: Iterable<[string, TrackMeta]>, canonical: Map<string, string>,
): string[] {
  const out: string[] = [];
  for (const [id, m] of entries)
    if (m.yt && !m.deleted && canonical.get(m.yt) !== id) out.push(id);
  return out;
}

/** yt → best tombstone doc to revive. This is deliberately separate from
 *  canonicalByYt because canonical excludes tombstones for every deletion /
 *  download decision. Upload-side dedupe still needs to find a deleted doc by
 *  yt so a manual re-download revives it in place instead of minting a new live
 *  doc beside the tombstone (the iOS bug fixed in LibraryReplicator.swift). */
export function tombstoneByYt(entries: Iterable<[string, TrackMeta]>): Map<string, string> {
  const best = new Map<string, { id: string; at: number }>();
  for (const [id, m] of entries) {
    if (!m.yt || !m.deleted) continue;
    const at = metaAtMs(m);
    const b = best.get(m.yt);
    if (!b || at > b.at || (at === b.at && id < b.id)) best.set(m.yt, { id, at });
  }
  const out = new Map<string, string>();
  for (const [yt, b] of best) out.set(yt, b.id);
  return out;
}
