// ServerClock.nowMs must be an INTEGER. Server timestamps carry microseconds
// (Timestamp.toMillis() keeps nanoseconds/1e6), so the median offset is
// fractional almost every time; the JS SDK stores a non-integer number as a
// Firestore DOUBLE, and Swift's `NSNumber as? Int` refuses a double with a
// fractional part. Every desktop-written leaseMs/anchor/updatedAtMs then made
// SessionState(snap:) fail on iOS — the phone dropped the whole session doc
// and its own takeOver threw .corrupt ("started a song on the phone, desktop
// never updated"). Rounding at the single choke point every writer uses.
import { serverClock } from "../src/serverClock";

let n = 0;
function ok(name: string, cond: boolean) {
  n++;
  if (!cond) throw new Error(name);
}

// Realistic samples: server ms with microsecond fractions, local ms integers
// whose midpoint lands on .5.
const base = 1_757_100_000_000;
serverClock.ingest(base + 0.123, base - 200, base - 51);   // midpoint x.5
serverClock.ingest(base + 0.777, base - 180, base - 40);   // integer midpoint
serverClock.ingest(base + 0.456, base - 210, base - 61);   // midpoint x.5
ok("offset is fractional in this setup (the hazard is real)",
  !Number.isInteger(serverClock.offsetMs));
for (let i = 0; i < 50; i++) {
  ok(`nowMs is an integer (iteration ${i})`, Number.isInteger(serverClock.nowMs));
}
ok("nowMs still tracks Date.now() + offset within 1 ms",
  Math.abs(serverClock.nowMs - (Date.now() + serverClock.offsetMs)) <= 1);

// A very large fractional offset (device clock hours off) rounds too.
serverClock.ingest(base + 7_200_000.5, base, base + 1);
serverClock.ingest(base + 7_200_000.5, base, base + 1);
serverClock.ingest(base + 7_200_000.5, base, base + 1);
ok("large fractional offset still yields an integer", Number.isInteger(serverClock.nowMs));

console.log(`serverClock-integer: ${n} assertions passed`);
