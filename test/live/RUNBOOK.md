# Live harness runbook

Everything needed to run `cis_test` against a real server, on the Windows VPS.
Written down because all of it was discovered the hard way and none of it is
guessable.

## What this is

Six resources under `test/live/`, deployed into the server's resources folder:

| Resource | What it is |
|---|---|
| `cis_libs` | the library itself — deployed by `npm run live:deploy` |
| `cis_test_providers` | recording fakes for all eleven capability slots, and the config the harness runs under |
| `cis_test` | the orchestrator: suites, cases, console commands, results, status.json |
| `cis_test_b` | a second consumer that collides with `cis_test` on purpose |
| `cis_test_badmeta` | deliberately broken, started only by cases that need it |
| `cis_ctl` | the agent's console: reads a command file, runs allow-listed commands |

`cis_ctl` depends on nothing. That is the point: the one thing a recovery tool
must survive is `cis_libs` and the harness being in a bad state.

`_cis_libstest` is **retired**. Do not start it, do not reference it, do not
leave it running.

## Running a test

```
npm run live:run -- all
npm run live:run -- server
npm run live:run -- player
```

That is the whole thing for the agent. It deploys, drives the server through
`cis_ctl`, checks that the running build is the one it deployed, starts the
client if the tier needs one, runs, collects the results and prints a summary.
Exit 0 only when nothing FAILed.

**From now on, do not run live tests any other way.** A run assembled by hand
from console entries is a run nobody can prove tested what it claims to.

## The console: two different things

| | who | how |
|---|---|---|
| **txAdmin console** | the owner | `http://localhost:40120/server/console`, txAdmin serves it |
| **`console-bridge`** | the agent | `node tools/console-bridge.js serve`, then `send "<command>"` |
| **`cis_ctl`** | the agent | `node tools/fx.js "<command>"` |

txAdmin stays. It keeps the server up, restarts it after a crash, and it is the
owner's view. What changed is that **the agent does not type into it.**

## The console bridge (`tools/console-bridge.js`)

The txAdmin console asks for a password the agent does not have and must not
read. FXServer runs console commands off its own **stdin** with source 0, which
is the same thing the txAdmin console does — so the bridge supplies a stdin and
gives the agent that console instead.

```
node tools/console-bridge.js serve           # start the server; keep running
node tools/console-bridge.js send "refresh"  # one console command
node tools/console-bridge.js status          # bridge up? game port open?
node tools/console-bridge.js log 60          # tail the console
```

`serve` runs the owner's own `server.cfg` with `+exec` from the profile folder.
It **appends nothing to server.cfg and writes nothing into it.** It also does not
run under txAdmin: txAdmin spawns the game server as a child process and its own
stdin never reaches that child, so commands written to the txAdmin parent's
stdin are accepted and silently dropped. Running the server directly is what puts
the console where the agent can reach it.

`send` appends `[tag] <command>` to `test/live/.console/inbox.txt`; the bridge
strips the tag, writes the rest to the server's stdin, and echoes `> [tag] ...`
into `history.txt`. That echo is the acknowledgement. The tag exists so a
half-written line can never become a command.

`serve` keeps running in the background for the whole session. The ACEs below are
session-scoped, so **they and `ensure cis_ctl` have to be re-sent after every
restart**:

```
node tools/console-bridge.js send "ensure cis_ctl"
node tools/console-bridge.js send "add_ace resource.cis_ctl command.refresh allow"
...
```

What the bridge replaces is the browser path, which was: fill the input, click
it, press Enter. On the PC that cost several attempts and never worked the way it
was written down —

| Attempt | Result |
|---|---|
| Playwright `click()` on the prompt input | **times out**, every time |
| `fill()` then `press('Enter')` | text appears, never submits |
| Click the terminal **body** | types into a *different, hidden* input than the visible prompt |
| Coordinate click on the visible prompt line, then `Enter` | works, at one window size only |

A control step that only works at one window size is not a control step.
The bridge replaces it with the server's own stdin, and `cis_ctl` sits above
that with a file the server reads.

### `tools/fx.js`

```
node tools/fx.js "restart cis_test_b"
node tools/fx.js "cis_test run all"
node tools/fx.js --log 200
```

