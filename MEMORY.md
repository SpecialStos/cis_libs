# MEMORY.md

**This is the entry point for everything.** If you read one file, read this one.

It records what `cis_libs` is, where the work stands, and everything learned
while building it — most of which was measured on a live server rather than
assumed. Several of the findings here cost days to get right.

**How to rotate this file.** It is ~35 KB and about to outgrow its welcome. When
it does: start a new `MEMORY-2.md`, move this one to `archive/MEMORY-1.md`, and
leave a short `MEMORY.md` at the root containing only §1 (navigation), §2 (what
the resource is), and §4 (where we are). Sections 3, 5, 6 and 7 are historical
weight; they only need to be readable, not current.

**What is current and what is not.** §2, §3 and §4 are current. §5 and §6 record
what was found *and when* — several entries there describe defects that are now
fixed, and that is deliberate: a wrong finding that was believed for a unit is
worth as much as a right one, because the next person will otherwise re-derive
it. Read §5 for the reasoning and §6 for what is still open.

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
| [`tools/deploy.sh`](tools/deploy.sh) | Mirror the working tree into a live server, verify parity, apply test overlays | Before any live run |
| [`tools/serverlog.sh`](tools/serverlog.sh) | Read `fxserver.log` incrementally by byte offset | Reading what a command actually produced |
| [`tools/report.js`](tools/report.js) | Every failure and every skip-with-reason from a report | After a run, before believing it |
| [`tools/luacheck.js`](tools/luacheck.js) | Parse every `.lua` file; no Lua needed locally | Before deploying — a parse error still reports "Started" |

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

**The live-server pass is not committed.** Everything in §5.4–§5.8, §6 and the
`tools/` scripts sit in the working tree: 21 modified files plus 4 new tools,
reviewed but uncommitted. Nothing in this section is a claim about a commit —
`git log` stops at `017118b`.

### 4.2 Test estate

| Layer | Count | Runs where |
|---|---:|---|
| unit | 105 | `npm test`, no server, ~2s |
| binding | 27 | `npm test`, guards the self trap |
| contracts | 158 | `npm test`, api.lua vs the real surface |
| **total pure** | **295** | all green |
| server | 48 | `/cistest`, needs a server and a player |
| client | 48 | `/cistest`, same |
| **total live** | **96** | 92 passed, 0 failed, 4 skipped |

`node tools/test-matrix.js` merges all of it into `TEST_MATRIX.json`, recording
any layer that has not run as `not run` rather than omitting it. It reads a live
report from `cis_libstest/` or `reports/`, so copying a run's JSON in makes the
matrix reflect the integration layers rather than reporting them as unrun.

**Last full run:** 391 cases · 387 passed · **0 failed** · 4 skipped.

The four live skips are each deliberate, and none is a hidden pass:

| Skip | Why it is a skip and not a pass |
|---|---|
| `defect 9.1: framework.notify is realm-asymmetric` | The asymmetry is between realms; observable only from the client suite. |
| `defect: the allow-list is read once at load` | Pins a real defect: a runtime change is ignored. |
| `core: a forged callback response is ignored` | Needs **two** connected players. The suite runs one. |
| `core: vehicle properties round-trip` | Needs the player to be sitting in a vehicle. |

The last two clear on the spot: connect a second client, or sit in a car, and
re-run. They are environmental, not unresolved.

**295 pure assertions, and roughly 3,400 of 3,900 library lines have no unit
coverage.** Everything touching a native is integration-tested only, and those
tests are manual because they need a running `fxserver`. See
`TEST_MATRIX.json` → `coverage.gaps`.

### 4.3 Running the live suite (this is the whole workflow)

The server lives at
`C:\Users\CB\Desktop\FiveM\txData\Qbox_A15D5A.base\resources\[standalone]\`,
and its console is at `http://localhost:40120/server/console`. Four tools, all in
`tools/`, make a run repeatable:

| Step | Command | What it does |
|---|---|---|
| 1 | `tools/deploy.sh --test-instance` | Mirrors the working tree into `[standalone]/`, verifies parity, applies the test-only overlays |
| 2 | *(console)* **Clear** | The trash icon under the terminal. Start from an empty buffer every run |
| 3 | *(console)* `refresh`, then `ensure cis_libs`, then `ensure cis_libstest`, then `cistest` | |
| 4 | `node tools/report.js` | Every failure and **every skip with its reason**. Exits 1 on any failure |

`tools/serverlog.sh mark` / `since` reads `fxserver.log` **by byte offset** — it
is ~70 MB and is never read whole. This is how the boot path gets checked, which
the browser cannot do: the console terminal does not render into a screenshot,
so the log is the only reliable way to *read* what a command produced.

`--test-instance` applies three changes that belong to a **test server only**,
after the mirror so they survive the next deploy: `cis_libstest` onto the
allow-list, `RunMutating = true`, and `Framework.Type` matched to the framework
actually running. A plain `tools/deploy.sh` puts the repo defaults back.

**Three things that will waste an hour if you do not know them:**

- `restart cis_libs` also **stops** `cis_libstest`, because the harness depends
  on it. Re-`ensure` it, or `cistest` answers `No such command`.
- A **parse error** in the harness still reports `Started resource
  cis_libstest`, and every later command fails pointing somewhere else. Run
  `npm run test:luacheck` before deploying.
- Export names here contain a colon (`cis_test:capture`), so
  `exports['cis_libstest']:cis_test:capture()` **does not parse** — `:cis_test`
  is read as a method call. Use `probeExport(name, ...)` in
  `cis_libstest/server/suite.lua`, which passes the table explicitly.

### 4.4 What the products actually use

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

### 5.4 The measurement that corrected defect 9.3

Everything in §6 about 9.3 was an **inference from the bracket CALL form**.
The dispatch path performs a bracket **LOOKUP** and then a `pcall`, which is a
different question. Run 1 "measured" it and concluded the handler received
**zero arguments** — a drop, not a shift. That was wrong, and the wrongness
mattered: the natural fix for a shift (pass the table explicitly) is a no-op
for a drop, so the recorded diagnosis would have produced a broken fix.

The decisive probe runs **inside `cis_libstest`'s own VM**, where there is no
resource boundary to interpret, and calls the same export both ways:

```
bracket:  n=2 [B|C]      -- exports[res][name]('A','B','C')
explicit: n=3 [A|B|C]    -- exports[res][name](exports[res],'A','B','C')
```

**The bracket lookup is an unbound method.** It is the same trap as the call
form, it cost the same one slot, and `src` was the argument that disappeared.
The fix is `pcall(fn, target, src, ...)` — three characters of insight, and it
only came from asking the engine instead of reasoning about it.

The rule this earns: **"the handler received nothing" and "the handler received
the wrong things" produce different fixes, and only one of them works.** When a
probe reports an absence, measure the shape of what is actually there before
concluding there is nothing.

### 5.5 Two more harness bugs, found the same way

1. **A table's string keys do not survive the exports boundary.** The probe
   returned `{ n = N, [1] = a, ... }` and then read `captured.n` back. The
   numeric entries arrived; `n` did not. The count read as `nil`, the test
   concluded the handler "recorded nothing", and two probes were skipped for
   several runs — all from a number that crossed as a string key rather than
   as data. **Anything asking a question across the boundary must return a
   scalar.** `cis_test:lastArgCount` and `cis_test:lastArgs` exist for this.
2. **A mixed-key table does not survive the _return_ trip at all.** Returning
   one makes the awaiting export throw. `cis_test:capture` now returns a
   formatted string for the same reason.

Both are the §5.2 pattern again: a green suite that had measured nothing, and
a "failure" that was really the test asking the question in a shape the boundary
cannot carry.

### 5.6 A green suite says nothing about the console

