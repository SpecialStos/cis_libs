# BUILD_LOG

Running record of programme units. One entry per unit: date, what changed, gate result,
and anything the subagent got wrong.

Format: gate items are the brief's, checked by the orchestrator against the repo, not taken
from the subagent's report.

---

## Pre-wave — freeze baseline

### Baseline commit

**Date:** 2026-09-29 · **Commit:** `efb4702` "Baseline: cis_libs v1.0.0 working tree, pre-refactor"

§0.1a Decision 2. 27 Lua files had never been committed and the previous commit (`0249976`)
predates the current architecture entirely. One commit, 64 files, labelled as the pre-refactor
state so every later gate has something to diff against.

Repo-local git identity set to the existing author (`Cisoko`) — the machine had none configured.
Not set globally.

### Test harness made CI-possible

Before the baseline could be a baseline, three gaps had to close:

- `test/binding.lua` — 27 assertions proving arguments survive the exports boundary, with a
  **canary** proving the stub models the `self` trap. Reverting the fix produces 17 named
  failures and exit code 1 (verified both ways).
- `package.json` + `package-lock.json` — previously **undeclared and gitignored**, so a clean
  checkout could not run the tests at all. Now committed; CI uses `npm ci`.
- `.github/workflows/tests.yml` — runs the suite, a grep tripwire for unbound export calls, and
  a Lua syntax check.

The tripwire was tested by planting a regression: the first pattern (`[A-Za-z_]+`) missed
double-quoted `exports["x"]["Y"](…)` and also fired on the comments documenting the trap. The
shipped pattern matches the call shape instead.

### Product usage enumeration

**`MEMORY.md` §4.3** — §0.1a Decision 1.

- **37 proxy calls** and **7 export calls** consumed across the products. All 44 verified to
  exist. **Zero broken references.**
- The deployed `[standalone]/` copies are **stale** — five of six show zero usage, while the
  `ZCode/` source copies show heavy proxy use. The source copies are the baseline; the deployed
  tree must be re-synced.
- `cis_BetterFightEvolved` and `cis_pacificBankRobbery` consume nothing at all. The freeze does
  not protect them.
- `cis_storeRobberies` depends on **five compat shims**. That is the strongest argument for
  keeping the shims until 3.0.

---

## UNIT 0.1 — Freeze, contract, three defects

**Date:** 2026-09-29 · **Status: gate PASSED**

One subagent. Gate run and checked by the orchestrator afterwards.

### Gate result

| # | Item | Result |
|---|---|---|
| 1 | Zone + door through the public API, args intact | **PASS** — 105 + 27 + 154 assertions |
| 2 | `COMPATIBILITY.md` enumerates all 52 server / 55 client exports from source | **PASS** — 1009 lines; 20 spot-checks incl. the 7 undocumented, all in source and all documented |
| 3 | Twelve stateful files, `:doorlock:*` computed from `Security.EventPrefix` | **PASS** — twelve, plus six more found by reading; computed-prefix claim present |
| 4 | `api.lua` validator green on a real fixture | **PASS** — 52 server / 55 client / 25 net events resolved |
| 5 | Validator **fails** on a broken fixture | **PASS** — 5/5 rejected: E010, E030, E031, E032, E042 |
| 6 | `CheckVersion` false, third-party URL absent | **PASS** — `grep` clean; the only `github.io` in the repo is a test asserting none exists |
| 7 | `node test/run.js` passes unmodified | **PASS** — `test/run.lua` and `test/binding.lua` untouched |
| 8 | No removed or renamed public symbol | **PASS** — zero deletions; `init.lua` untouched |

### Deliverables

- `COMPATIBILITY.md` (1009 lines) — full surface, semver policy, four-number manifest contract,
  3.0 removal list (14 shims), changelog policy. Export tables generated from source, not transcribed.
- `API_SPEC.md` + `api.lua` + `tools/validate-api.js` + `tools/lua-exports.js` — schema, validator,
  and a self-test. Wired into CI. The validator **fails on what it cannot read** rather than guessing.
- `test/contracts.lua` — 154 assertions on argument slots, export resolution, discriminators, and a
  source-level pin on `exportCall`'s shape.
- Three fixes: `CheckVersion` default off and the third-party host removed; `AuthorizedResources`
  restrictive for new installs with a legacy-detection path; a boot-time diagnostic for the
  transaction driver.