Writes `inbox.json` through a temp file and a rename, polls `outbox.json` for
**its own id**, prints the answer. Exit 1 means the command was refused; exit 2
means it was never answered (cis_ctl not started, or a timeout).

The id is what makes this safe: an id already in the inbox at startup is marked
seen and never run, so `restart cis_ctl` cannot restart itself in a loop.

`--log` prints the tail of the server log with IP addresses, `fivem:` identifiers
and licence-shaped digit runs redacted. Everything else is untouched — redacting
the diagnostics would defeat the purpose of reading the log.

### What `cis_ctl` may run

A complete allow-list, defaulting to **no**:

- `refresh`
- `ensure` / `start` / `stop` / `restart` of `cis_libs`, `cis_test`,
  `cis_test_b`, `cis_test_providers`, `cis_test_badmeta`
- `restart cis_ctl`
- `cis_test <args>`, where args are letters, digits, spaces and `_ : - .`

Everything else is refused, including `quit`, `sv_licenseKey`, `add_ace` and
`exec`. This is deliberate: an agent that can type into a console can print the
server's licence key by accident, on a box whose model provider may log what it
reads. The list is unit tested in `test/ctl-allow.lua`.

One known gap: `cis_test run server,lifecycle` is refused, because a comma is
outside the documented character set even though cis_test's own parser accepts
one. Run tiers separately — `live:run` does one per invocation anyway.

## The ACE lines

ACEs do **not** survive a server restart, so they live in `server.cfg`, not in a
console session. They are the owner's to add; the agent never edits `server.cfg`.

```
ensure cis_ctl
add_ace resource.cis_ctl command.ensure allow
add_ace resource.cis_ctl command.start allow
add_ace resource.cis_ctl command.stop allow
add_ace resource.cis_ctl command.restart allow
add_ace resource.cis_ctl command.refresh allow
add_ace resource.cis_ctl command.cis_test allow

add_ace resource.cis_test command.ensure allow
add_ace resource.cis_test command.stop allow
add_ace resource.cis_test command.start allow
add_ace resource.cis_test command.restart allow
add_ace resource.cis_test command.refresh allow
add_ace resource.cis_test command.cis_force_unregister allow
add_ace resource.cis_test command.cis_audit allow
```

Until the `cis_ctl` block is present, `cis_ctl` starts but executes nothing, and
`live:run` stops at step 2 with a message saying so. Until the `cis_test` block
is present, the lifecycle tier runs hand-driven and says so on every case.

`cis_test` also refuses `source ~= 0` from inside every handler, so a missing
ACE costs you the command, not the server.

## Where state is read from

Not console scrollback. Three files in the deployed `cis_test` folder:

| File | What it holds |
|---|---|
| `status.json` | cis_libs version, deployed commit, whether a player is connected, slot owners, the suite list |
| `results_latest.json` | the most recent run |
| `results_<runId>.json` | one file per run; the history |

`status.json` is rewritten at start, on every player join and drop, and on
`cis_test status`. The join/drop part is a change-detecting watcher rather than
only event handlers, because FiveM has no single reliable server-side "player
joined" event.

It records **whether** a player is connected and never **who**. No name, no
identifier, no IP. The same rule applies to the results files and to the log
tail.

## The client

`.live-env.json` carries a `client` block. Three modes:

| `client.mode` | what it does | when |
|---|---|---|
| `local` | `Start-Process 'fivem://connect/127.0.0.1:30120'` | the client is on the same machine, which needs a real GPU |
| `ssh` | `schtasks /run /tn CisFiveMStart` over SSH | the client is on another machine, reached over Tailscale |
| `off` | nothing; the player tier is SKIP with a reason | no client is available |

**This VPS has no GPU** (`Microsoft Remote Display Adapter`), so GTA V cannot
run on it and `local` is not available here. It is `off` until a client machine
is set up; `live:run` then reports the `player` tier as SKIP with the reason
printed. That is a correct result, not a broken one.

For `ssh` mode the remote command must stay inside **one** quoted string, and
the host key has to be saved first by connecting once by hand.

## Reading a run

```
run run-20261003-075804  commit 107ee39  players 1
  pass 12  fail 5  skip 3  manual 0  error 0  (84213 ms)

  5 failing case(s):
    [FAIL] registry :: no provider means a refusal, not a raise
        ...
```

