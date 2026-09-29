# cis_libs

Standalone FiveM library and framework bridge. Other resources use it for player
state, callbacks, zones, inventory, targeting, doors, entity sync, database, and
logging. **It depends on no other library** — not ox_lib, not PolyZone. It sits
beside ESX / QBCore / QBOX and normalises the differences.

Version **1.0.0**. Requires OneSync and server build 4500+.

> **Start with [MEMORY.md](MEMORY.md).** It is the entry point for the whole
> repository: what the resource is, where the work stands, and the boundary
> rules that will silently corrupt your code if you get them wrong.

## Install

1. Put this folder in `resources`.
2. Add `ensure cis_libs` to `server.cfg` **before** resources that use it.
3. Edit `configs/master_config.lua` to match the server (framework, inventory,
   target, database).

Consumers add one line to their manifest:

```lua
shared_script '@cis_libs/init.lua'
```

That sets a global `Cis` table. Hot reads (coords, ped, vehicle) stay in that
VM. Mutations go through exports on `cis_libs`.

## Use

```lua
Cis.ready(function(ok)
    if not ok then return end

    -- Hot reads are free. No boundary crossing.
    local coords = Cis.player.coords()

    -- Subscribe rather than poll.
    Cis.player.on('vehicle', function(current) print('in', current) end)

    -- A zone. Callbacks must be EVENTS, not functions: a function cannot
    -- cross the exports boundary.
    Cis.zones.sphere('marker', vector3(0.0, 0.0, 72.0), 3.0, {
        onEnterEvent = 'myResource:markerEnter',  -- (zoneName, x, y, z)
        onExitEvent  = 'myResource:markerExit',
    })
end)

RegisterNetEvent('myResource:markerEnter', function(zoneName, x, y, z)
    print(('entered %s at %.0f,%.0f'):format(zoneName, x, z))
end)
```

## Documentation

| File | For |
|---|---|
| [**MEMORY.md**](MEMORY.md) | **Start here.** Architecture, current state, everything learned |
| [**DOCUMENTATION.md**](DOCUMENTATION.md) | The integration guide — boundary model, every API function, recipes, and [Appendix A](DOCUMENTATION.md#appendix-a-brief-for-migrating-a-resource), a brief for migrating a resource |
| [**COMPATIBILITY.md**](COMPATIBILITY.md) | The frozen 1.x surface. What may not change until 3.0 |
| [**API_SPEC.md**](API_SPEC.md) | The `api.lua` machine-readable contract |
| [**BUILD_LOG.md**](BUILD_LOG.md) | Per-unit record: what changed, gate result, what went wrong |
| [**cis_libstest/**](cis_libstest/README.md) | Integration harness. `/cistest` on a server, JSON report |

## Tests

```
npm install
npm test            # 286 assertions, no FiveM server needed
npm run test:matrix # writes TEST_MATRIX.json covering every layer
```

The live integration suite needs a running server and a connected player. See
[`cis_libstest/README.md`](cis_libstest/README.md).

## Three rules that will save you time

1. **`exports['cis_libs']:Name(...)` — colon form only.** The bracket form
   `exports['cis_libs']['Name'](...)` shifts every argument one slot left and
   raises nothing. This bug lived in this library itself.
2. **A function can be handed back across the boundary, but not sent over.**
   Use the `*Event` options for every zone and proximity callback.
3. **Never `shared_script` a stateful file.** `COMPATIBILITY.md` §10 lists the
   twelve files that hold process-global state.

Each is explained, with the measurement behind it, in
[MEMORY.md §3](MEMORY.md#3-the-architecture-that-must-survive).

## Support

- Docs: https://docs.cisoko.net
- Discord: https://discord.gg/cisoko
- License: [LICENSE.md](LICENSE.md)
