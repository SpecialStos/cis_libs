<!-- Independent read-only re-audit, 2026-10-23, of branch cis-libs-a-grade at c663d0d. Three auditors: (1) shared/util + shared/algo, (2) client/core + shared helpers, (3) tests, tools, CI, docs. Top findings spot-checked against the code before filing. Line numbers may be off by a few lines (the hooks.lua numbers in the second report were wrong; the code it describes is real). Scratch probes lived in the session scratchpad and are not preserved. NOT YET ACTED ON. -->

# Modules, tests, CI and docs re-audit

| Area | Grade |
|---|---|
| shared/util + shared/algo | **C+** |
| client/core + shared helpers | **C+** |
| Tests | **B** |
| Tools | **B+** |
| CI | **D** |
| Docs | **C+** |

`npm run test:all` was green at c663d0d. Counts: 3549 Lua assertions under fengari; 10 suites green under Lua 5.4; web 57/57; ci 25; api selftest 15/15. A line-coverage pass found only 3 of 2928 assertion lines that never run.

---

## 1. shared/util + shared/algo — C+

semver, cron, json, set, lru, ringbuffer and heap held up under edge-case probing, as did most of interp and curve. The checks covered:
- semver.org precedence;
- Vixie day-of-month/day-of-week OR semantics;
- leap days;
- depth caps;
- NaN refusal.

The grade comes from `random` and a set of cheap edge-case bugs. None of those cases has a test.

### HIGH
- **A-H1. Integer overflow in random ranges.** At random.lua:124-127, `n = hi - lo + 1` is computed before any check, and `gen:int` (about :207-219) does the same.
  - `integer(0, math.maxinteger)` always returns 0.
  - `integer(mininteger, maxinteger)` always returns mininteger.
  - `gen:int(0, maxinteger)` returns -1.
  - `gen:int(-2^62, 2^62)` returns a value above `hi`.
  - `integer(-1e300, 1e300)` raises, although the doc promises `nil, why`.
  - Fix: compute the span as a float (or with `math.ult`) before any arithmetic, and refuse spans wider than 2^53 with `nil, why`.
  - [verified]
- **A-H2. Seeded generators are linearly correlated.** The generator is MINSTD with the seed used linearly (random.lua:163-166, :189), so seed k's stream equals k × seed 1's stream, mod 1.
  - For seeds 1 and 2, `b == 2a mod 1` held on 1000 of 1000 draws.
  - Seeds 0 and 2147483646 give identical streams.
  - Fix: mix the seed with splitmix64, and preferably move to xoshiro.
  - [verified]

### MEDIUM
- **A-M1. `mathx.toHex(math.mininteger)` loops forever.** At mathx.lua:136-148, `-n` wraps back to a negative number, so `v` converges to -1 and never reaches 0. [verified]
- **A-M2. `mathx.round` gives wrong answers.** It uses `floor(a*m + 0.5)/m` (mathx.lua:37-41). [verified]
  - `round(0.49999999999999994)` returns 1.
  - `round(2^53+1)` changes the integer.
  - `round(mininteger)` returns +9.2e18.
  - `round(1.5, 400)` returns NaN.
  - Fix: return integers unchanged, compare `a - floor(a)` against 0.5, and cap `|d|` at 308.
- **A-M3. `mathx.approx` treats infinities and wrapped integers as equal.** All of these return true: `approx(inf, 1e308)`, `approx(inf, -inf)`, `approx(maxinteger, -1)` (mathx.lua:117-118). [verified]
- **A-M4. sparse.each misses elements, and add(NaN) corrupts the set.**
  - `sparse.each` loops over the live dense array (sparse.lua:128-131). A visitor that removes the current value skips later values and is handed nil. The doc promises every value present at the start.
  - `add(NaN)` raises after `size` has already been incremented (sparse.lua:63-65).
  - [verified]
