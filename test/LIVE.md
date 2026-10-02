# cis_libs — live server smoke run

Recorded from a real running server, not from the fengari suite. The suite proves
contracts; this file records what a real FiveM runtime did.

**Run date:** 2026-10-01, 23:03–23:15 local
**Server:** `TEST-QBOX` (`[Qbox Project] TEST-QBOX`), txAdmin v8.1.1, FXServer b35245/Win
**Deployed from:** `origin/main` @ `0896c2d`, copied to
`txData/Qbox_A15D5A.base/resources/[standalone]/cis_libs`
**Player count during the run:** 0 (the run happened with nobody connected — see
"Not covered" at the bottom)

---

## What was verified

### 1. Deployment

The working tree was copied over the previous deployment after removing it. Ten
load-bearing files were checksum-verified byte-for-byte against the repo
(`shared/algo/random.lua`, `shared/util/semver.lua`, `shared/algo/sparse.lua`,
`shared/ready.lua`, `shared/grid.lua`, `shared/algo/window.lua`,
`shared/util/id.lua`, `shared/algo/interp.lua`, `fxmanifest.lua`,
`server/security.lua`, `server/callback.lua`, `server/initialize.lua`,
`shared/config.lua`, `init.lua`) — all match.

### 2. Boot — PASS

After a full server restart, `cis_libs` starts clean:

* `cis_signal` install check reports `[ok] cis_libs is running` and
  `[ok] receiver positions survive a restart`.
* 104 resources started; 18 of them `cis_*`; `cis_libs` present throughout.
* **All 11 `could not find client_script/server_script` warnings are gone**, and
  so are the 4 `attempt to index a nil value (global 'CisDefaults'/'CisRegistry'/'CisOwned'/'CisNetOn')`
  boot errors. Zero `cis_libs` load failures.

### 3. OPERATIONAL GOTCHA — `restart` does not re-read fxmanifest.lua

This cost real time and is worth writing down.

`restart cis_libs` re-runs the resource's Lua but **does not re-parse its
manifest**. The manifest FiveM used was the one cached at boot, three hours
earlier, which still listed eleven files that had since moved to `cis_core`
(`client/inventory.lua`, `framework/framework_client.lua`,
`configs/master_config.lua`, `server/discord.lua`, …).

The symptom looks exactly like a broken deployment:

```
[ resources:cis_libs] Warning: could not find client_script 'client/inventory.lua'
                      (defined in fxmanifest.lua:86)
[ script:cis_libs] SCRIPT ERROR: @cis_libs/shared/config.lua:148:
                    attempt to index a nil value (global 'CisDefaults')
```

The tell is the **line number**: it cites `fxmanifest.lua:86` and `:103`, while
the deployed manifest is 139 lines with `client_scripts` at 113 and
`server_scripts` at 130. A line number that does not match the file on disk means
FiveM is using a cached manifest, not that your files are missing.

The four `CisDefaults`/`CisRegistry`/`CisOwned`/`CisNetOn` nil-index errors are
the same cause and not independent faults: the stale manifest loaded a different
script set in a different order, so the globals did not exist yet.

**Rule: after changing fxmanifest.lua, restart the SERVER, not the resource.**
A resource restart is enough only when the manifest is unchanged.

---

## Finding 1 — cis_libs raises on a consumer net event whose export is absent

**This is a defect in cis_libs, not in the consumers.**

29 distinct missing exports across 6 resources produce a SCRIPT ERROR each:

| resource | occurrences |
|---|---|
| cis_signal | 24 |
| cis_evidence | 24 |
| cis_medic | 20 |
| cis_dispatch | 7 |
| cis_electricity | 5 |
| cis_keys | 4 |

Representative trace:

```
[script:cis_libs] SCRIPT ERROR: @cis_libs/server/security.lua:525:
                  No such export handleFile in resource cis_dispatch
[script:cis_libs] > libExport   (@cis_dispatch/shared/platform.lua:103)
[script:cis_libs] > netOn       (@cis_dispatch/shared/platform.lua:314)
[script:cis_libs] > register    (@cis_dispatch/server/net.lua:169)
[script:cis_libs] > fn          (@cis_dispatch/server/boot.lua:48)
```

`server/security.lua:525`, in `CisNetOn`'s string-form handler resolution:

```lua
self = exports[resource]
handler = self and self[exportName]
```

The guard is on `self`, which protects against a resource that is not running.
It does **not** protect against an export that is missing from a resource that
*is* running: indexing a FiveM resource export proxy with a name the resource
does not export **raises**, it does not return nil. So the line the guard was
written to make safe is exactly the line that throws.

Consequences:

* Every boot of a server with any of these consumers prints errors. Support cost
  is the stated priority for this platform, and this is the shape of thing that
  becomes "cis_libs is broken" in a customer report.
* The consumer has no way to know registration failed. `CisNetOn` throws out of
  the consumer's own boot path, so the consumer's remaining registrations in that
  file may not run.

This is the cross-repo contract drift the audit's X-1 anticipates ("a drift like
the `count`/`Count` mismatch found in this audit then fails CI in the provider's
repo"). Here it is caught on a live server instead of in CI, and it should be
fixed on the cis_libs side first: a missing export is a refusal with a reason,
not an exception.

**FIXED AND VERIFIED LIVE** (commit `ca74685`, "L-S26: a missing export is a
refusal, not a raise"). The lookup is now under `pcall`, and the message names
the resource and the export instead of reporting `not string` for a string.

Measured on this server, restarting `cis_libs` plus five consumers:

| | before | after |
|---|---|---|
| errors | 97 `No such export` in the log | 97 — **zero new** across 308 fresh lines |
| message | `SCRIPT ERROR: @cis_libs/server/security.lua:525: No such export handleState in resource cis_medic` | `[ERROR] Cis.net.on("cis_medic:server:state") registered nothing: resource "cis_medic" does not export "handleState". Check the name, and that the resource is started.` |
| the consumer | raise escapes into its boot | `cis_medic ready. platform: cis_libs` · `[ok] cis_libs is running` |

That last row is the whole point. The consumers now reach `ready` instead of
being interrupted, and a refusal names the reference rather than aborting.

**The underlying mismatch is still there** — `cis_medic` genuinely does not
export `handleState`, and neither do `cis_signal`, `cis_evidence`, `cis_keys` or
`cis_electricity` for the names they register. That is a contract question for
those resources, not for this one, and it is exactly what Phase 8.1 / X-1 is
for. What changed is that cis_libs now *reports* it instead of crashing on it.

---

## Finding 2 — one cross-repo ordering fault, pre-existing

```
[script:cis_core] SCRIPT ERROR: @cis_core/framework/framework_server.lua:
                  attempt to index a nil value (global 'CisDetect')
[script:cis_libstest] SCRIPT ERROR: @cis_libs/shared/config.lua:148:
                  attempt to index a nil value (global 'CisDefaults')
```

Both are load-order faults in resources outside this repo (cis_core, and
cis_libstest — the old integration harness, which vendors cis_libs files and is
no longer maintained). `cis_libstest` in particular should not be running on a
server being used to test cis_libs: it loads `@cis_libs/shared/config.lua` into
its own script environment, where `CisDefaults` does not exist.

---

## cis_debug — the slot contract, as reported on the live server

Captured at 23:15:53, after the clean restart. This is the output the
definition of done asks for ("`cis_debug` shows every slot `resolved` with no
`missing:` lines"). It does not, and the reason is not cis_libs.

```
[cis_libs] ready=true jobs={"police":0}
[cis_libs] client payload has secrets: false
[cis_libs] --- capabilities ---
[cis_libs]   dataProbe          cis_keys         resolved
[cis_libs]   database           -                no provider installed
[cis_libs]   discord            -                no provider installed
[cis_libs]   doors              cis_keys         resolved
[cis_libs]   doorsClient        -                no provider installed
[cis_libs]   framework          -                no provider installed
[cis_libs]   inventory          cis_core         resolved
[cis_libs]   inventoryProvider  -                no provider installed
[cis_libs]   migration          -                no provider installed
[cis_libs]   security           cis_core         resolved
[cis_libs]   target             -                no provider installed
[cis_libs]   qbx_core: started
[cis_libs]   qb-core: started
[cis_libs]   es_extended: missing
[cis_libs]   oxmysql: started
[cis_libs]   mysql-async: started
[cis_libs]   ghmattimysql: started
[cis_libs]   mongodb: missing
[cis_libs] configuration supplied by: cis_core
```

**4 resolved, 8 with no provider installed.** Every unresolved slot belongs to
cis_core or cis_bridge, neither of which has had its phase started:

| slot | who owes it | plan item |
|---|---|---|
| framework | cis_core | C-1 / C-2 |
| inventoryProvider | cis_bridge | B-4 |
| database | cis_bridge | B-1 |
| target | cis_bridge | B-4 / B-5 |
| migration, discord, doorsClient | cis_core / cis_bridge | C-6, B-13 |

So the "no `missing:` lines" gate cannot pass until Phases 6 and 7 exist. cis_libs
is reporting this accurately, which is the behaviour the gate depends on.

Three things this run does confirm about cis_libs itself:

* `ready=true` — the ready gate settles, and `CisReadyState` is healthy
  (the L-S16 work from this session behaves on a real server).
* `client payload has secrets: false` — the L-C22 client-payload work holds; the
  config pushed to clients carries no secrets.
* The security posture is enforced and explains itself. `cis_keys` is correctly
  **refused** door mutation, with the fix named:
  `[x] this resource may mutate doors on cis_libs` /
  `fix: Add "cis_keys" to Security.AuthorizedResources in cis_libs's
  configs/security_config.lua`. That is L-C1 and L-C2 working: the operator's
  allow-list is read, enforced, and a refusal says what to change.

Detection is also healthy: qbx_core, qb-core, oxmysql, mysql-async and
ghmattimysql all report started; es_extended and mongodb report missing, which
is correct for this server.

---

## U1 — ANSWERED. Functions DO cross the exports boundary.

The audit asked this as an open question ("unverified", § Features U1): do
function arguments survive the exports boundary as funcrefs? If they do, the
`type(x) == 'function'` checks reject working callables and DOCUMENTATION §3.2 is
wrong.

**Answer: they do, and they work.**

Measured with a purpose-built probe resource (`cis_u1probe`, still on the server
under `[standalone]`) that exports a receiver and calls its own export passing a
function. Measured, not inferred:

```
function argument: type=table  tostring=table: 0b8ab04fbe3a362d
function argument: rawget __cfx_functionReference = cis_u1probe:16687:2 (type string)
function argument: cis_libs isCallableRef would say: true
function argument: CALLING the value -> ok=true res=I am a function that crossed

FUNCTION ARG: plain index ok=true  res=cis_u1probe:16687:2
FUNCTION ARG: rawget      ok=true  res=cis_u1probe:16687:2
```

So a function argument arrives as:

* `type(v) == 'table'`, **not** `'function'`;
* carrying `__cfx_functionReference`, a string like `cis_u1probe:16687:2`;
* **fully callable** — `v()` returned "I am a function that crossed".

It is *not* indexable for arbitrary fields: `v.probe` raises
`Cannot index a funcref`. That is a property of the funcref, not a broken
callable.

A table argument crosses completely intact, function fields included — the
control `{ probe = fn, tag = 'control' }` arrived with `probe()` still callable.

### What this means

**DOCUMENTATION §3.2 is wrong.** It currently says "A function can be handed
back, but not sent", and shows `Cis.zones.box('shop', centre, size,
{ onEnter = function() ... end })` as NEVER WORKING because "onEnter arrives nil
and silently never fires". That is not what this runtime does. A function passes
through, in a direct argument and inside a table.

**The library is right, and was already right.** `server/security.lua:471`,
`server/callback.lua:33` and `client/callback.lua:33` each accept both a bare
function and a callable reference table — and the probe confirms
`isCallableRef` returns true for a real crossed function. The audit's worry is
already mitigated, and the comments saying "Measured: a function RETURNED from an
export arrives as a callable reference table" describe exactly what was observed.

A hypothesis that this run **disproved**, worth recording so nobody re-raises it:
`security.lua` spells the predicate `rawget(v, '__cfx_functionReference')` while
both `callback.lua` files spell it `v.__cfx_functionReference`, and the security
comment warns "both must agree or a handler registered one way is refused the
other". Since a funcref raises `Cannot index a funcref` on an absent field, plain
indexing looked like it would break. It does not: `__cfx_functionReference` is a
field the funcref actually provides, and plain index and `rawget` return the same
string. The two spellings agree on a real server.

**Caveat, stated rather than glossed:** the probe resource called its OWN export.
Cross-RESOURCE behaviour may differ, and the specific path §3.2 documents — an
`onEnter` inside an options table going through `init.lua`'s proxy — is still not
directly verified, because that needs a second resource with a real zone on it.
What is established is the mechanism; what remains is one call site.

---

## Consumer restarts — no leaks, no stacking (L-C7 / L-C8)

Two full rounds of `restart` over `cis_libs`, `cis_signal`, `cis_evidence`,
`cis_keys`, `cis_medic` and `cis_electricity` — twelve restarts in total.

| | round 1 | round 2 |
|---|---|---|
| `No such export` raises | 0 | 0 |
| cis_libs refusals logged | 22 | 22 |
| consumers reaching `[ok] cis_libs is running` | 5 | 5 |

Equal counts across rounds is the point. L-C8 fixed `RegisterNetEvent` APPENDing
a fresh handler on every registration, which meant a resource restarted a few
times turned one client action into a burst of identical error lines. Stacking
would show here as round 2 reporting twice round 1. It reports the same.

The 22 refusals each round are the same registrations being refused once per
boot, because the underlying contract mismatch still exists and is now reported
rather than raised. One per registration per boot is correct; one per restart
per registration would be the leak.

## Not covered by this run

The definition of done asks for more than this run achieved. Explicitly **not**
verified:

* **Entity sync, in any form.** This is the highest value item in the whole plan —
  the sync rewrite is the change most likely to need real entities in a real
  world — and it was **not** exercised at all, because no real client is
  connected. `players.json` reports `id 0`, empty `identifiers` and `ping 0`,
  which is the FiveM server-list placeholder rather than a player: a connected
  client has a non-zero id, identifiers and a real ping. A probe resource was
  written and deployed to ask the client what `GetSyncedEntities()` returns; it
  produced no output at all, because there is no client VM to run it in.

  The create side was deliberately not attempted from that probe: it would have
  been refused. `server/sync.lua` calls `CisInvokingAllowed()` before any work,
  and the probe is not on `Security.AuthorizedResources` — which is the D2/L-C1
  posture behaving exactly as designed, confirmed from the other side.

  The probe resource (`cis_u1probe`) has been removed from the server.
* Zones, and callbacks in both directions, as observable behaviour.
* U1 — ANSWERED, see above. The specific `onEnter`-in-an-options-table
  path through init.lua is still unverified: that needs a second resource.
* A restart of each consumer while connected (the leak check). `cis_libs` was
  restarted and the server restarted, but with 0 players, so no per-consumer
  owned-record teardown was observed.

`cis_debug` WAS captured — see the section above. Getting a command into the
txAdmin console needs one non-obvious step: the input is a plain `<input>`, and
`fill()` followed by `press("Enter")` silently does nothing — the text lands and
stays. The value must be filled, the input **clicked**, and only then `Enter`
pressed. A command that "did not run" here is indistinguishable from one that ran
and printed nothing, so the log file is the only trustworthy check that a console
command actually executed.
---

# Run 2 — 2026-10-02, native-semantics probe

**Run date:** 2026-10-02, 13:05 local
**Server:** `Vanilla` (`[FiveM Basic Server] Vanilla`), txAdmin v8.1.1, FXServer **b35245**/Win
**Deployed from:** working tree @ `939d2ba` (+ the `resolve` fix committed after it)
**Player count:** 0 — see "What this run did NOT cover"
**Probe resource:** `resources/[standalone]/cisprobe` (kept; writes `probe-results.txt`)

## Why this run exists

The fengari suite can only test this library against **fakes**. Three of the
fixes in this batch depend on how a real CitizenFX runtime actually behaves, and
every one of them was previously "verified" against a stub that agreed with the
bug:

* `Citizen.Await` returning ONE value rather than two, and a rejection raising
  rather than returning a second value — which is why every `await`/`awaitClient`
  dropped its results and reported refusals as successes;
* `GetInvokingResource()` being nil for an in-VM call, which is what makes the
  S1 owner fallback safe rather than a hole;
* `exports[res][name]` **raising** rather than answering nil for a missing
  export.

So a probe resource was deployed and asked directly. It writes its verdict to
`probe-results.txt` as well as the console, because the txAdmin console is a
rendered terminal widget and reading it back programmatically is unreliable —
the file is the copy that can be diffed.

**Result: 11 passed, 0 failed.**

## Verbatim results

```
Await(resolve(a,b,c)) -> n=1  [1]=first [2]=nil [3]=nil
PASS  Q1 Await returns exactly ONE value (the first resolve arg)   n=1
Await(rejected) -> pcall ok=false err=refused
PASS  Q2 a rejection RAISES, carrying the reason (pcall catches it)   ok=false err=refused
GetInvokingResource() called internally -> nil
PASS  Q3 GetInvokingResource is nil for an in-VM call   got nil
GetPlayerRoutingBucket exists = true
PASS  Q4 GetPlayerRoutingBucket is a callable server native
GetPlayerRoutingBucket(1) with nobody online -> ok=true value=0
PASS  Q5 invalid-src behaviour recorded (not asserted)   ok=true value=0
PASS  Q6 cis_libs is started   started
PASS  Q7 a cis_libs export is callable from another resource   ok=true type=table
RegisterCapability("discord","cisprobe:Evil") -> ok=true why=nil
recorded owner of slot "discord" = cisprobe
PASS  Q8 the slot owner is the CALLING resource, not the provider string
RegisterCapability("migration","cis_core:FakeMigrate") -> ok=true
recorded owner of slot "migration" = cisprobe  (the string CLAIMED cis_core)
PASS  Q9 a forged provider string does NOT become the owner   recorded cisprobe
GetDiscordConfig() from cisprobe -> 0 key(s)
PASS  Q10 a foreign caller gets an EMPTY webhook table (S2)   0 keys
SetConfig from cisprobe -> false
PASS  Q11 a bad config is refused by the validator (H1)   got false
```

## The two that matter most

**S1, end to end, across a real exports boundary.** `cisprobe` registered the
`migration` slot with the provider string `cis_core:FakeMigrate` — naming a
resource it does not own — and the slot was recorded as owned by **`cisprobe`**.
Before the fix the recorded owner was the CLAIM, so the row read `cis_core` and
the conflict check compared a claim against a claim. The console line agrees:

```
[cis_libs] [INFO] cis_libs: capability "migration" <- cisprobe
```

**The probe found a bug nothing else had.** Q8/Q9 initially read `false` for the
owner instead of a string. That was the probe's own `pcall` masking a RAISE:
`GetCapabilities` was throwing `No such export FakeMigrate in resource cis_core`,
because `resolve` read `exports[res][name]` unguarded and `snapshot()` resolves
every slot to fill in `resolved`. One dead provider therefore broke the one
command whose entire job is to report which capability is missing. Fixed in
`0d5fad6`; the raw snapshot dump below is the after state, and note it answers
rather than raising, with `resolved=false` and the owner still reported:

```
--- raw GetCapabilities() ---
  ok=true type=table
  [discord] type=table owner=cisprobe resolved=false
  [migration] type=table owner=nil resolved=false
  ...
```

## Confirmed-not-changed

`AimingCheckType`, `UpdateInterval` and the rest of H1 were exercised only on the
server side (Q11). `SetVehicleExtra`'s `disable` semantics (C5) and the routing
bucket default (Q5) are client-side or need a connected player, so those remain
verified against the native declarations, not against a running client.

## What this run did NOT cover

Still unverified, exactly as in Run 1:

* Anything needing a connected client — entity sync end to end, vehicle extras,
  zones, and the client half of callbacks. `players.json` reports the server-list
  placeholder, not a player.
* The six-slot `cis_debug` table with products installed. A vanilla server has no
  cis_core/cis_bridge, so every slot is correctly `resolved=false`; the *shape*
  is verified (the snapshot dump above), not the conformance of real providers.

## Operational notes (txAdmin, repeated because they cost time again)

* A resource added to disk after boot is invisible until `refresh` is issued.
  Without it the console answers "Couldn't find resource cis_libs" for a resource
  that is sitting in the right folder.
* The console input must be **clicked** after filling before `Enter` is pressed;
  `fill()` + `press("Enter")` leaves the text sitting in the box. Already noted
  in Run 1; hit again here. **Confirm every command from the output, never from
  the absence of an error** — a command that did not run looks exactly like one
  that ran and printed nothing.
