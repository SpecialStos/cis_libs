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

**Not yet fixed.** No test accompanies this finding and no change has been made.

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

## Not covered by this run

The definition of done asks for more than this run achieved. Explicitly **not**
verified:

* **Two-client entity sync, with one client joining late.** This is the highest
  value item in the whole plan — the sync rewrite is the change most likely to
  need real entities in a real world — and it was **not** exercised. It needs two
  players connected.
* Zones, and callbacks in both directions, as observable behaviour.
* U1 — do function arguments survive the exports boundary as funcrefs? Not
  answered; it needs a two-resource, in-game test.
* A restart of each consumer while connected (the leak check). `cis_libs` was
  restarted and the server restarted, but with 0 players, so no per-consumer
  owned-record teardown was observed.

`cis_debug` was not captured in this run either: the txAdmin console input is a
terminal widget and neither `fill()` + `Enter` nor the history entry submitted a
command. A different input path is needed for that.