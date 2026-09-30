# cis_libstest

Integration test harness for `cis_libs`. Exercises the real API on both realms —
including teleport-driven zone enter/exit — and writes one JSON report.

**95 tests**: 47 server, 48 client. It is a **separate FiveM resource**; it cannot
run inside `cis_libs`.

## Install

1. Copy the `cis_libstest` folder into `resources/`, as a sibling of `cis_libs`.
2. In `server.cfg`, after `cis_libs`:

```
ensure cis_libs
ensure cis_libstest
```

3. Join the server as at least one player, then run `/cistest` in the server
   console or in-game chat as an admin.

The report is written to `cis_libstest/cis-test-report-<unix timestamp>.json`.

## Commands

| Command | Scope |
|---|---|
| `cistest` | Server suite + every connected client |
| `cistest_server` | Server suite only |
| `cistest_client` | Client suite only; results still go to the server |

## Configuration

`config.lua`:

| Key | Default | Notes |
|---|---|---|
| `RunMutating` | `false` | Enables state-changing tests. **Read this warning twice** |
| `RunProbes` | `true` | Boundary measurement. Read-only and safe |
| `RunTeleport` | `true` | **Set `false` when heartbeat anti-cheat is running** |
| `TimeoutMs` | `8000` | Per-test deadline. Raise for a slow database |
| `OutputFile` | `nil` | Defaults to `cis-test-report-<timestamp>.json` |
| `RunClientTests` | `true` | Ask connected clients to participate |
| `ClientWaitMs` | `25000` | Teleport and multi-player tests are slow |
| `Verbose` | `true` | Print a line per test |

## Safety

Tests are tagged. A tag whose config switch is off is reported as `skipped`
with the reason — **a skip is not a pass.**

- **`mutating`** — changes real state: inventory items, doors, synced entities,
  database queries. **Off by default.** Enable with `RunMutating = true` only on
  a test instance.
- **`teleport`** — moves the player and holds them for seconds at a time.
  `phylax_ac` has kicked a player for exactly this. Set `RunTeleport = false`
  when it is running.
- **`probe`** — read-only. These measure boundary behaviour and are safe.

## What changed in 2.0

The harness was rebuilt. The point of most of it is that **several behaviours
were documented but never measured**, and a test that repeats an assumption is
worse than no test.

**New: boundary probes.** `probe: remote handler binding -- is
exports[res][name] unbound?` settles defect 9.3. `cis_libs`'s remote-handler
dispatch does:

```lua
local target = exports[ref.resource]
local fn = target and target[ref.export]
pcall(fn, src, ...)
```

`MEMORY.md` §1 measured the bracket **call** form as unbound. Nobody ever
measured whether the bracket **lookup** returns an unbound function or an
already-bound callable reference. The answer decides whether every remote
handler silently drops its first argument. One run settles it either way, and
the report records what actually arrived.

Also new: argument typing across the boundary, `vector3` transit, whether a
remote handler's return value survives the call, and confirmation that multiple
return values collapse to the first.

**New: Unit 0.1 regression coverage** — `CheckVersion` default, the allow-list
posture, and the database driver diagnostic. That code has never run on a
server.

**New: open defects pinned as tests.** 9.1 (`notify` realm asymmetry), 9.2
(`db.transaction` times out and returns `nil`), and the allow-list being read
once at load. Pinned, not fixed, because fixing them is a behaviour change.

**New: per-test tags** so a whole category can be switched off.

**Fixed:** the two remote-handler tests previously "fixed" by weakening the
assertion. They now assert the argument arrived in the right slot, or fail with
`the remote handler recorded nothing`.

## Report format

```json
{
  "meta": { "resource": "cis_libstest", "framework": "QBOX", "mutating": false, "...": "..." },
  "summary": {
    "total": 95, "passed": 90, "failed": 0, "skipped": 5,
    "serverTotal": 47, "serverFailed": 0, "serverSkipped": 4,
    "clientTotal": 48, "clientFailed": 0, "clientSkipped": 1,
    "clientsReporting": 1
  },
  "server": [ { "name": "...", "status": "passed|failed|skipped", "durationMs": 1,
                "message": "...", "detail": "...", "values": {} } ],
  "client": [ { "player": 5, "name": "...", "status": "...", "values": {} } ]
}
```

`values` carries the measured data per test — argument counts, entity counts,
distances, the chosen posture. When a test is inconclusive it says so in
`message` and reports `skipped`, rather than quietly passing.

## Reading a run

1. Read the `SUMMARY` console line first.
2. **If anything is `skipped`, read the reason.** A suite reporting 80 passed
   and 14 skipped has verified 80 things, not 94.
3. `detail` on a failure names the cause. `remove returned false (create=false)`
   is a different bug from `remove returned false after create returned true`.
4. `probe:` tests settle open questions. Read their `values` before writing them
   up.

## Unit tests

The harness's own pure modules — the JSON encoder, the runner's report contexts,
and the probe helpers — are covered by the main suite, which needs no FiveM
server:

```
npm test
```

**290 assertions** across three suites. If you change the encoder, the report
shape, or `isCallable`, keep those passing. `isCallable` is load-bearing: a
returned function arrives as a callable reference *table*, and a
`type() == 'function'` check rejects handlers that work.

## Automated runs

Deploying to a live server and driving it from the console is repetitive enough
to script. Three tools, all in `tools/`:

| Tool | What it does |
|---|---|
| `tools/deploy.sh` | Mirrors this working tree into the server's `resources/[standalone]/`, then verifies the deployed copy matches. Backs up first. |
| `tools/serverlog.sh` | Reads `fxserver.log` incrementally by byte offset. `mark`, then `since` gives you exactly what a command produced. |
| `tools/report.js` | Turns a JSON report into every failure and **every skip with its reason**. Exits 1 if anything failed. |

```bash
tools/deploy.sh --test-instance     # deploy + apply the test-only overlays
tools/serverlog.sh mark             # start recording
# ... send `refresh`, `ensure cis_libs`, `ensure cis_libstest`, `cistest` ...
tools/serverlog.sh since            # what those commands produced
node tools/report.js                # what they mean
```

`--test-instance` applies three changes that belong to a **test server only**,
applied after the mirror so they survive the next deploy:

- adds `cis_libstest` to `Security.AuthorizedResources`, so the mutating tier
  can run (the library's shipped default stays restrictive);
- sets `RunMutating = true`;
- sets `Framework.Type` to match the server actually running it. A qbx_core
  server with the default `QBCORE` makes cis_libs fall back to standalone mode
  and every player lookup return `nil` — which reads as a library bug and is
  not one.

Two things that will waste your time if you do not know them:

- **`restart cis_libs` also stops `cis_libstest`**, because the harness depends
  on it. Re-`ensure` it, or `cistest` answers `No such command`.
- A **parse error** in the harness still reports `Started resource
  cis_libstest`, and every later command fails with a message that points
  somewhere else. `npm run test:luacheck` catches it before you deploy.

The pure suite, which needs no server:

```bash
npm run test:all    # luacheck + 290 assertions + api self-test + api + matrix
```
