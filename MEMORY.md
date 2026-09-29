# MEMORY.md

**This is the entry point for everything.** If you read one file, read this one.

It records what `cis_libs` is, where the work stands, and everything learned
while building it — most of which was measured on a live server rather than
assumed. Several of the findings here cost days to get right.

**How to rotate this file.** When it grows past useful, start a new
`MEMORY-2.md`, move this one to `archive/MEMORY-1.md`, and leave a short
`MEMORY.md` at the root containing only §1 (navigation), §2 (what the resource
is), and §4 (where we are). Sections 3, 5, 6 and 7 are historical weight; they
only need to be readable, not current.

---

## 1. Navigation

| File | What it is | Read it when |
|---|---|---|
| **`MEMORY.md`** | This file. The record of what was found and why | Always, first |
| [`README.md`](README.md) | Short overview, install, API summary | Someone is deciding whether to use this |
| [`DOCUMENTATION.md`](DOCUMENTATION.md) | **The integration guide.** Boundary model, performance model, every API function, recipes | You are writing a resource that consumes `cis_libs` |
| [`COMPATIBILITY.md`](COMPATIBILITY.md) | The frozen public surface. 1.x is frozen; what 3.0 removes | Any change might break a consumer |
| [`API_SPEC.md`](API_SPEC.md) | The `api.lua` machine-readable contract | Adding a resource, or extending the contract |
| [`BUILD_LOG.md`](BUILD_LOG.md) | Per-unit running log: what changed, gate result, what went wrong | Auditing a decision, or picking up mid-programme |
| [`cis_libstest/README.md`](cis_libstest/README.md) | How to run the integration harness | You are about to run `/cistest` |
| `TEST_MATRIX.json` | Machine-readable test coverage across every layer | You want to know what is and is not tested |

**The split.** `MEMORY.md` is *knowledge* — findings and their reasoning.
`BUILD_LOG.md` is *history* — what was done and whether it passed.
`DOCUMENTATION.md` is *instruction* — how to use the thing.
`COMPATIBILITY.md` is *contract* — what may not change.

### Files that were removed

Three earlier documents were absorbed here rather than simply deleted, because
each contained a finding that mattered:

- `deltareport1.md` (451 lines) — the audit of the pre-Unit-0.1 state. Its
  findings are §5.1 and §6 below.
- `PRODUCT_USAGE.md` (158 lines) — what the six products actually call. That is
  §4.3.
- `MIGRATION_PROMPT.md` (229 lines) — a brief for rebuilding other resources.
  It is now Appendix A of `DOCUMENTATION.md`.

---

## 2. What `cis_libs` is

A standalone FiveM library, version 1.0.0, that provides the pieces almost every
server rewrites: player state, a callback system, spatial zones, an inventory
bridge, a targeting bridge, door locks, entity sync, a database layer, and
logging. **It depends on no other library** — not ox_lib, not PolyZone. It is
not a framework; it sits beside ESX / QBCore / QBOX and normalises the
differences. Requires OneSync and server build 4500+.

Consumers declare it with `shared_script '@cis_libs/init.lua'`, which yields a
global `Cis` table, and gate their startup on `Cis.ready(function(ok) end)`.

### Layout

```
init.lua          the Cis proxy every consumer loads
shared/           5 pure modules, no natives: grid, pending, histogram,
                 config, ready
client/           13 files: cache, callback, doorlock, zones, target, sync,
                 streaming, inventory, vehicle, weapon, logging, utils,
                 initialize
server/           10 files: callback, database, doorlock, security, sync,
                 inventory, player, discord, logging, version, initialize
framework/        ESX / QBCore / QBOX adapters, client and server
configs/          server-only configuration; the client gets a whitelist
```

`shared/` is deliberately pure. That is what makes those modules unit-testable
under fengari with no FiveM server, and it is why roughly 3,400 of ~3,900
library lines still have no unit coverage — the untestable ones are the ones
that touch natives.

### The four rules that matter

