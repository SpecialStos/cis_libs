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