- **A-M5. rate.prune frees a key the sliding limiter still blocks.** prune's default idle time is `windowSec` (rate.lua:343-357), but the ring still weights the oldest slice for one more slice. With 10 per 10 s and 10 hits at t=0, `prune(lim, 10)` lets 10 more through at t=10.
  - Fix: default idle to `windowSec + sliceSec`.
  - [verified]
- **A-M6. window.record with an earlier timestamp loses live samples.** It moves `lastBucket` backwards (window.lua:308-322). [verified]
- **A-M7. Schema `field` drops options the validators support.** [verified]
  - The string options lose `nonEmpty` (validate.lua:300-305).
  - `type='table'` ignores `min`, `max`, `of` and `nonEmpty` (:327-344).
  - `required` only means non-nil (:290-294), so `required` accepts `''`.
- **A-M8. Deep inputs raise instead of returning `nil, why`.** [verified]
  - `deepMerge` ignores `maxDepth` (table.lua:630-656), and a 300k-deep overlay overflows the stack.
  - validate's `copyTree` (:226-234) has no cycle guard.
- **A-M9. locale.t runs two formatting passes.** It substitutes `${name}` and then runs `string.format` on the result (locale.lua:178-185).
  - A substituted value containing `%` corrupts the positional arguments.
  - `%%` prints differently depending on how many arguments are passed.
  - [verified]
- **A-M10. Each timer pause/play spawns another sleeping thread.** `arm` runs `CreateThread`+`Wait(left)` on every play (timer.lua:62-80, 110-118). 500 cycles leave 501 threads. [verified]

### LOW
- **A-L1.** `levenshtein` with a cap returns the true distance instead of `cap+1` (418 of 20k random cases), and it does full O(la·lb) work. `suggest('FOO', {'foo'})` reports distance 3, above its own max of 2 (string.lua:389-475).
- **A-L2.** `heap.replaceTop(nil)` and `heap.build` with holes raise "compare number with nil".
- **A-L3.** `lru.put(c, nil, v)` raises. `removeWhere` crashes when the predicate removes the successor.
- **A-L4.** `cron.next` raises from `os.date` for a huge time or one before the epoch (on Windows). `matches(expr, 'abc')` and `matches(expr, NaN)` also raise.
- **A-L5.** `groupDigits(maxinteger)` is wrong because it formats through a float, and an invalid `decimals` raises.
- **A-L6.** `padStart('a', 2.5)` and `padStart('a')` raise.
- **A-L7.** `array.sum` wraps on integers, and `array.flat(cyclic, math.huge)` overflows the stack.
- **A-L8.** `window.new(math.huge)` makes `clear()` loop forever. `isSeen` and `prune` raise on a nil `now`.
- **A-L9.** class does not copy `__newindex`, `__index` functions or `__gc` to subclasses, so a read-only base becomes writable through a subclass.
- **A-L10.** Missing clamps:
  - `interp.ease` with t above 1 returns NaN for circ curves.
  - `clampLength(v, -1)` flips the vector.
  - `curve.pointAtXYZ(inf)` returns NaN with `ok=true`.
  - `mathx.clamp(NaN)` returns NaN.
- **A-L11.** `rate.newFixed{limit=0}` silently becomes limit 10, and a nil key raises.
- **A-L12.** id's uniqueness suffix pushes the result past `maxLength`.
- **A-L13.** `time.parseDuration` with a huge number returns inf.
- **A-L14.** After 8 rejections the random draw folds with bias, although the doc says unbiased. SUSPECTED.
- **A-L15.** The three clamps (mathx, interp, validate) disagree on reversed bounds and NaN.

### What keeps it from an A
A-H1, A-H2, A-M1, A-M2, A-M4, A-M7, A-M8, A-M5, A-M6, A-M3, A-M9, A-M10, A-L1, A-L4, A-L2, A-L3, A-L10, then the remaining lows.

---

## 2. client/core + shared helpers — C+

Every native in scope resolves against natives_{gta,cfx}.json with the right arity, argument order and client realm. Idle loops exit when there is nothing to do, streaming releases on timeout, DUI and scaleform release when the consumer stops, and zone, point and keybind removal is owner-checked.