### What the subagent got wrong or found

1. **It did not touch the `self` trap**, correctly — I had already fixed it, and the prompt said so.
   `git diff --quiet init.lua` confirms.
2. **It found a real hole in the guard I wrote.** Reordering `Cis.callback.callClient`'s parameters
   from `(name, src, …)` to `(src, name, …)` passed both `binding.lua` and the CI grep, because
   the grep matches the literal call shape and `binding.lua` never reached the proxy wrappers that
   reorder. `contracts.lua` closes it: **11 planted mutations, 11 caught**, against 2 of 7 before.
3. **It found three live defects and correctly did not fix them** (Unit 0.1 forbids behaviour
   changes). All three verified independently and recorded in `MEMORY.md` §6.
4. **It caught an error in my `MEMORY.md`**, which claimed `Security.AuthorizedResources` is
   "re-read on demand". It is read once at load. Corrected.

### Two behaviour changes, both required and documented

1. `InvokingAllowed` / `AddDoorToSystem` / `AddDoorGroup` / `SyncCreate` / `SyncRemove` on a **new**
   install with an empty allow-list now refuse foreign callers. Legacy installs unchanged.
   Return values byte-identical.
2. `Config.CheckVersion` now defaults to `false`.

---

## Defects open after Unit 0.1

Carried forward. Full detail in `MEMORY.md` §6.

| # | Defect | Status |
|---|---|---|
| 9.1 | `Cis.framework.notify` realm-asymmetric signature | pinned, not fixed — 3 products affected |
| 9.2 | `Cis.db.transaction` always times out, returns `nil` | pinned, not fixed — 2 products affected |
| 9.3 | `server/callback.lua` remote dispatch loses every argument | **CONFIRMED LIVE.** Handler invoked with `n = 0`. Not a shift — the arguments are dropped. No shipped product affected (`cis_storeRobberies` registers a local function, not a remote reference), so the path has simply never worked. Full measurement in `MEMORY.md` §6 |
| 2 | `AuthorizedResources` read once at load | corrected in `MEMORY.md`; not fixed |

**9.2 invalidates the brief's defect 3.** The brief states the contract is
`false, 'transactions require oxmysql'`. That string is unreachable through any export; the
measured contract is `nil` after a 15-second stall, on every driver. §0.1a Decision 1's rule
applies: freeze the interface, not the brief's description of it.


---

## RUN 1 — first live run of cis_libstest 2.0

**Date:** 2026-09-29 · Qbox server, 1 client connected

**Outcome:** server suite 34 passed / 3 failed / 12 skipped. The client's 48
tests were received but the report was never written — `collect()` threw on a
non-existent `version()` native. Fixed.

**The result that mattered: defect 9.3 is confirmed.**

| Probe | Result |
|---|---|
| `remote handler binding` | **FAILED** — the handler recorded **zero** arguments |
| `argument types survive` | skipped — handler recorded 0 arguments |
| `vector3 arguments survive` | skipped — handler recorded nothing |
| `remote handler return value` | passed — returns come back correctly |
| `multiple return values collapse` | passed — only the first crosses |

Control flow reaches the handler and the return value crosses intact. Only the
**arguments** are lost. So the reference is bound (contradicting the earlier
"unbound method" reading) but is not argument-forwarding. See
`MEMORY.md` §6 for the full analysis and fix direction.

**Three harness bugs the run exposed, all mine:**

1. `version()` is not a FiveM native. It threw inside `collect()`, so **no
   report was written at all**. Replaced with `GetResourceMetadata`.
2. The suite read `Config` and `Security` directly. Those are **cis_libs's**
   globals and are `nil` in a separate VM — the same cross-VM mistake made
   earlier in this programme. Both tests now read through `GetConfigSummary()`.
3. `GetNormalizedPlayer` returns a **well-formed table even for a source that
   does not exist**, echoing the requested id with `name` and `job` nil. The
   test now asserts that truth and names it: a caller cannot distinguish
   "no such player" from "this framework cannot tell you". That is defect 5
   showing up in practice.