1. **`shared_script` copies; it does not share.** Each resource has its own Lua
   VM. A consumer that loads `cis_libs/init.lua` gets a *proxy*, not a handle on
   cis_libs's internals. A consumer that `shared_script`s a stateful file gets a
   second copy of that index and multiplies native calls by its resource count.
2. **Stateless logic can be duplicated; stateful singletons cannot.** Twelve
   files hold process-global state. They are listed in `COMPATIBILITY.md` §10.
3. **Exports return data, not behaviour.** A function can be handed *back*
   across the boundary but not *sent over* (§3.3).
4. **The bracket export form shifts every argument.** §3.1. This one is silent.

---

## 3. The architecture that must survive

### 3.1 The `self` trap — the single most important thing here

```lua
exports['cis_libs']:SomeExport(a, b)    -- CORRECT
exports['cis_libs']['SomeExport'](a, b) -- WRONG
```

The bracket form looks equivalent and is not. It yields an **unbound method**:
the exports table is expected as the first argument, so calling it without
`self` shifts every argument one place left.

`init.lua` carried this bug, and it **silently corrupted every API call in the
library**. A zone created as `(kind, name, coords)` arrived as
`(name, coords, size)`, so the zone's *name became its own coordinates* and
creation returned `false` with no error raised anywhere. Silent, total, and
invisible from the documentation.

**Fixed.** `init.lua` now caches the table and passes it explicitly, which is
exactly what the colon syntax does:

```lua
local EXPORT_TABLE = exports[RESOURCE]
local function exportCall(name, ...)
    return EXPORT_TABLE[name](EXPORT_TABLE, ...)
end
```

**Guarded** by `test/binding.lua` (27 assertions). A canary makes that guard
trustworthy: the stub models the trap, so a regression cannot pass by accident.
Reverting the fix produces 17 named failures and exit code 1.

### 3.2 What `shared_script` actually does

Each resource runs in its own Lua VM; a `shared_script` copies the file in. A
consumer does **not** see `Config`, `Security`, `Globals`, `CisReadyState`, or
`CisCache` — those are cis_libs's globals, and reading them from a companion
resource yields `nil`.

**This bit the test harness twice**, in two separate units, before anyone
noticed it was a general hazard. Anything a companion resource needs must go
through an export:

| Need | Call |
|---|---|
| Is it up? | `Cis.wait(t)` or `exports['cis_libs']:IsReady()` |
| What did the server choose? | `exports['cis_libs']:GetConfigSummary()` |
| What did the server send me? | `exports['cis_libs']:GetClientConfig()` |
| Event prefix | `exports['cis_libs']:GetLibsPrefix()` |
| Would my mutation be allowed? | `exports['cis_libs']:InvokingAllowed()` |
| Check a rate-limit budget | `exports['cis_libs']:RateOk(src, name, ms, n)` |

### 3.3 The measured boundary contract

Measured, not assumed. A purpose-built probe (`cis_libstest/shared/probe.lua`)
established each row.

| Value | Result |
|---|---|
| Number, string, boolean, table, `vector3` | Preserved |
| `nil` | Dropped — the key vanishes from a returned table |
| Multiple return values | **Collapse to the first only** |
| **Function as an argument** | **Dropped** |
| **Function as a return value** | Arrives as a **callable reference table** |

**The asymmetry is the thing to internalise: a function can be handed back, but
not sent over.**

A returned function arrives as `{ __cfx_functionReference = 'resource:line:col' }`
and **is callable** — but `type()` reports `table`, so a
`type(x) == 'function'` check rejects a handler that works. Use
`CisTestProbe.isCallable`, or check for `__cfx_functionReference` directly.

This is why zone `onEnter`/`onExit`/`inside` and `Cis.player.on`/`near` cannot
take a callback from a consumer resource, and why every callback option has an
**Event twin** that does work:

```lua
Cis.zones.box('shop', centre, size, {
    onEnterEvent = 'myResource:shopEnter',   -- receives (zoneName, x, y, z)
    onExitEvent  = 'myResource:shopExit',
    insideEvent  = 'myResource:shopInside',
})
Cis.player.near(coords, 10.0, nil, nil, 'myResource:nearEnter', 'myResource:nearExit')
```

### 3.4 Performance model

Three calls are free for a consumer — `ped()`, `coords()` (memoised to once per
frame), `heading()`. Everything else crosses a boundary, which is irrelevant at
low call rates and ruinous in a `Wait(0)` loop.

Four cross and should not be polled: `Cis.player.vehicle()`, `weapon()`,
`serverId()`, and `Cis.inventory.count()`. The framing that matters:

> An export call at 60 Hz means you are polling something you should be
> subscribing to. Fixing the loop beats optimising the call.

Idle budget: one fallback poll per `Config.UpdateInterval.Player` ms (default
1000) costing roughly ten natives and one `vec4` allocation; no `Wait(0)` loop,
except `DrawText3D` in door mode and a zone with `insideInterval = 0`.

### 3.5 The five `:doorlock:*` event names are computed

They are derived from `Security.EventPrefix`, so **a consumer cannot hardcode
them.** `cis_storeRobberies` calls `AddDoorToSystem` and cannot name the
resulting events. This is load-bearing API behaviour and it is easy to miss.

---

## 4. Where we are

### 4.1 Commits

| Commit | What |
|---|---|
| `efb4702` | **Baseline.** The pre-refactor working tree. Before this, 27 of 52 Lua files had never been committed, and the previous commit (`0249976`) predated the current architecture entirely |
| `b13482a` | **Unit 0.1.** `COMPATIBILITY.md`, the `api.lua` schema and validator, three defect fixes |
| `d3ab480` | **cis_libstest 2.0.** Harness rebuilt around measurement rather than assumption |
| `017118b` | Three harness bugs from the first live run, plus `TEST_MATRIX.json` |

### 4.2 Test estate

| Layer | Count | Runs where |
|---|---:|---|
| unit | 105 | `npm test`, no server, ~2s |
| binding | 27 | `npm test`, guards the self trap |
| contracts | 154 | `npm test`, api.lua vs the real surface |
| **total pure** | **286** | all green |
| server | 38 | `/cistest`, needs a server and a player |
| client | 44 | `/cistest`, same |

`node tools/test-matrix.js` merges all of it into `TEST_MATRIX.json`, recording
any layer that has not run as `not run` rather than omitting it.

**286 pure assertions, and roughly 3,400 of 3,900 library lines have no unit
coverage.** Everything touching a native is integration-tested only, and those
tests are manual because they need a running `fxserver`. See
`TEST_MATRIX.json` → `coverage.gaps`.

### 4.3 What the products actually use

Verified against every product source tree. **All 44 symbols they call exist —
zero broken references.**

- **37 `Cis.*` proxy calls** and **7 `exports['cis_libs']:Name` calls**.
- `cis_tcvs` is the heaviest consumer: 21 distinct proxy calls.
- `cis_storeRobberies` alone depends on **five compat shims** — the strongest
  argument for keeping them until 3.0.
- **`cis_BetterFightEvolved` and `cis_pacificBankRobbery` consume nothing.**
  The freeze does not protect them.
- **The deployed `[standalone]/` copies are stale.** Five of six show zero usage
  there, while the source copies show heavy proxy use. The source copies are
  authoritative; anyone auditing the deployed tree would freeze an almost-empty
  surface.

---

## 5. The record

### 5.1 The original audit — 20 defects found and fixed

A read-only audit of the initial codebase. All fixed.

**Critical**

1. **QBOX framework detection returned success on failure.** `provider = 'QBOX'`
   sat outside the `if ok and core` guard, so a failed `GetCoreObject` produced
   a library that reported ready while every player lookup returned `nil`. The
   QBCORE branch had the identical flaw.
2. **Client logging swallowed everything.** `Logging.Log` returned early for
   *all* levels when debug was off, so every `CisLog('error', …)` — cache
   listener failures, zone callback crashes, sync model failures — was dropped
   in production. Only DEBUG is gated now.