### HIGH
- **C-H1. Infinite or huge coordinates hang the game thread.** [verified, 5e7-instruction abort]
  - `grid.checkAabb` rejects NaN but not ±inf (grid.lua:36-63).
  - For inf-inf, `cols` is NaN, so the cap check passes (:90-92). The cell loop is then a float loop with `cx + 1 == cx` (:70-71), which never ends.
  - Coordinates above about 6e20 hang the same way.
  - points.lua:43 and zones.lua:49 accept any number, although api.lua promises that infinity is refused.
  - Fix: refuse non-finite or off-map bounds (|v| > 1e5) in checkAabb, and in both `asVec3` functions.
- **C-H2. Zone event names let a consumer forge local events as cis_libs.** zones.lua:116-126 calls `TriggerEvent(eventName, …)` from cis_libs' own VM with whatever name the consumer chose. [verified with stubbed invoker semantics]
  - With `cis_libs:cache` the zone writes into every consumer's cache mirror, because mirror.lua trusts the invoker `cis_libs`.
  - With `onResourceStop` and a zone named `cis_libs`, `CisRealStop` passes (owned.lua:36-37). That despawns all sync entities, closes the UI and releases capabilities, points and keybinds.
  - Fix: refuse names starting with `on`, `__cfx_` or `cis_libs`. Better, require the `<owner>:` prefix.
- **C-H3. HookRemove has no owner check.** `CisHooks.remove(id)` (hooks.lua:77) removes any id, and ids are a global counter. A loop over 1..500 strips every resource's veto hooks. Zones, points and keybinds all refuse non-owners. [verified]

### MEDIUM
- **C-M1. HookRun iterates over the live list.** `CisHooks.run` loops `for i=1,#list` over the list itself (hooks.lua:55-75), so a hook that removes itself makes run raise, and one that registers a hook re-sorts the list mid-run. Fix: iterate over a copy, or copy on write. [verified]
- **C-M2. Zone `local = true` is ignored unless insideEvent is set.** It is only applied inside `if zone.insideEvent` (zones.lua:205-207), so `onEnterEvent` alone goes to the server. [verified]
- **C-M3. A NaN streaming timeout never expires.** `deadline = GetGameTimer() + (tonumber(timeout) or 5000)` (streaming.lua:146). It is reachable through `Cis.anim.play` opts.timeout. Fix: reuse raycast's `positiveMs` guard and add a cap. [verified]
- **C-M4. Zone shape inputs raise or make dead zones.** [verified]
  - Radius, heading and size are not checked, so a table radius or string heading raises.
  - A negative size, a 2-point poly or minZ > maxZ creates a zone that never contains anything.
- **C-M5. Vector type assumption.** Coordinate entry points accept `'vector3'`, `'vector4'` or `'table'` (points.lua:36-47, marker.lua, world.lua, zones.lua). The repo's skill claims `type(vector3) == 'userdata'`, while ox_lib checks `'vector3'`. Nothing live settles it. Fix: duck-type on numeric `.x/.y/.z` and add a live probe. SUSPECTED, and unverified either way.

### LOW
- **C-L1.** scaleform sends a half-built call when a typed param is unknown, and still returns true (scaleform.lua:243-271).
- **C-L2.** world: `'closest'..kind` raises on a nil kind, and queries allocate one table per entity per call.
- **C-L3.** ready runs waiters before setting `Cis.isReady`, so a waiter reads false.
- **C-L4.** detect uppercases a configured framework name before the started check (`ND_Core` becomes `ND_CORE`). Whether the runtime is case-sensitive is unverified.
- **C-L5.** The GetClosestPoint export is not owner-scoped and is O(n). Coordinates with no z raise.
- **C-L6.** Creating zones inside onEnter inserts into the bucket that `pairs` is walking.
- **C-L7.** raycast accepts `distance=inf`, and `fromCoords` does not check for NaN.
- **C-L8.** Keybind names can collide across consumers, because `RegisterCommand` is global while the byName guard is per instance. SUSPECTED.
- **C-L9.** `CisHooks.on` returns `nil, reason`, but api HookOn says `false, reason`.
- **C-L10.** ox_lib parity:
  - streaming polls every 50 ms;
  - vehicle queries do not exclude the player's own vehicle;
  - scaleform has no method that returns a value.