**Also confirmed with the driver's own error:** `oxmysql: Transaction
parameters must be array or object, received 'undefined'` — defect 9.2's arity
mismatch, now with first-party evidence.

---

## RUN 2 — driving the live suite to zero failures

**Date:** 2026-09-29 · Qbox server, 1 client connected (player 3)

**Started at:** 95 tests · 75 passed · 3 failed · 16 skipped
**Finished at:** 95 tests · **90 passed · 0 failed · 5 skipped**

Gate run by the orchestrator throughout; every number below came from a report
file, not from a claim.

### What actually changed

| # | Change | Kind |
|---|---|---|
| 1 | `invoke()` passes the exports table to a remote handler | **library fix** — defect 9.3 |
| 2 | `canonical()` excludes `id`, plus a content index; an idless `Cis.sync.*` now upserts instead of duplicating | **library fix** — new defect |
| 3 | `SetDoorState` returns how many doors it changed; `LockDoors`/`UnlockDoors` return it | **library fix** — `Cis.doors.setState` could not report success |
| 4 | `Database` is a global again, so `GetConfigSummary().databaseReady` is not permanently false | **library fix** — new defect |
| 5 | Client `AddDoorToSystem` returns true/false | **library fix** — `Cis.doors.add` could not report success |
| 6 | Probes read argument counts over dedicated scalar exports | **harness fix** |
| 7 | `cis_test:getRelay` takes `src` as a parameter instead of reading a global | **harness fix** |
| 8 | `Regenerate` of the inventory, vector3 and closest-door assertions | **harness fix** |
| 9 | `tools/deploy.sh`, `tools/serverlog.sh`, `tools/report.js` | **tooling** |

### The finding that mattered most

**Defect 9.3 was documented wrong, and the wrongness would have produced a
broken fix.** Run 1 recorded "the handler receives zero arguments — a drop, not
a shift". Measuring the bracket *lookup* rather than inferring it from the
bracket *call* form gave:

```
bracket:  n=2 [B|C]      -- exports[res][name]('A','B','C')
explicit: n=3 [A|B|C]    -- exports[res][name](exports[res],'A','B','C')
```

The lookup is an unbound method, exactly like the call form. `src` was the
argument that disappeared. A shift is fixed by passing the table; a drop is
not — so the recorded diagnosis would have sent the next person at a no-op
fix. See `MEMORY.md` §5.4.

### Two more harness bugs, both producing false signals

1. A table's **string keys do not survive the boundary**. The probe returned
   `{ n = N, ... }` and read `captured.n` back; the numbers arrived and `n` did
   not. Two probes skipped themselves for several runs because of it. The
   count now comes from `cis_test:lastArgCount`.
2. A **mixed-key table does not survive the return trip at all** — returning one
   makes the awaiting export throw. `cis_test:capture` returns a string now.

### The three genuine library defects found by the mutating tier

The mutating tier had never run: `RunMutating` was off and `cis_libstest` was
not on the allow-list. Turning it on found three real ones that no amount of
reading would have surfaced — each of them a documented promise that did not
hold:

- **`Cis.sync.*` without a caller-supplied id never upserted.** Every call
  minted a fresh id, so "re-sending identical data is a no-op" held only for
  callers that tracked ids themselves. Found by `expected prop_1, got prop_2`.
- **`Cis.doors.setState` and `Cis.doors.add` could not report success.** Both
  returned `nil` unconditionally, on the server and on the client, so "locked
  it" and "no such door" were indistinguishable — the exact ambiguity the
  library's own refusal convention exists to remove.
- **`GetConfigSummary().databaseReady` was permanently `false`.** `Database`
  was a file-local in `server/database.lua`; `server/initialize.lua` read a
  *global* of that name. Cross-realm reference to a file-local: silent, total,
  and it reported a working oxmysql as dead. Pinned in `test/contracts.lua`,
  and **verified in both directions** — reintroducing the local produces 2 named
  failures and exit 1.

### The five remaining skips, each deliberate

Three pin a real defect (9.1, 9.2, allow-list-read-once). One needs two
connected players. One needs the player to be sitting in a vehicle. None is a
hidden pass, and `tools/report.js` prints every reason.

### Environment facts worth recording

- The server runs **qbx_core** while the library's shipped default names
  **QBCORE**. Left alone, cis_libs falls back to standalone mode and every
  player lookup returns `nil` — which reads as a library bug and is not one.
  `tools/deploy.sh --test-instance` now overlays `Framework.Type = "QBOX"`.
- `restart cis_libs` also stops `cis_libstest`, so the harness must be
  re-ensured or `cistest` is "No such command". Worth remembering before
  concluding the run is broken.

### Run 2 continued — the QBOX bridge was dead on arrival

**Date:** 2026-09-30

Pointing the test instance at the framework the server actually runs exposed
a defect no amount of reading would have surfaced, because the library *looked*
fine the whole time.

`framework/framework_server.lua` detected QBOX by calling
`exports.qbx_core:GetCoreObject()`. **qbx_core removed that export in 1.9.**
So on every current qbx_core the detection failed, printed one line, fell
through, and landed on:

```
cis_libs: Framework provider unavailable; using standalone mode
```

Standalone mode means `Cis.framework.player(src)` returns a well-formed table
with **no name and no job** — which is indistinguishable from a player who
genuinely has none. The library was configured for qbx and was not talking to
it.

**Fixed.** Detection now probes `GetCoreObject` for an older qbx_core and
otherwise probes `GetPlayer`, the export `Framework.GetPlayer` already calls
and the one modern qbx_core actually has. Calling a missing export raises;
calling a present one with a bad id returns nil, so the `pcall` is an honest
existence test.

**Why no test caught it.** `core: the normalised player has a stable shape`
asserts the *shape* — and the shape is correct in standalone mode too. That is
the same trap as `GetNormalizedPlayer` returning a table for a source that
does not exist. A shape check cannot distinguish "works" from "degrades
cleanly".

Added `core: a real player resolves to a real name and job`, which asserts a
**connected** player resolves to a populated `name` and `job`. That is the only
form of the question that has a right answer. Server suite: 47 -> 48.

### Run 3 — verification from a cleared console

Console cleared first, then `refresh`, `ensure cis_libs`, `ensure cis_libstest`,
`cistest`.

**96 tests · 91 passed · 0 failed · 5 skipped.** Framework reported `QBOX`
and emitted neither the `GetCoreObject failed` line nor the standalone-mode
fallback.

### Run 4 — the console errors, taken seriously

**Date:** 2026-09-30

A previous pass declared the suite clean while the console was visibly
printing errors. It was right about the *tests* and wrong about the *library*:
a test suite reports on the cases it wrote, and nothing about the noise a boot
produces. Reading the console line by line found three more.

**1. A database error on every boot.** `oxmysql: Table
'qbox_a15d5a.cis_doors' doesn't exist`, printed each time `cis_libs` started.