3. **Dynamic entity sync recreated every entity every 2 seconds.** The client
   handler did `despawn` then `spawn` unconditionally. Records are now
   fingerprinted server-side, and the client *moves* an existing entity when the
   model is unchanged.
4. **`SecurityReport` ignored the configured drop handler.** The config defines
   a function; the code tested a boolean and called the global.
5. **`GiveMoney` returned `true` on failure** — the framework's result was
   discarded.

**Security**

6. **Callback keys were not bound to a player.** Keys are sequential integers, so
   a client could guess another player's pending key and resolve it with forged
   data. Now bound to the player they were sent to.
7. Rate limiters, `lastChange` and `lastApplied` all leaked.

**Correctness**

8. **The vehicle seat was read from the wrong array index.** `data['seatIndex']
   or data.seatIndex or data[1]` — the first two are the same key, and
   `data[1]` is the *vehicle handle*. A "seat" of 1234567 was then cached
   permanently, because derivation only ran when the value was nil.
9. **`Cis.callback.call` reinterpreted a numeric first argument as a player
   ID.** Split into `call` / `callClient`.
10. **DB awaits could park a coroutine forever.** Now bounded by
    `Database.Timeout`.
11. **Zone exits fired up to 32 units late** — the grid pass only ran after half
    a cell of movement. Added a cheap recheck of already-entered zones.
12. `aabbFromPoints({})` returned infinities. `Target.Remove` reported failure
    for successful removals. The Discord queue was unbounded.

**Performance**

13. **`queryNeighbors` did 9× the work of `queryPoint` for an identical
    result.** Verified by fuzzing 3,000 random points against a brute-force
    reference: zero differences. Because `insert` registers an id in every cell
    its AABB overlaps, the single containing cell is provably sufficient.
14. **The DrawText3D door loop called a cross-resource export every frame.**
15. The sync broadcast re-read every player's coords per record.

### 5.2 Four harness bugs that produced a *green* suite

The test harness itself failed four ways, and **all four reported success while
testing nothing.** They are recorded because the pattern recurs.

1. **A shared context across tests.** Bodies received a *capture callback*
   instead of a context, so `check(ctx).equal(…)` evaluated on nil, `pcall`
   swallowed it, and the suite context (named `"server"`, status `passed`) was
   recorded 40 times. **77 of 84 tests "passed"; not one ran an assertion.** One
   context per test, created and named *before* the body runs.
2. **`ok and nil or tostring(err)`.** When `ok` is true, `ok and nil` is nil, so
   the `or` branch ran and every *passing* test was reported as
   `failed / crash / "nil"`. One run read as 77 failures with the detail
   `"nil"`.
3. **A forward-declared local shadowed by `local function`.** `local collect`
   followed by `local function collect()` creates two different locals; the one
   captured by an earlier handler stayed nil forever.
4. **A build tool that reported success unconditionally.** A scripted edit
   silently failed to match while printing "done", and a deployed file was
   wrongly blamed for being stale when the change had never landed.

### 5.3 The measurement that settled it

When behaviour was ambiguous, a probe was added that returned what *actually*
arrived, and the data was read rather than interpreted:

- `EchoArgs('alpha', 7, true)` — proved argument order was intact across the
  boundary, which killed the "the boundary is corrupting arguments" theory.
- `ProbeTypes()` — proved functions return as callable reference tables.
- Returning `false, '<reason>'` from a refusal, recorded by the caller — turned
  `"name arrived as vector3"` into the `self` trap diagnosis in one run.

Each was faster than the round of guessing it replaced, and **two of the
theories they replaced were simply wrong.**

---

## 6. Open defects

### Confirmed by measurement

