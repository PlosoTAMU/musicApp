// Pure band-math logic gate for the visualizer's FFT bin bucketing.
import { computeBandEdges, peakPerBand } from "../src/beat";

let n = 0;
function eq(name: string, got: unknown, want: unknown) {
  n++;
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) throw new Error(`${name}: got ${g}, want ${w}`);
}
function ok(name: string, cond: boolean) {
  n++;
  if (!cond) throw new Error(`${name}: expected true`);
}

// ── computeBandEdges ─────────────────────────────────────────────────────
const edges48 = computeBandEdges(48000, 2048, 1024, 48, 40, 14_000);
eq("48-band edge count", edges48.length, 49);
ok("edges strictly non-decreasing", edges48.every((v, i) => i === 0 || v >= edges48[i - 1]));
ok("edges within analyser bin range", edges48.every(v => v >= 1 && v <= 1024));

const edges100 = computeBandEdges(48000, 2048, 1024, 100, 40, 14_000);
eq("100-band edge count", edges100.length, 101);
ok("100-band edges non-decreasing", edges100.every((v, i) => i === 0 || v >= edges100[i - 1]));

// ── peakPerBand ──────────────────────────────────────────────────────────
const freq = new Uint8Array(1024);
freq[10] = 255; // sits in an early low-frequency band
freq[500] = 128; // sits in a later band
const bands = peakPerBand(freq, edges48, 48);
eq("peakPerBand output length", bands.length, 48);
ok("band containing bin 10 picks up the peak", bands.some(v => v === 1));
ok("all values normalized 0-1", bands.every(v => v >= 0 && v <= 1));

const flatFreq = new Uint8Array(1024); // silence
const flatBands = peakPerBand(flatFreq, edges48, 48);
ok("silence yields all-zero bands", flatBands.every(v => v === 0));

console.log(`beatBins.test.ts: ${n} assertions passed`);