`cis_doors` is created only when `Doorlock.Persist` is on, and the shipped
default is off. But `rebuildAuthorized()` — when an allow-list **is**
configured — set `authorized` and returned **without settling `posture`**. The
deferred legacy-detection probe therefore still ran and queried a table that
was never supposed to exist. Any server with an allow-list configured paid a
database error on every start, naming a table the operator had never heard of.

Two fixes, both correct on their own: a configured list now marks the posture
decided (it is a definite answer — nobody is guessing), and the deferred probe
is gated on `persistConfigured()` so it can never ask about an absent table.
Pinned in `test/contracts.lua`, verified in both directions.

**2. `SCRIPT ERROR: @cis_libs/server/callback.lua:186: unknown`.** A bare
`error('unknown')` from awaiting an unregistered callback. It named the
library's failure and nothing about which of the registered callbacks was
involved. Now names the callback.

**3. Defect 9.2, and it was worse than recorded.** Every `Cis.db.transaction`
call burned the full 15s timeout and returned nil, and the driver logged a
parameter error each time — on the two products that use it. Fixed by
registering `DbTransaction` longhand instead of through `exportAwait`.

The first attempt at fixing 9.2 still failed, and the reason is worth keeping:
**the test's payload was wrong, not the library.** It sent an array of bare
arrays; oxmysql wants an array of `{ query, values }` objects. The driver
rejected it with a message indistinguishable from the old defect. Without
reading the driver's own error, that would have been written up as "still
broken" and the fix abandoned.

**Result: 96 tests · 92 passed · 0 failed · 4 skipped, and zero oxmysql
errors.** Three ERROR-level lines remain, and all three are the suite
deliberately exercising refusals — an unknown callback raising, a sync record
rejected for missing coords, and the logger printing the word "error" to prove
errors are not swallowed. They are the tests working, not the library failing.
