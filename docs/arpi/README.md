# ARPI process — desktop parity effort

This directory holds the working artifacts for bringing the **desktop** app to
parity with the **iOS** app, run under the **ARPI operating protocol**. It exists
so the work is legible to a reviewer and resumable by a fresh session.

## What ARPI is

ARPI = **Assess → Research → Plan → Implement**, applied to every nontrivial task.
It is a methodology, not a domain tool. The rules that shape this effort:

1. **ARPI everything** — never skip a phase silently; scale depth to the problem.
2. **Correctness over speed** — a slow right answer beats a fast wrong one.
3. **Ask on genuine forks** — one sharp question before building beats a wrong guess.
4. **Skills before code** — read relevant skills first.
5. **Continuity via NOTES.md** — externalize state so any session can resume cold.
6. **Verify before delivering** — run the app on the changed flow; no victory laps.
7. **Failure protocol** — 2 failed fixes → stop + write; 3rd attempt differs in kind; 3 dead hypotheses → escalate with a map.

## How this effort is organized

| File | Role |
|------|------|
| `../../NOTES.md` | **State file** (repo root). Goal, decisions, assumptions, done, open, ruled-out. Read first on resume. |
| `desktop-parity-findings.md` | **Assess output.** The full iOS↔desktop audit: every parity gap + usability issue, with file:line evidence. |
| `desktop-parity-plan.md` | **Plan output.** Phased implementation plan, in strict priority order, with per-phase verification. |
| `README.md` | This file — the process explainer. |

## How the phases were traced (Assess + Research)

- Read the entire iOS feature surface: all Swift views + the two managers
  (`AudioPlayerManager`, `DownloadManager`) at API level.
- Read the entire desktop app: `main.js`, `index.html`, and all `src/*.ts`.
- Cross-referenced the two into a parity matrix; captured usability gaps from the
  desktop UI + the committed screenshots.
- Confirmed two load-bearing facts before planning: (a) the engine command-bus
  already supports follower→owner control, so "full remote" is UI-only work; and
  (b) `beat.ts` already runs a Web Audio graph on the player element, so the P4
  rebuild consolidates rather than duplicates.

## Two decisions the user made at the ARPI question gate (2026-07-14)

1. **Scope** = *everything, strict priority order* — including the Web Audio
   rebuild required for real pitch-shift and the crop editor.
2. **Remote control** = *full remote* — the desktop becomes a true touch/mouse
   remote of the phone (unblur the rail, wire mirror transport), matching iOS.

Both are recorded in `NOTES.md` under DECISIONS.

## Working rules for this effort

- **iOS is the reference.** The README calls desktop the "twin"; when behavior
  differs, desktop changes to match iOS unless there's a platform reason not to.
- **Do not change Firestore wire field names.** They are the cross-platform
  contract (see the header of `musicApp/Sync/SettingsSync.swift`). Parity work
  changes clients, never the schema, unless both sides change together.
- **One reviewable increment per phase.** Each phase is a coherent, pushable unit
  so progress can be pushed and reviewed without waiting for all 30 items.
- **Verify by running the app**, not just by reading the diff.
