// Two-way effects-settings sync — twin of musicApp/Sync/SettingsSync.swift.
// Doc: users/{uid}/sync/settings (singleton, same doc family as session).
//   { speed, bassDb, reverbPct, pitchSt?, bypass?, updatedBy, at }
// LWW is Firestore's own snapshot ordering, same as the session/playlist
// docs — `at` (ServerClock ms) is carried for parity/debugging, not compared
// client-side. `updatedBy` filters same-device echo.
//
// What the doc means: "the effects currently AUDIBLE on the owning device".
// Any device may write it (a remote's slider drag is a live control of the
// owner); the owner also writes it whenever its audible values change for
// any other reason (per-track memory restore on a track change, reset).
import { Firestore, doc, setDoc, onSnapshot, Unsubscribe } from "firebase/firestore";
import { DEVICE_ID } from "./protocol";
import { serverClock } from "./serverClock";

export interface SettingsDoc {
  speed: number;     // playback rate multiplier
  bassDb: number;     // raw dB, same units both apps
  reverbPct: number;  // 0-100 — desktop's internal fx.reverb is a 0-1 fraction
  // Pitch shift in semitones, ±12, 0.5 st steps on both UIs. OPTIONAL on the
  // wire: absent means "written by a client from before pitch synced", read
  // as 0. Pitch was the one effect that never left the device it was set on
  // ("reverb, pitch and bass don't sync") — the iOS side simply never
  // published it and this side had it marked local-only.
  pitchSt?: number;
  // Effects master switch (iOS effectsBypass / desktop fx.bypass). Without it
  // a device with effects OFF still published its stored slider values, and a
  // device with effects ON applied them audibly — and they contradicted
  // PlaybackState.rate, which IS bypass-adjusted (sync-audit-4 M10).
  // OPTIONAL on the wire: absent means "an old client wrote this", and the
  // safe reading of a doc from a client that had no concept of bypass is
  // "not bypassed", which is exactly how those values were being applied.
  bypass?: boolean;
}

/** Wire ranges, shared with iOS (AudioSettingsSheet sliders). */
export const SETTINGS_RANGE = {
  speed: [0.5, 2.0], bassDb: [-10, 20], reverbPct: [0, 100], pitchSt: [-12, 12],
} as const;

const clamp = (v: number, [lo, hi]: readonly [number, number]) => Math.min(Math.max(v, lo), hi);

/** Parse + clamp a raw settings doc. Undefined when the doc is unusable
 *  (missing a required field, or this device's own echo). Pure — pinned by
 *  tests/settingsDoc.test.ts, and the single place the optional fields'
 *  defaults live. */
export function parseSettingsDoc(
  d: Record<string, unknown> | undefined, selfId: string = DEVICE_ID,
): Required<SettingsDoc> | undefined {
  if (!d || d.updatedBy === selfId) return undefined;
  if (typeof d.speed !== "number" || typeof d.bassDb !== "number"
      || typeof d.reverbPct !== "number") return undefined;
  return {
    speed: clamp(d.speed, SETTINGS_RANGE.speed),
    bassDb: clamp(d.bassDb, SETTINGS_RANGE.bassDb),
    reverbPct: clamp(d.reverbPct, SETTINGS_RANGE.reverbPct),
    pitchSt: typeof d.pitchSt === "number" ? clamp(d.pitchSt, SETTINGS_RANGE.pitchSt) : 0,
    bypass: typeof d.bypass === "boolean" ? d.bypass : false,
  };
}

export class SettingsSync {
  onRemote?: (s: Required<SettingsDoc>) => void;

  private unsub?: Unsubscribe;
  private uid = "";

  constructor(private db: Firestore) {}

  start(uid: string) {
    this.stop();
    this.uid = uid;
    this.unsub = onSnapshot(this.ref(), snap => {
      const s = parseSettingsDoc(snap.data());
      if (s) this.onRemote?.(s);
    });
  }

  stop() {
    this.unsub?.(); this.unsub = undefined;
    this.uid = "";
  }

  push(s: SettingsDoc) {
    if (!this.uid) return;
    void setDoc(this.ref(), { ...s, updatedBy: DEVICE_ID, at: serverClock.nowMs })
      .catch(() => {});
  }

  private ref() {
    return doc(this.db, "users", this.uid, "sync", "settings");
  }
}
