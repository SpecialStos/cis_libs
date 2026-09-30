# cis_libs

Standalone FiveM library and framework bridge. Other resources use it for player
state, callbacks, zones, inventory, targeting, doors, entity sync, database, and
logging. **It depends on no other library** — not ox_lib, not PolyZone. It sits
beside ESX / QBCore / QBOX and normalises the differences.

Version **1.0.0**. Requires OneSync and server build 4500+.

> **Read [DOCUMENTATION.md](DOCUMENTATION.md) first**, specifically *How the
> boundary works*. Almost every integration mistake comes from misunderstanding
> that one section, and the boundary rules there will silently corrupt your code
> — never an error, just wrong data.

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
| [**DOCUMENTATION.md**](DOCUMENTATION.md) | **Start here.** The integration guide — boundary model, every API function, recipes, and [Appendix A](DOCUMENTATION.md#appendix-a-brief-for-migrating-a-resource), a brief for migrating a resource |
| [**COMPATIBILITY.md**](COMPATIBILITY.md) | The frozen 1.x surface. What may not change until 3.0, and the defects that are pinned rather than fixed |
| [**cis_libstest**](https://github.com/SpecialStos/cis_libstest) | The integration harness, in its own repository. `/cistest` on a server, JSON report |

The `api.lua` manifest and the `tools/validate-api.js` checker that keeps it
honest are documented in `API_SPEC.md`, which moved to the project history
along with the rest of the internal notes.

## Tests

```
npm install
npm test            # 252 assertions, no FiveM server needed
npm run test:all    # the above + the api contract self-test + the matrix
```

The pure suite covers `shared/` and the exports-boundary contract. Everything
that touches a native is integration-tested by
[cis_libstest](https://github.com/SpecialStos/cis_libstest), which needs a
running server and a connected player.

## Three rules that will save you time

1. **`exports['cis_libs']:Name(...)` — colon form only.** The bracket form
   `exports['cis_libs']['Name'](...)` shifts every argument one slot left and
   raises nothing. This bug lived in this library itself. The *lookup*
   `exports['cis_libs']['Name']` is unbound in exactly the same way, so passing
   the table explicitly is the only safe dynamic equivalent.
2. **A function can be handed back across the boundary, but not sent over.**
   Use the `*Event` options for every zone and proximity callback.
3. **Never `shared_script` a stateful file.** `COMPATIBILITY.md` §10 lists the
   twelve files that hold process-global state.

Each is explained, with the measurement behind it, in
[DOCUMENTATION.md § How the boundary works](DOCUMENTATION.md#how-the-boundary-works).

## Support

- Docs: https://docs.cisoko.net
- Discord: https://discord.gg/cisoko
- License: [LICENSE.md](LICENSE.md)