The single most important process failure in this programme, and the one that
cost the most: **a passing suite was reported as "no problems" while the server
console was visibly printing errors.** A test suite reports on the cases someone
wrote. It says nothing about the noise a boot produces, and "0 failed" reads
very much like "fine" to anyone who has just read `===== 0 failed =====`.

Reading the console line by line found three things the suite was blind to:

**A database error on every boot.** `oxmysql: Table 'cis_doors' doesn't exist`,
each time `cis_libs` started. `cis_doors` is created only when
`Doorlock.Persist` is on, and the shipped default is off — but when an
allow-list **is** configured, `rebuildAuthorized()` set `authorized` and returned
**without settling `posture`**, so the deferred legacy-detection probe ran
anyway and queried a table that was never supposed to exist. Any server with an
allow-list configured paid a database error on every start, naming a table the
operator had never heard of. Fixed on both sides: a configured list now marks
the posture decided (it is a definite answer — nobody is guessing), and the
deferred probe is gated on `persistConfigured()`.

**A shape check cannot tell "works" from "degrades cleanly".**
`core: the normalised player has a stable shape` passed while the library sat in
standalone mode, because the shape is *correct in standalone mode too*. That is
the same trap as `GetNormalizedPlayer` returning a table for a source that does
not exist. The fix is a test that asks a question with only one right answer: a
**connected** player must resolve to a populated `name` and `job`. That test is
what caught the QBOX detection defect in §6.

**A refused call is still the library working.** Awaiting an unregistered
callback raises, a coordless sync record is refused, and the logger is exercised
at every level — all deliberately, all correct, all of which write to the
console. The harness now brackets its own run with `EXPECTED ERROR OUTPUT
BEGINS/ENDS` so an operator can tell "the tests are working" from "the library
is broken" without opening the source. Nothing was silenced: lowering a real
ERROR to a WARN to make a console pretty would be the wrong trade.

### 5.7 When the fix "did not work", check the test before the code

The 9.2 fix looked broken on the first attempt. The library was fine; **the test
was wrong.** It sent `{{ 'SELECT 1' }}` — an array of bare arrays — where oxmysql
wants an array of `{ query = ..., values = { ... } }` objects. The driver rejected
it with a message indistinguishable from the old defect.

Without reading the driver's own error, the next honest-looking move was to write
"still broken" in the log and abandon a fix that worked. The rule this earns:
**when a fix fails, the regression is evidence about the failure — read the
downstream error before blaming the change.** §8 is the same lesson one level up.

### 5.8 A non-greedy Lua pattern asserts the wrong slice

The guard for the boot error was written as
`secSource:match('local list = configuredList%(%)(.-)end\n')`. The non-greedy
match stopped at the **first** `end` — the `for` loop's — so the assertion
inspected a slice that did not contain the thing under test. It failed, and
correctly, but for the wrong reason. Rewritten with plain `find`/`sub` on
explicit offsets.

A test that is wrong in a way that *fails* is lucky. This one would have been
indistinguishable from a real regression.

---

## 6. Defects

### Still open

Two real defects remain. Both are pinned by a test rather than fixed, because
fixing either is a behaviour change to a shipped export and `COMPATIBILITY.md`
§3.1 makes that a deliberate decision, not a cleanup.

| # | Defect | Impact | Why it is still open |
|---|---|---|---|
| **9.1** | **`Cis.framework.notify` is realm-asymmetric.** The proxy takes `(srcOrNil, message, kind)`; the client export takes `(message, kind)`. A two-argument call resolves differently per realm, and on the client the two-argument branch sends the *kind* in the message slot | `cis_tcvs`, `cis_storeRobberies`, `cis_HawkEyeSurveillance` | Needs a separate entry point per realm. Fixing the client branch changes what a shipped call actually delivers — a MAJOR decision |
| — | **`Security.AuthorizedResources` is read once at load** by `rebuildAuthorized()` and never rebuilt, so a runtime console change is ignored. A restart re-reads it, which is the supported way | All mutation calls | Making it live is a behaviour change. *(An earlier draft of this file claimed it was fixed; it is not.)* |