### Test gaps
- ±inf and huge coordinates.
- Forged zone event names.
- Hooks: a non-owner remove, a hook mutating the list during run, and `releaseOwner`.
- `local = true` with only enter/exit events.
- NaN streaming timeouts.
- Bad zone shapes.
- **`releaseAll` is never called by any test.**
- The ready flag as a waiter sees it.
- A real `vector3` through every entry point (live).

### What keeps it from an A
C-H1, C-H2, C-H3, C-M1, C-M2, C-M3, C-M4, C-M5, then C-L1 to C-L9.

---

## 3. Tests (B), Tools (B+), CI (D), Docs (C+)

### HIGH
- **T-H1. The mutation gate fails on HEAD: 8 rows are stale.** Their `find` text matches 0 times or 2 times:

  | Row | File | Matches |
  |---|---|---|
  | M08 | shared/registry.lua | 0 |
  | M70 | server/security.lua | 2 |
  | M93 | client/points.lua | 0 |
  | M119 | client/cache.lua | 2 |
  | M157 | server/callback.lua | 2 |
  | M192 | server/sync.lua | 0 |
  | M248 | init.lua | 0 |
  | M290 | client/core/mirror.lua | 0 |

  The `mutate` CI job and release.yml both fail on this. The 8 defects these rows were meant to guard are currently guarded by nothing. Fix: re-anchor the rows, then run the full gate. [verified]
- **T-H2. CI has never run in its current form.**
  - main still has `runs-on: ${{ env.RUNNER }}`, so every run since about 2026-10-01 fails in 0 s.
  - The fix exists only on this branch.
  - tests.yml triggers on push to main, PRs, nightly and dispatch, and there is no PR. So nothing shows the workflows parse on GitHub, let alone pass.
  - Fix: open a PR to main, or run `workflow_dispatch` on this branch. Owner action.
  - [verified]

### MEDIUM
- **T-M1. The Lua 5.4 driver passes a suite that exits early.** test/run.lua:157-183 counts only failed entries. A suite that calls `os.exit(0)` near its top shows "0 failed", while fengari reports FAIL. Fix: require `#TEST_CASES > 0` and a summary line. [verified]
- **T-M2. Assertion counts differ between interpreters.** The modules suite gives 732 under fengari and 734 under Lua 5.4, although run.lua:10-11 says the counts match. Fix: diff per-suite counts against an allow-listed delta. [verified]
- **T-M3. The examples gate is close to a tautology.** Only one README fence is tagged `lua example`, and that fence is an assert. No DOCUMENTATION example runs. Fix: tag the real examples and run them against init.lua with stubs. [verified]
- **T-M4. Actions are pinned by mutable tag, not by SHA**, in tests.yml and release.yml. [verified]
- **T-M5. The release job holds `contents: write` across untrusted steps.** checkout persists credentials, and the token sits in .git/config while npm ci and the tests run. Fix: `persist-credentials: false`, and a separate publish job.
- **T-M6. The release has no provenance.** The sha256 only goes to the log. There is no SHA256SUMS file, no attestation, and no check that the tag is on main.
- **T-M7. The version story does not add up.** [verified]
  - api.lua has 290 entries `since 1.0.0` and 105 `since 1.1.0`, while every version string says 1.0.0.
  - The CHANGELOG has [1.0.0] dated 2026-10-07, but no tag or release exists.
  - Nothing enforces `since <= version`.
  - Fix: decide the version (owner), then add a validate-api rule.
