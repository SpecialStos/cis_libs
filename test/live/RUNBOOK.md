# Live harness runbook

Everything needed to run `cis_test` against a real server, written down because
all of it was discovered the hard way and none of it is guessable.

## What this is

Four resources under `test/live/`, deployed to the server's resources folder:

| Resource | What it is |
|---|---|
| `cis_libs` | the library itself — deployed by `npm run live:deploy` |
| `cis_test_providers` | recording fakes for all eleven capability slots, and the config the harness runs under |
| `cis_test` | the orchestrator: suites, cases, console commands, results |
| `cis_test_b` | a second consumer that collides with `cis_test` on purpose |
| `cis_test_badmeta` | deliberately broken, started only by cases that need it |

`_cis_libstest` is **retired**. Do not start it, do not reference it, do not
leave it running.

## One-time setup

The harness reads `.live-env.json` for `resourcesDir`, the console URL and the
log path. It holds no passwords, no keys and no identifiers.

## Deploying

```
npm run live:deploy
```

It copies exactly the file set `fxmanifest.lua` names — never a hand-maintained
list, which is the thing that goes stale — and writes `deploy.json` (commit,
branch, dirty flag, timestamp) into every folder it touches so
`cis_test status` can prove what is running.

**It prints the console sequence; it does not run it.** Deploying a resource and
starting it are separate decisions, and starting needs `refresh` to have
happened first.

### If it refuses

The tool stops when it finds a `cis_libs` folder it did not create. FiveM scans
resource directories recursively, so two of them means the one that loads is a
coin flip, and the second folder is not the tool's to delete. This is expected
the first time: a `cis_libs` deployed by hand, as the first one here was. Either
move that folder out of the resources tree, or confirm it is canonical — the
next deploy then writes a `.cis_deploy` marker into it and stops asking.

## The session ACEs

ACEs do not survive a server restart. Once per session, in the console:

```
add_ace resource.cis_test command.ensure allow
add_ace resource.cis_test command.stop allow
add_ace resource.cis_test command.start allow
add_ace resource.cis_test command.restart allow
add_ace resource.cis_test command.refresh allow
add_ace resource.cis_test command.cis_force_unregister allow
add_ace resource.cis_test command.cis_audit allow
```

Every `cis_test` command also refuses `source ~= 0` from inside the handler, so
a missing ACE costs you the command, not the server.

## The console, and its quirks

The console is at the `txConsoleUrl` in `.live-env.json`.

**Read results from the console pane or from the results file — never by tailing
the server log.** On this server the log is flooded with a repeating
`Server list query returned an error` line, which drowns anything a command
prints.

**Under browser automation the prompt does not behave.** The plan says "fill the
input, click it, then press Enter". What actually works:

| Attempt | Result |
|---|---|
| Playwright `click()` on the prompt input | **times out**, every time |
| `fill()` then `press('Enter')` | text appears, never submits |
| Click the terminal **body** | types into a *different, hidden* input than the visible prompt |
| Coordinate click on the visible prompt line, then `Enter` | **works** |

The working sequence, in full: click the visible prompt line by coordinate, then
press Enter. This is not cosmetic — it is the difference between a harness that
runs and one that silently sends nothing, which is the failure this repository
has been bitten by before.

## Running

```
cis_test status              version, deployed commit, players, slot owners, self-check
cis_test list [tier]         what is registered
cis_test run all             every tier except the self-test
cis_test run <tier|suite>    one tier or one suite
cis_test run selftest        the harness testing ITSELF: this is meant to FAIL
cis_test abort               stop after the current suite; cleanups still run
cis_test restore             release every slot; the player is NOT touched
```

`run all` deliberately **excludes** the `selftest` tier. Its cases are written to
fail, because a harness that has only ever been seen to pass has not been
tested. A permanently red command is one everybody stops reading, so the
self-test is run on its own, where a FAIL is the correct answer.

## Reading a run

One JSON object per console line, prefixed `[cis_test] `:

```
{"ev":"run_start","run":"run-20261002-222059","commit":"unknown","tiers":["player","self","server"]}
{"ev":"case","run":"…","tier":"player","suite":"player","case":"…","status":"FAIL","ms":182,"msg":"…"}
{"ev":"run_end","run":"…","fail":1,"pass":0,"skip":0,"manual":0,"error":0,"ms":243}
```

Two files land in the `cis_test` folder: `results_<runId>.json` and
`results_latest.json`. Both hold the same body, written whole — never appended —
so a run that dies half way leaves a complete file or none.

`status` values are `PASS`, `FAIL`, `SKIP`, `MANUAL` and `ERROR`. **SKIP is not
pass**: a tier that needs a player and finds none reports SKIP with a reason and
counts for nothing.

## The player contract

**The player is a real person's session.** Snapshot before every client suite,
restore after, and verify the restore — a failed restore fails the run.

Never: drop, kick, ban, or write to the player's KVP or settings. The harness
config sets `Security.DropPlayer = false` so nothing in it *can*, and the fake
`security` provider refuses rather than acting.

All geometry is relative to the player's **current position**. No case
hard-codes a map coordinate: the player's origin is wherever they happened to
connect, and a coordinate that is open road on one server is water on the next.

Movement freezes the ped and steps it with `SetEntityCoordsNoOffset`. Stepping
rather than teleporting matters — a teleport can cross a zone boundary between
two zone-loop passes and look like the player walked through it.

Death and respawn run only when the convar `cis_test_allow_death` is `1`, which
defaults to `0`.

### Which fields the client could actually read

Not every native exists on the client. Checked against FiveM's own native
database, which carries an `apiset` per native:

- **not in the database at all** — client availability not guaranteed:
  `GET_ENTITY_INVINCIBLE`, `GET_ENTITY_COLLISION_ENABLED`, `SET_ENTITY_INVINCIBLE`,
  `SET_ENTITY_COLLISION`, `SET_ENTITY_VISIBLE`, `SET_ENTITY_HEALTH`,
  `SET_ENTITY_COORDS_NO_OFFSET`, `GET_PED_WEAPONTYPE_INDEX`, `GET_PED_AMMO`,
  `SET_PED_AMMO`
- **apiset `server`** — the documented surface, not the client's:
  `GET_ENTITY_HEALTH`, `GET_PED_ARMOUR`, `GET_VEHICLE_PED_IS_IN`,
  `GET_PED_IN_VEHICLE_SEAT`, `FREEZE_ENTITY_POSITION`, and the routing-bucket family

The harness reads a field only when the native exists on the client, and every
field it skipped is reported in the run envelope. An unread field is safe only
if no case can touch it either — which is what the report is for.

## What is in which tier

| Tier | Needs a player | What it covers |
|---|---|---|
| `server` | no | registry, capabilities, notify, diagnostics, self-check |
| `player` | **yes** | zones, the debug-text draw, points |
| `lifecycle` | no | resource stop and restart, ownership, cleanup |
| `perf` | no | timing against the plan's targets |
| `soak` | no | 30 minutes, memory and count drift |
| `selftest` | no | the harness failing on purpose |

## Known open items

- **`cis_test_b` is deployed but no suite drives it yet.** The lifecycle tier
  (2.6) starts and stops it to prove ownership and cleanup.
- **`cis_test_badmeta` is deployed but no suite starts it yet.** Same.
- **`GetZoneDebug` and `DrawText3D`** are called by the player tier and are
  expected to fail — they are the two undefined natives found in Stage 1, and the
  cases stay red until those are fixed.
- **Second-player and real player-drop cases cannot be produced on this server**
  and are unit-only, on the approved SKIP list.