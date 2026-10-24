# cis_libs

A FiveM library. Zero runtime dependencies. Cisoko Community Source & Identity
License 1.0 (the folder must stay named `cis_libs`). Product **1.0.0**,
contract **`api = 1`**.

It is the shared boundary of the Cisoko platform: naming, marshalling, gating,
and primitives. It owns no database table, reads no config file, and never
calls a third-party resource by name. Products (`cis_core`, `cis_bridge`,
`cis_keys`) register into it. A server that runs this resource alone still
boots.

The machine-readable contract is [`api.lua`](api.lua). This README is the
install. Signatures live in [`DOCUMENTATION.md`](DOCUMENTATION.md), generated
from `api.lua`.

## Install

OneSync on. Server build 4500+.

```cfg
ensure cis_libs
```

```lua example
-- consumer fxmanifest.lua — both lines, always
dependency 'cis_libs'
shared_script '@cis_libs/init.lua'
```

Missing either is a self-check problem that presents as a logic bug. Do not
`shared_script` any other file from this resource: each Lua file is its own
chunk, and a second copy of the zone grid is an empty grid.

Call exports with a colon, never a bracket:

```lua example
exports['cis_libs']:GetCapabilities()   -- yes
```

Indexing the exports table by name and calling the result feeds that table as
argument 1. Use the colon form.

## Example

```lua example
local caps = exports['cis_libs']:GetCapabilities()
assert(type(caps) == 'table')
```

## Modules

Twenty-four pure-Lua modules (`Cis.requireList()` names them) load on demand
into the calling resource's own Lua state, with no global left behind:

```lua example
local semver = Cis.require('semver')
local ok = semver.satisfies('1.4.2', '^1.2')   -- true
```

| Need | Module |
|---|---|
| Translations from `locales/<lang>.json`, convar `cis:locale` | `locale` |
| Levelled console output, convar `cis:printlevel[:<resource>]` | `print` |
| Pausable timers, `setTimeout` / `setInterval` with cancellation | `timer` |
| Cron schedules (`*/15 9-17 * * mon-fri`, `@daily`) | `cron` |
| Classes with inheritance and private fields | `class` |
| Arrays with an explicit length, stable sort, groupBy, chunk, zip | `array` |
| Set, ring buffer, heap, LRU, sparse set | `set`, `ringbuffer`, `heap`, `lru`, `sparse` |
| Rounding, remap, hex, digit grouping, weighted pick | `mathx` |
| Case, split, fuzzy match, `random('1AA111')` | `string` |
| Seeded randomness, ids, semver, JSON, validation, durations | `random`, `id`, `semver`, `json`, `validate`, `time` |
| Easing, damping, splines, rate limits, sliding windows | `interp`, `curve`, `rate`, `window` |
| Deep copy, merge, sorted keys | `table` |

```lua example
local locale, print = Cis.require('locale'), Cis.require('print')
print.info(locale.t('shop.welcome', { name = 'Ana' }))

local cron = Cis.require('cron')
local job = cron.schedule('0 4 * * *', function() print.info('nightly cleanup') end)
```

Your own files load the same way: `Cis.require('client.utils')` reads
`client/utils.lua` from the calling resource and
`Cis.require('@other_resource/shared/config')` from another. Each file is read
once per Lua state, as text only, into its own environment; a circular require
raises and names the chain. The function reference is DOCUMENTATION.md §5.1.

Never `shared_script` a module file. `init.lua` is the only one.

## Handlers

Zones, points and keybinds made through `init.lua` run in **your** resource's
VM, so their handlers are plain functions and nothing crosses per frame
(DOCUMENTATION.md §5.2). They survive a cis_libs restart.

```lua example
Cis.zones.box('shop', vector3(1.0, 2.0, 3.0), vector3(4.0, 4.0, 3.0), {
    onEnter = function(zone) Cis.ui.textUI.show('[E] Shop') end,
    onExit = function(zone) Cis.ui.textUI.hide() end,
})
```

Hook and callback handlers still cross the exports boundary: use an event name
or `'resource:export'` there.

## Trust

Client asks, server decides. Mutating exports (`SyncCreate`, door writes, …)
consult `Security.AuthorizedResources`. An empty list is **always restrictive**
(1.0.0). A refusal names the fix:

```
cis_libs refused SyncCreate from my_resource:
  add 'my_resource' to Security.AuthorizedResources
```

`SetConfig(config, security, discord)` is first supplier wins. `cis_core` is
the intended supplier. A second caller is refused and told who already owns it.

Console: `cis_debug`, `cis_doctor`. Counts only, never player data:
`exports['cis_libs']:GetDiagnostics()` — pass `{ collect = true }` to run
`collectgarbage` in **this** resource before `memoryKb`. A collect in the
caller VM does not collect cis_libs.

## Docs

- [DOCUMENTATION.md](DOCUMENTATION.md) — how it works, generated signatures
- [CHANGELOG.md](CHANGELOG.md)
- [LICENSE.md](LICENSE.md)
- [test/LIVE.md](test/LIVE.md) — live run ids

Report a still-exploitable mutator bypass as a **private** GitHub security
advisory on this repository. Do not file a public issue for that.

## Development

```
npm ci
npm test              # every suite under fengari (Lua 5.3 semantics)
npm run test:all      # the full gate CI runs, including a real Lua 5.4
npm run test:mutate   # every known defect must break the suite
```

`npm run test:lua54` needs `lua5.4` on PATH (or `LUAC_LUA54`). Without one it
skips with a warning locally and fails when `CI` is set.

`npm run live:run` stops `cis_libs` and kills client scripts for anyone joined.
After a `cis_libs` restart, they reconnect. Never log player names or IPs.

## Testing

Three tiers, from cheapest to most real:

- **Stubbed** (`npm run test:all`, the `test` CI job on every pull request,
  every push to main and nightly): the suites under fengari and a real Lua 5.4
  against hand-written native stubs.
- **Live server** (the `live-server` CI job, started on every pull request and
  push to main but skipped until the secret below exists): a real headless
  Linux FXServer boots with cis_libs and the harness in `test/live/`, and runs
  the `server` and `lifecycle` tiers on FiveM's own natives. Any FAIL, script
  error or boot error fails the build. To turn it on, add a licence key from
  <https://portal.cfx.re> as the repository secret `FIVEM_LICENSE_KEY`
  (Settings → Secrets and variables → Actions). Without it the job is skipped
  with a notice, as it is for pull requests from forks. That secret is not set
  on this repository today, so the job skips on every run and CI does not
  exercise this tier yet.
- **Player** (`npm run live:run -- player`, by hand): zones, points, the debug
  draw, the client sync spawn path and the `perf` tier need a real game
  client, which CI does not have.

How each tier runs and what it does not cover:
[test/live/RUNBOOK.md](test/live/RUNBOOK.md#ci).

**Author:** Cisoko · **Docs:** <https://docs.cisoko.net> · **Discord:** <https://discord.gg/cisoko>