`status` values are `PASS`, `FAIL`, `SKIP`, `MANUAL` and `ERROR`.

**SKIP is not a pass.** A tier that needs a player and finds none reports SKIP
with a reason and counts for nothing.

The console still prints one JSON object per line for a run in progress, which
is useful when watching:

```
{"ev":"run_start","run":"run-20261002-222059","commit":"unknown","tiers":["player","self","server"]}
{"ev":"case","run":"…","tier":"player","suite":"player","case":"…","status":"FAIL","ms":182,"msg":"…"}
{"ev":"run_end","run":"…","fail":1,"pass":0,"skip":0,"manual":0,"error":0,"ms":243}
```

## The player contract

**The player is a real person's session.** Snapshot before every client suite,
restore after, and verify the restore — a failed restore fails the run.

Never: drop, kick, ban, or write to the player's KVP or settings. The harness
config sets `Security.DropPlayer = false` so nothing in it *can*, and the fake
`security` provider refuses rather than acting.

### Death cases and `cis_test_allow_death`

The convar is **0** unless deliberately set otherwise, and that is the safe
default: with it at 0 the death and respawn cases **stay on the approved SKIP
list** and a run over the owner's own character cannot kill anyone.

Set it to `1` only when the client is a test account — a dedicated machine, or
the VPS's own second GTA V licence under its own Steam and Rockstar accounts.
With it at `1` the death cases **leave the approved SKIP list and run**.

`cis_test_allow_death 0` is what is in `server.cfg` here. Changing it is the
owner's call.

### Geometry

All geometry is relative to the player's **current** position. No case
hard-codes a map coordinate: the player's origin is wherever they happened to
connect, and a coordinate that is open road on one server is water on the next.

Movement freezes the ped and steps it with `SetEntityCoordsNoOffset`. Stepping
rather than teleporting matters — a teleport can cross a zone boundary between
two zone-loop passes and look like the player walked through it.

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
field it skipped is reported in the run envelope.

## What is in which tier

| Tier | Needs a player | What it covers |
|---|---|---|
| `server` | no | registry, capabilities, notify, diagnostics, self-check |
| `player` | **yes** | zones, the debug-text draw, points |
| `lifecycle` | no | resource stop and restart, ownership, cleanup |
| `perf` | no | timing against the plan's targets |
| `soak` | no | 30 minutes, memory and count drift |
| `selftest` | no | the harness failing on purpose |

`run all` excludes `selftest` on purpose: its cases are written to fail, because
a harness that has only ever been seen to pass has not been tested. Run it on
its own, where a FAIL is the correct answer.

The table is not the source of truth. `cis_test` writes the real list into
`status.json` and `live:run` reads it from there.

## Deploying

```
npm run live:deploy
```

It copies exactly the file set `fxmanifest.lua` names, and writes `deploy.json`
(commit, branch, dirty flag, timestamp) into every folder it touches, which is
what `status.json` reports as the deployed commit.

### If it refuses

The tool stops when it finds a `cis_libs` folder it did not create. FiveM scans
resource directories recursively, so two of them means the one that loads is a
coin flip, and the second folder is not the tool's to delete. Either move it out
of the resources tree, or confirm it is canonical — the next deploy then writes
a `.cis_deploy` marker into it and stops asking.

## Known open items

- **No client on this VPS.** `client.mode` is `off`, so the `player` tier is
  SKIP. Section 4.2 of `cis_libs_vps_setup.md` is the way out.
- **`cis_test_b` owns no sync record, and never could.** It is deliberately off
  `AuthorizedResources`, so every mutating export it calls is refused before any
  state exists. Any case that needs a *second owner* must use `cis_test_c`, which
  is on the list. The lifecycle suite and the `syncids` case both say so where
  they need it.
- **The lifecycle callback case answers its own await** — a fixture gap, not a
  library defect.
- **`cis_test_badmeta`'s contract-99 claim is not refused** on registration.
- **Second-player and real player-drop cases cannot be produced on this server**
  and are unit-only, on the approved SKIP list.
- **The game server runs outside txAdmin while the bridge holds it.** txAdmin is
  still installed and its settings are untouched; it just is not the parent of
  that process, so its web UI will not show it as managed. Starting the server
  from the bridge is the only way the agent can reach a console it can drive.