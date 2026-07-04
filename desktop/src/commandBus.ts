// Twin of Sync/CommandBus.swift — follower→owner control channel.
// Single-writer invariant: followers never touch `playback`; commands round-trip
// through the owner as fenced publishes.
import {
  Firestore, DocumentReference, collection, addDoc, onSnapshot, query, orderBy,
  serverTimestamp, deleteDoc, Timestamp, Unsubscribe,
} from "firebase/firestore";
import { DEVICE_ID } from "./protocol";
import { serverClock } from "./serverClock";

export type Command =
  | { t: "play" } | { t: "pause" } | { t: "next" } | { t: "prev" }
  | { t: "seek"; ms: number };

const STALE_MS = 30_000;

export class CommandBus {
  private unsub?: Unsubscribe;

  constructor(
    private db: Firestore,
    private ref: () => DocumentReference | undefined,
  ) {}

  send(cmd: Command) {
    const ref = this.ref();
    if (ref) void addDoc(collection(ref, "commands"),
      { ...cmd, by: DEVICE_ID, at: serverTimestamp() });
  }

  /** Owner-side. Applies fresh commands in server order; deletes every doc. */
  start(handler: (cmd: Command) => void) {
    this.stop();
    const ref = this.ref();
    if (!ref) return;
    this.unsub = onSnapshot(query(collection(ref, "commands"), orderBy("at")), snap => {
      for (const change of snap.docChanges()) {
        if (change.type !== "added") continue;
        const d = change.doc.data();
        const at = d.at as Timestamp | null;                 // null until server-acked
        const ageMs = at ? serverClock.nowMs - at.toMillis() : 0;
        if (ageMs < STALE_MS && d.by !== DEVICE_ID) handler(d as Command);
        void deleteDoc(change.doc.ref);
      }
    });
  }

  stop() { this.unsub?.(); this.unsub = undefined; }
}
