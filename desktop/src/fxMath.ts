// Pure effect/crop math — Node-testable without a DOM (pattern of listOps/urls).

/** Twin of AudioPlayerManager.applyBassBoost's 5-band surgical shaping.
 *  db ∈ [−10, +20]; returns gains (dB) for
 *  [sub shelf 40 Hz, mid-bass 120 Hz, mud cut 300 Hz, presence 3 kHz, air 10 kHz].
 *  Cutting bass (db < 0) skips the compensation bands, exactly like iOS. */
export function bassGains(db: number): [number, number, number, number, number] {
  const sub = db;
  const mid = db * 0.6;
  if (db <= 0) return [sub, mid, 0, 0, 0];
  const extreme = db > 12; // iOS: past +12 dB the shaping gets more aggressive
  return [
    sub,
    mid,
    -db * (extreme ? 0.4 : 0.35),
    db * (extreme ? 0.2 : 0.15),
    db * (extreme ? 0.12 : 0.1),
  ];
}

// ── Crop window math (twin of CropSongSheet.swift) ─────────────────────────
// All values in SECONDS like iOS; ms conversion happens only at the doc write.

/** Loading clamp — iOS loadAudioDuration: keep ≥0.5 s of window inside the file. */
export function clampCrop(start: number, end: number, full: number): { start: number; end: number } {
  const s = Math.max(0, Math.min(start, full - 0.5));
  return { start: s, end: Math.max(s + 0.5, Math.min(end, full)) };
}

/** Start-slider clamp — iOS startSliderRange = 0...(end − 0.5). */
export const clampStart = (v: number, end: number): number =>
  Math.max(0, Math.min(v, end - 0.5));

/** End-slider clamp — iOS endSliderRange = (start + 0.5)...full. */
export const clampEnd = (v: number, start: number, full: number): number =>
  Math.min(full, Math.max(v, start + 0.5));

/** Twin of applyCrop's hasCrop: a near-full window means "no crop" (null). */
export function cropForSave(start: number, end: number, full: number):
    { startMs: number; endMs: number } | null {
  const hasCrop = start > 0.1 || end < full - 0.1;
  return hasCrop
    ? { startMs: Math.round(start * 1000), endMs: Math.round(end * 1000) }
    : null;
}

/** "m:ss" | "mm:ss" | raw seconds → seconds — twin of CropSongSheet.parseTime. */
export function parseTime(text: string): number | undefined {
  const t = text.trim();
  if (t.includes(":")) {
    const parts = t.split(":");
    if (parts.length !== 2) return undefined;
    const m = Number(parts[0]), s = Number(parts[1]);
    if (!Number.isInteger(m) || !Number.isInteger(s) || m < 0 || s < 0 || s >= 60)
      return undefined;
    return m * 60 + s;
  }
  const s = Number(t);
  return Number.isFinite(s) && s >= 0 && t !== "" ? s : undefined;
}

/** Seconds → "m:ss" — twin of CropSongSheet.formatTime. */
export function fmtTime(time: number): string {
  if (!Number.isFinite(time) || time < 0) return "0:00";
  const total = Math.floor(time);
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
}
