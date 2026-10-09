// Effects-settings wire contract (twin of SettingsSync.swift's applyRemote):
// optional fields' defaults, clamping to the shared slider ranges, and the
// same-device echo filter. `pitchSt` joined the doc when pitch started
// syncing; a doc from an older client has no such field and must read as 0,
// not be rejected.
import { parseSettingsDoc, SETTINGS_RANGE } from "../src/settingsSync";

let n = 0;
function eq(name: string, got: unknown, want: unknown) {
  n++;
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) throw new Error(`${name}: got ${g}, want ${w}`);
}

const ME = "ME", OTHER = "OTHER";
const base = { speed: 1.5, bassDb: 6, reverbPct: 40, updatedBy: OTHER, at: 1 };

eq("full doc parses; pitch + bypass carried",
  parseSettingsDoc({ ...base, pitchSt: -3.5, bypass: true }, ME),
  { speed: 1.5, bassDb: 6, reverbPct: 40, pitchSt: -3.5, bypass: true });

eq("pre-pitch client: pitchSt absent reads as 0, doc still accepted",
  parseSettingsDoc(base, ME)?.pitchSt, 0);
eq("pre-M10 client: bypass absent reads as false (values were applied as active)",
  parseSettingsDoc(base, ME)?.bypass, false);

eq("own echo is dropped", parseSettingsDoc({ ...base, updatedBy: ME }, ME), undefined);
eq("missing doc is dropped", parseSettingsDoc(undefined, ME), undefined);
eq("missing required field is dropped",
  parseSettingsDoc({ speed: 1, bassDb: 0, updatedBy: OTHER }, ME), undefined);

const wild = parseSettingsDoc(
  { speed: 9, bassDb: -50, reverbPct: 250, pitchSt: 40, updatedBy: OTHER }, ME)!;
eq("speed clamped", wild.speed, SETTINGS_RANGE.speed[1]);
eq("bass clamped", wild.bassDb, SETTINGS_RANGE.bassDb[0]);
eq("reverb clamped", wild.reverbPct, SETTINGS_RANGE.reverbPct[1]);
eq("pitch clamped", wild.pitchSt, SETTINGS_RANGE.pitchSt[1]);

eq("non-number pitch reads as 0 rather than poisoning the doc",
  parseSettingsDoc({ ...base, pitchSt: "3" }, ME)?.pitchSt, 0);

console.log(`settingsDoc: ${n}/${n} PASS`);
