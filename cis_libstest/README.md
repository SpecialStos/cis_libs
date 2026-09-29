# cis_libstest

Integration test harness for `cis_libs`. Exercises the API on client and
server and writes a single JSON report into this resource's folder.

This is a **separate FiveM resource**. It cannot run inside `cis_libs`.

## Install

1. Copy the `cis_libstest` folder into your server's `resources/` directory, as
   a sibling of `cis_libs`.
2. In `server.cfg`, **after** `cis_libs`:

```
ensure cis_libs
ensure cis_libstest
```

If you keep it inside the `cis_libs` repository, copy the folder out rather than
nesting it — a resource directory cannot live inside another resource.

## Run

| Command | Scope |
|---|---|
| `cistest` (console) | Server suite + every connected client |
| `cistest` (in game, admin) | Same |
| `cistest_server` | Server suite only |
| `cistest_client` (in game) | Client suite only, reports straight to the server |

The report is written to
`cis_libstest/cis-test-report-<unix-timestamp>.json`.

## Safety

Some tests change real state: they add and remove inventory items, register
doors, spawn synced entities, and would write database rows. **These are
skipped by default.** You will see them reported as `skipped`, not `failed`.

To run them, edit `config.lua`:

```lua
CisTestConfig = {
    RunMutating = true,   -- DANGER: only on a test instance
}
```

With mutating tests off, the suite is safe to run against a live server — it
only reads.

## Configuration

`config.lua`:

| Key | Default | Notes |
|---|---|---|
| `RunMutating` | `false` | Enables state-changing tests. Read this warning twice |
| `TimeoutMs` | `8000` | Per-test deadline. Raise for a genuinely slow database |
| `OutputFile` | `nil` | Defaults to `cis-test-report-<timestamp>.json` |
| `RunClientTests` | `true` | Ask connected clients to participate |
| `ClientWaitMs` | `15000` | How long to wait for client results |
| `Verbose` | `true` | Print a line per test |

## Report format

```json
{
  "meta": {
    "resource": "cis_libstest",
    "version": "1.0.0",
    "gameBuild": 4500,
    "framework": "QBCORE",
    "inventory": "ox_inventory",
    "database": "oxmysql",
    "startedAt": 1756425600,
    "mutating": false,
    "ready": true
  },
  "summary": {
    "total": 81, "passed": 74, "failed": 2, "skipped": 5,
    "serverTotal": 38, "serverFailed": 1,
    "clientTotal": 43, "clientFailed": 1,
    "clientsReporting": 1,
    "durationMs": 4310
  },
  "server": [
    {
      "name": "server: callback register + local call",
      "status": "passed",
      "durationMs": 0,
      "values": {}
    }
  ],
  "client": [
    {
      "player": 3,
      "name": "client: ped handle is valid",
      "status": "failed",
      "message": "expected 0, got 12345",
      "durationMs": 1,
      "values": {}
    }
  ]
}
```

`status` is one of `passed`, `failed`, or `skipped`. Key order is deterministic,
so two runs of an unchanged system produce diffable output.

## What is covered

**Server (38 tests)** — resource lifecycle, config delivery, ready state, grid
and pending and histogram internals, config secret-leak checks, the JSON
encoder, callback register / call / await / unknown-name / crash containment /
source validation / numeric-argument passthrough, client-targeted callbacks,
forged-response rejection, the framework bridge, normalised player shape,
unknown source handling, job counts, inventory read and roundtrip, door
registration and state, unauthorised door requests, entity sync create /
remove / coords validation / no-op upsert, the rate limiter, security reports,
logging at all four levels, Discord queue depth, and `net.on` registration.

**Client (43 tests)** — lifecycle, config delivery, ready state, server id, ped
handle, coords and their per-frame memoisation, heading, vehicle and seat
plausibility, weapon shape and non-mutation, cache subscriptions, `near()`
registration, the `Globals` table, box / sphere / poly zone creation and
containment, `onEnter` and `inside` callbacks actually firing, zone removal,
zone debug stats, target availability and create/remove, door registration,
closest-door proximity, unknown door handling, synced entity listing, model
streaming success and failure, inventory count and `has()` agreement, unknown
callback handling, the utility helpers, `CreatePed`, vehicle properties, closest
vehicle, weapon data, logging, and a check that client errors reach the console
with debug disabled.

Tests whose dependency is absent are reported as `skipped` with a reason rather
than failing — no target provider, no nearby vehicle, no database.

## Unit tests

The harness's JSON encoder and report contexts are covered by the pure test
suite, which needs no FiveM:

```
node test/run.js
```

`shared/report.lua` is deliberately free of natives so it can be tested that
way. If you change the encoder, run it — a broken array or escape makes every
saved report unparseable.