| # | Defect | Impact | Status |
|---|---|---|---|
| **9.3** | **Remote handler dispatch loses every argument.** `invoke` does `pcall(fn, src, ...)` on an export reference. The handler is reached and its return value crosses intact, but it receives **zero arguments** | Every `Cis.callback.register(name, 'resource:export')` handler. **No shipped product affected** — `cis_storeRobberies` registers a local function — so the path has simply never worked | Confirmed live. Fix direction: stop calling an export to obtain behaviour; pass arguments out of band, or dispatch through a net event |
| **9.2** | **`Cis.db.transaction` always times out and returns `nil`.** `Database.Transaction(queries, cb)` has arity 2, but `exportAwait` calls `method(sql, params, cb)` — so the callback receives the query list and is never invoked | `cis_housing` and `cis_phone`. A guaranteed **15-second stall on every driver, including oxmysql**. Driver evidence: `Transaction parameters must be array or object, received 'undefined'` | Pinned as a test. The brief's stated contract (`false, 'transactions require oxmysql'`) describes a string that is unreachable through any export |
| **9.1** | **`Cis.framework.notify` is realm-asymmetric.** The proxy takes `(srcOrNil, message, kind)`; the client export takes `(message, kind)`. A two-argument call resolves differently per realm | `cis_tcvs`, `cis_storeRobberies`, `cis_HawkEyeSurveillance` | Pinned as a test. Needs a separate entry point per realm |
| — | **`Security.AuthorizedResources` is read once at load** by `rebuildAuthorized()` and never rebuilt, so a runtime console change is ignored | All mutation calls | Documented. *(An earlier draft of this file claimed it was fixed; it is not.)* |

### Confirmed present, not yet fixed

From the original audit: `CheckVersion` phoning home (now defaults `false`, host
removed), the empty allow-list (now restrictive for new installs, permissive for
legacy), no capability registry, no `Result` type, the module-restart race
unsolved, no machine-readable contract, and no migrations / state layer / NUI /
perf harness / observability. See `COMPATIBILITY.md` and `BUILD_LOG.md`.

### Found while writing tests

- **A guard gap.** Reordering `Cis.callback.callClient`'s parameters from
  `(name, src, …)` to `(src, name, …)` passed *both* `binding.lua` and the CI
  grep. `test/contracts.lua` closes it: 11 planted mutations, 11 caught, against
  2 of 7 before.
- **`GetNormalizedPlayer` returns a well-formed table for a source that does not
  exist** — echoing the requested id with `name` and `job` nil. A caller cannot
  distinguish "no such player" from "this framework cannot tell you". This is
  the brief's defect 5 appearing in practice.

---

## 7. Working rules

**Do**

- Make the library **explain itself** before forming a theory. A refusal that
  returns a reason, and a probe that records what arrived, beat every round of
  guessing. The `self` trap took six rounds to find and one probe to confirm.
- **Verify edits with `grep`**, not with the exit status of the script that made
  them. That mistake cost a cycle twice.
- **Run the gate yourself.** A subagent reporting "done" is not evidence. One
  subagent's completion claim needed four separate checks before it held.
- Treat a **skip as not a pass**, and read the reason.
- Copy the **whole** resource when deploying. Six files had drifted and four of
  them ran.

**Do not**

- `shared_script` a stateful file from a consumer.
- Use the bracket form of an export call.
- Pass a function into an export. Use the `*Event` form.
- Read `Config`, `Security`, `Globals`, or `CisCache` from another resource.
- Change an existing public signature in 1.x. Freeze the *interface*, not the
  defect — where a shipped behaviour is wrong, add a deprecation warning at the
  call site rather than staying quiet about it.

---

## 8. The one lesson worth keeping

For six rounds the boundary was blamed for a bug that was in our own proxy
layer. Every probe that measured the boundary came back clean; the evidence was
pointing the whole time at `exportCall`, and it kept being read as a FiveM
mystery.

What broke it open was the crudest thing available: **make the library return
`false, '<what specifically was wrong>'` and have the caller print it.**
`"name arrived as vector3"` is not an interpretation. It is the answer, and it
arrived in a single run after several rounds of plausible theory.

Every ambiguous behaviour in this codebase should be able to do that.