### Found and fixed in the live-server pass

| # | Defect | Impact | Fix |
|---|---|---|---|
| **9.3** | **Remote handler dispatch shifted every argument by one slot.** `invoke` resolved `fn = target[ref.export]` and called `pcall(fn, src, ...)`. The bracket **lookup** is an unbound method, so `src` was consumed as `self` and the handler received the caller's arguments **without the source** | Every `Cis.callback.register(name, 'resource:export')` handler. **No shipped product affected** — `cis_storeRobberies` registers a local function, so the path had simply never worked | `pcall(fn, target, src, ...)`. See §5.4 — the earlier description of this defect was *wrong*, and the wrongness would have produced a broken fix |
| **9.2** | **`Cis.db.transaction` always timed out and returned `nil`.** `exportAwait` calls `method(sql, params, cb)`, but `Database.Transaction` is `(queries, cb)` — so the callback landed in a slot it never read, the transaction never ran, and the await burned the full 15 s | `cis_housing` and `cis_phone`, on **every** call, with a driver error logged each time | `DbTransaction` registered longhand so the callback reaches slot 2. Verified live: completes in well under the timeout, oxmysql logs nothing. See §5.7 for why the first attempt appeared to fail |
| — | **QBOX detection could never succeed on a current qbx_core.** It required `exports.qbx_core:GetCoreObject()`, which qbx_core **removed in 1.9** | Every server configured `Framework.Type = "QBOX"` silently fell back to **standalone mode** — `Cis.framework.player(src)` returned a table with no name and no job, and no consumer could tell | Probe `GetCoreObject` for an older qbx_core, otherwise probe the `GetPlayer` export the library already uses. A missing export raises; a present one with a bad id returns nil, so the `pcall` is an honest existence test |
| — | **`GetConfigSummary().databaseReady` was permanently `false`.** `Database` was a file-local in `server/database.lua`; `server/initialize.lua` read a *global* of that name | Any consumer gating on that field was told the database was never ready, even with oxmysql initialised | `Database` is a global again, with a source-level pin in `test/contracts.lua`, **verified in both directions** |
| — | **A database error on every boot.** The deferred legacy-detection probe queried `cis_doors` on servers that had an allow-list configured, because that branch returned without settling `posture` | Every boot of every configured server | See §5.6. Two fixes, each correct alone, both pinned in `test/contracts.lua` |
| — | **`Cis.sync.*` without a caller-supplied id never upserted.** `data.id = data.id or nextId(kind)` minted a fresh id every call, so "re-sending identical data is a no-op" held only for callers managing their own ids | Every other caller got a duplicate entity per call | Content fingerprint excludes `id`, plus an O(1) content index |
| — | **`Cis.doors.add` and `Cis.doors.setState` could not report success.** Both returned `nil` unconditionally, in *both* realms | "locked it" and "no such door" were indistinguishable — the exact ambiguity the library's own refusal convention exists to remove | Both answer now. Additive: a caller that ignored the old `nil` is unaffected |

### Confirmed present, not yet fixed

- **`GetNormalizedPlayer` returns a well-formed table for a source that does not
  exist** — echoing the requested id with `name` and `job` nil. A caller cannot
  distinguish "no such player" from "this framework cannot tell you". This is the
  brief's defect 5 appearing in practice, and it is the same shape as the QBOX
  failure in §6: a correct-looking answer that carries no information. A caller
  gating work on `player.name` gets `nil` and no indication why.
- The module-restart race is unsolved. It is defect 6 in the brief and untested
  by design.
- No capability registry, no `Result` type, no migrations / state layer / NUI /
  perf harness / observability. These are scope, not defects.
- ~~No machine-readable contract~~ — `api.lua` and its validator now exist and
  run in CI. This line was stale; the contract is `API_SPEC.md`.

