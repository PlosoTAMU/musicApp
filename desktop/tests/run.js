// Logic-test runner (Node, no DOM): bundles each tests/*.test.ts with esbuild
// so the pure src modules resolve, then runs them in-process. localStorage is
// stubbed for protocol.ts's DEVICE_ID; firebase stays external (installed).
// Usage: npm run test:logic — exits 1 on any failure.
const { buildSync } = require("esbuild");
const fs = require("fs");
const path = require("path");

const outDir = path.join(__dirname, "..", "dist", "tests");
const entries = fs.readdirSync(__dirname).filter(f => f.endsWith(".test.ts"));

buildSync({
  entryPoints: entries.map(e => path.join(__dirname, e)),
  bundle: true,
  platform: "node",
  external: ["firebase/firestore"],
  outdir: outDir,
  banner: { js: "globalThis.localStorage={getItem:()=>null,setItem:()=>{}};" },
});

let failed = false;
for (const e of entries) {
  try { require(path.join(outDir, e.replace(/\.ts$/, ".js"))); }
  catch (err) { console.error(`FAIL ${e}:`, err.message ?? err); failed = true; }
}
process.exit(failed ? 1 : 0);
