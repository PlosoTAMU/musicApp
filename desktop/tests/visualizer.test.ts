// Pure color-quantization logic gate for the edge visualizer's art-color sampling.
import { extractDominantColors } from "../src/visualizer";

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

// Build a 4x4 RGBA buffer: half mid-gray-blue, half mid-gray-red.
function makeImage(w: number, h: number, fill: (x: number, y: number) => [number, number, number]) {
  const data = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const [r, g, b] = fill(x, y);
      const i = (y * w + x) * 4;
      data[i] = r; data[i + 1] = g; data[i + 2] = b; data[i + 3] = 255;
    }
  }
  return data;
}

const twoTone = makeImage(4, 4, (x) => (x < 2 ? [80, 90, 180] : [180, 90, 80]));
const colors = extractDominantColors(twoTone, 4, 4);
ok("returns at least one color", colors.length >= 1);
ok("all entries are 'r,g,b' strings", colors.every(c => /^\d+,\d+,\d+$/.test(c)));

// All-black image: every pixel fails the brightness>0.2 filter → fallback color.
const black = makeImage(2, 2, () => [0, 0, 0]);
eq("all-dark image falls back to theme red", extractDominantColors(black, 2, 2), ["241,43,38"]);

// All-white image: every pixel fails the brightness<0.9 filter → fallback color.
const white = makeImage(2, 2, () => [255, 255, 255]);
eq("all-bright image falls back to theme red", extractDominantColors(white, 2, 2), ["241,43,38"]);

console.log(`visualizer.test.ts: ${n} assertions passed`);