### A claim in this file that is not backed by an artifact

Both `MEMORY.md` and `COMPATIBILITY.md` have stated, at various times, that a
number of planted mutations were "11 caught" and "13 caught". **No committed
script produces either figure.** They were measured ad hoc during a session and
the runner was never kept.

By this file's own standard — §7, "run the gate yourself" — a claim with no
artifact behind it is not evidence, and this is precisely the class of thing §5.2
records going wrong four times. What *is* committed and reproducible is the
guard set in `test/contracts.lua`, plus the two source-level pins (`Database`
global, allow-list posture) that were each verified by reintroducing the bug.
The honest statement is the guard count, not a mutation count.

---

## 7. Working rules

**Do**

- Make the library **explain itself** before forming a theory. A refusal that
  returns a reason, and a probe that records what arrived, beat every round of
  guessing. The `self` trap took six rounds to find and one probe to confirm.
- **Read the console, not just the scoreboard.** A green suite is evidence about
  the cases someone wrote. The boot path is evidence about everything else.
  §5.6 is the run where this mattered.
- **Verify a fix by reading the downstream error** when it appears not to work,
  before blaming the change. §5.7.
- **Verify edits with `grep`**, not with the exit status of the script that made
  them. That mistake cost a cycle twice.
- **Run the gate yourself.** A subagent reporting "done" is not evidence. One
  subagent's completion claim needed four separate checks before it held.
- **Prove a guard fails before trusting it.** Both the `Database` global and the
  allow-list posture guards were checked by reintroducing the bug: 2 named
  failures and exit 1 each time.
- Treat a **skip as not a pass**, and read the reason.
- Copy the **whole** resource when deploying. Six files had drifted and four of
  them ran.

**Do not**

- `shared_script` a stateful file from a consumer.
- Use the bracket form of an export call. **The lookup is as unbound as the
  call** — §3.1 measured only the call form for years.
- Pass a function into an export. Use the `*Event` form.
- Read `Config`, `Security`, `Globals`, or `CisCache` from another resource.
  And do not make a module `local` that another file reads as a global — that is
  the same class of mistake, in the other direction.
- Ask a question across the boundary with a **table**. Return a scalar; string
  keys do not survive. §5.5.
- Change an existing public signature in 1.x. Freeze the *interface*, not the
  defect — where a shipped behaviour is wrong, add a deprecation warning at the
  call site rather than staying quiet about it.
- Quiet a correct ERROR to make a console look clean. Frame it instead. §5.6.

---

## 8. The lessons worth keeping

**The first.** For six rounds the boundary was blamed for a bug that was in our
own proxy layer. Every probe that measured the boundary came back clean; the
evidence was pointing the whole time at `exportCall`, and it kept being read as
a FiveM mystery.

What broke it open was the crudest thing available: **make the library return
`false, '<what specifically was wrong>'` and have the caller print it.**
`"name arrived as vector3"` is not an interpretation. It is the answer, and it
arrived in a single run after several rounds of plausible theory.

Every ambiguous behaviour in this codebase should be able to do that.

**The second, and it is the same lesson wearing different clothes.** Defect 9.3
was pinned as "the handler receives zero arguments" for an entire unit, and that
was wrong — the handler received everything *except* the first argument. Nobody
caught it because the conclusion sounded like a measurement.

> **A recorded finding is not a measured one.** The difference is whether
> something asked the engine, or whether a human read a shape and named it.

This is why `MEMORY.md` §5.4 exists, why `COMPATIBILITY.md` §13.3 carries a
correction notice rather than a quiet edit, and why the probe that answered it
runs **inside** `cis_libstest`'s own VM where there is no boundary to
interpret. A number is worth exactly as much as the question that produced it.

**The third.** Two defects in this codebase were invisible to a green test suite
and visible in thirty seconds of reading a console (§5.6). A test suite is
evidence about the cases somebody thought to write. It is not evidence about the
system. Both are needed, and only one of them was being looked at.