- **T-M8. README overstates CI.** It claims test:all runs on "every push" and that the live tier runs on "every pull request". There is no FIVEM_LICENSE_KEY secret, so the live tier always skips. RUNBOOK repeats the claim. [verified]
- **T-M9. DOCUMENTATION contradicts itself.** §1 (:59-61) says functions passed into exports arrive nil; :204, :1211 and :1249 say they arrive as funcrefs. [verified]
- **T-M10. CHANGELOG is missing upgrade information.** [Unreleased] has no Security section, no upgrade notes for the behaviour breaks and no compare links. There is also no ox_lib → cis_libs migration guide.

### LOW
- **T-L1.** Can't-fail assertions: client.lua:891 `check(env.EXPORTS and true or true, …)` and contracts.lua:2046 `check(true, …)`.
- **T-L2.** The test preload order is not the manifest's: histogram and ready are swapped, and shared/statebag.lua is never preloaded.
- **T-L3.** server.lua:2171-2173 prints FAIL lines mid-suite and again at the end, so failures are counted twice.
- **T-L4.** lint.js calls `process.exit` inside `try`, so the temp copy is never removed. %TEMP% holds 39 `cis-luacheck-*` directories.
- **T-L5.** docs-check:
  - It reads only 5 files.
  - Its export regex misses the dot form `exports.cis_libs:Name`, which DOCUMENTATION uses 33 times.
  - docs/archive links to a LICENSE.md that does not exist there.
- **T-L6.** syntax-check skips a whole file at its first backtick, so client/cache.lua is never parsed by it. Its header claims CI runs luac, which it does not.
- **T-L7.** mutate.js counts any non-zero exit as "killed", including a spawn error, and has no duplicate-id check.
- **T-L8.** The `test` and `mutate` jobs have no timeouts. The nightly run shares a concurrency group that a push to main cancels.
- **T-L9.** package.json `engines` says node >=18, but CI only runs Node 24.
- **T-L10.** docs/handoff/README.md is stale:
  - its counts and grade table predate this week's work;
  - "Licence decision (open question)" contradicts LICENSE.md (CSIL-1.0).

### Secrets
No finding in the repo:
- FIVEM_LICENSE_KEY is read from the environment only, removed from the child environment, and redacted from logs and artifacts.
- It is written to a 0600 secrets.cfg that is deleted at shutdown.
- The only `cfxk_` strings are test fixtures.

Owner action: rotate the key that was pasted into the cloud chat.

### What keeps each sub-area from an A
- **Tests:** T-H1, T-M1, T-M2, T-M3, T-L1, T-L2, T-L3
- **Tools:** T-M7 (`since` rule), T-L5, T-L4, T-L6, T-L7
- **CI:** T-H2, T-H1, T-M8, T-M4, T-M5, T-M6, T-L8, T-L9
- **Docs:** T-M7, T-M8, T-M9, T-M10, T-M3, T-L10, T-L5

---

## Proposed fix order

1. **Restore the gate.** Re-anchor the 8 stale mutation rows (T-H1), then fix the lua54 driver's early-exit hole (T-M1) and the count diff (T-M2), so every later fix lands on a working gate.
2. **client/core security.** C-H1 (the inf hang), C-H2 (zone event forgery), C-H3 and C-M1 (hooks), then C-M2 to C-M4.
3. **Algorithm and utility correctness.** A-H1 and A-H2 (random), A-M1 (toHex hang), then the other A-M items, then the lows.
4. **Test hygiene and tooling.** T-M3, T-L1 to T-L7.
5. **CI hardening.** SHA pins, a split release job, provenance, timeouts (T-M4 to T-M6, T-L8, T-L9).
6. **Docs.** T-M8, T-M9, T-M10, T-L10, T-L5. T-M7 waits on the owner's version decision.
7. **Owner actions.** Run CI on GitHub (a PR to main or workflow_dispatch: T-H2), decide the version, add and rotate FIVEM_LICENSE_KEY, and test whether `type(vector3)` is `'vector3'` or `'userdata'` on a live client (C-M5).
