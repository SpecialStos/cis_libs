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

```lua
-- consumer fxmanifest.lua — both lines, always
dependency 'cis_libs'
shared_script '@cis_libs/init.lua'
```

Missing either is a self-check problem that presents as a logic bug. Do not
`shared_script` any other file from this resource: each Lua file is its own
chunk, and a second copy of the zone grid is an empty grid.

Call exports with a colon, never a bracket:

```lua
exports['cis_libs']:GetCapabilities()   -- yes
```

Indexing the exports table by name and calling the result feeds that table as
argument 1. Use the colon form.

## Example

```lua example
local caps = exports['cis_libs']:GetCapabilities()
assert(type(caps) == 'table')
```

Zone, point, hook, and callback handlers that cross the exports boundary cannot
be Lua functions. A function arrives `nil`. Use an event name or
`'resource:export'`.

```lua
Cis.zones.box('shop', { x = 1.0, y = 2.0, z = 3.0 }, { x = 4.0, y = 4.0, z = 3.0 }, {
    onEnterEvent = 'shop:client:enterShop',
})
```

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

Work on branch `cis_libs-2.2`. Do not push `main`. Do not tag.

```
npm test
npm run test:all
npm run test:mutate
```

`npm run live:run` stops `cis_libs` and kills client scripts for anyone joined.
After a `cis_libs` restart, they reconnect. Never log player names or IPs.

**Author:** Cisoko · **Docs:** <https://docs.cisoko.net> · **Discord:** <https://discord.gg/cisoko>
