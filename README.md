# cis_libs

A standalone FiveM library and framework bridge. It provides the pieces almost
every server rewrites — player state, callbacks, spatial zones, an inventory
bridge, a targeting bridge, door locks, entity sync, a database layer, and
logging — so your resource does not have to.

**It depends on no other library.** Not ox_lib, not PolyZone. It sits beside
ESX / QBCore / QBOX and normalises the differences, so you write against one API
and it does not matter which framework your server runs.

Version **1.0.0**. Requires OneSync and server build 4500+.
[MIT licensed](LICENSE.md) — the original author's name and the resource name
must be retained in all copies.

> **Read [DOCUMENTATION.md](DOCUMENTATION.md) before you write a line.** Almost
> every integration mistake comes from misunderstanding the resource boundary,
> and every one of those mistakes fails *silently* — wrong data, no error, no
> log line. Start at [§0, the rules that break code silently](DOCUMENTATION.md#0-rules-that-break-code-silently).

## Install

1. Put this folder in `resources`.
2. Add `ensure cis_libs` to `server.cfg` **before** resources that use it. A
   consumer that starts first will time out waiting for configuration.
3. Edit `configs/master_config.lua` to match your server — framework, inventory,
   target, database.

Consumers add one line to their manifest:

```lua
shared_script '@cis_libs/init.lua'
```

That sets a global `Cis` table. Hot reads (coords, ped) stay local to that VM;
mutations go through exports.

## Use

```lua
Cis.ready(function(ok)
    if not ok then return end

    -- Free: no boundary crossing.
    local coords = Cis.player.coords()

    -- Subscribe rather than poll.
    Cis.player.on('vehicle', function(current) print('in', current) end)

    -- A zone. Callbacks must be EVENTS, not functions: a function cannot be
    -- sent across the exports boundary, so onEnter would arrive nil and
    -- silently never fire.
    Cis.zones.sphere('marker', vector3(0.0, 0.0, 72.0), 3.0, {
        onEnterEvent = 'myResource:markerEnter',  -- (zoneName, x, y, z)
        onExitEvent  = 'myResource:markerExit',
    })
end)

RegisterNetEvent('myResource:markerEnter', function(zoneName, x, y, z)
    print(('entered %s at %.0f,%.0f'):format(zoneName, x, z))
end)
```

## Three rules that will save you time

An abridgement. Each is stated once, in full, with the measurement behind it, in
[§0](DOCUMENTATION.md#0-rules-that-break-code-silently).

1. **`exports['cis_libs']:Name(...)` — colon form only.** The bracket form
   shifts every argument one slot left and raises nothing. This bug lived in
   this library itself, in a form that silently corrupted every API call it had.
   The *lookup* `exports['cis_libs']['Name']` is unbound the same way, so a
   dynamically resolved handler loses its first argument too.
2. **A function can be handed back across the boundary, but not sent over.**
   Use the `*Event` options for every zone and proximity callback.
3. **Never `shared_script` a stateful file.** [§15](DOCUMENTATION.md#15-stateful-files--twelve)
   lists the twelve files that hold process-global state; duplicating one
   multiplies native work by your resource count.

The reasoning and the measurements behind all three are in
[§3, the boundary model](DOCUMENTATION.md#3-the-boundary-model).

## Documentation

| File | For |
|---|---|
| **[DOCUMENTATION.md](DOCUMENTATION.md)** | **Everything.** Boundary model, full API reference, recipes, security, configuration, the frozen contract, the complete export surface, known defects, troubleshooting, and a brief for migrating an existing resource |
| [LICENSE.md](LICENSE.md) | MIT, with a mandatory attribution notice |
| [cis_libstest](https://github.com/SpecialStos/cis_libstest) | The integration harness, in its own repository. `/cistest` on a running server writes a JSON report |

**Reading order, whether you are a person or an agent.** The long document is
ordered so that each section depends only on the ones before it:

| If you are… | Read |
|---|---|
| Integrating | [§0](DOCUMENTATION.md#0-rules-that-break-code-silently) rules → [§3](DOCUMENTATION.md#3-the-boundary-model) boundary → [§6](DOCUMENTATION.md#6-api-reference) API → [§7](DOCUMENTATION.md#7-recipes) recipes |
| Auditing a breaking change | [§10](DOCUMENTATION.md#10-the-frozen-contract) onward is the frozen contract and the 3.0 removal schedule |
| Reaching for a helper | [§20](DOCUMENTATION.md#20-the-utility-and-algorithm-layer) — 15 pure modules |
| Debugging | [§19](DOCUMENTATION.md#19-troubleshooting), then [§16](DOCUMENTATION.md#16-known-defects-pinned-not-fixed) so you do not file a known bug |

`api.lua` at the resource root is a machine-readable contract declaring the
public surface. It is plain data, it is not a script, and
`tools/validate-api.js` fails if it ever drifts from what the code actually
registers — the drift checks catch a renamed export, a changed parameter list, an
undeclared event, and a declared-but-missing export.

`api.lua` at the resource root is a machine-readable contract declaring the
public surface. It is plain data, it is not a script, and
`tools/validate-api.js` fails if it ever drifts from what the code actually
registers — the drift checks catch a renamed export, a changed parameter list, an
undeclared event, and a declared-but-missing export.

## Tests

```
npm install
npm test         # 397 assertions, no FiveM server required
npm run test:all # the above + a Lua syntax check + the api contract self-test
```

| Suite | Covers |
|---|---|
| `test/run.lua` | `shared/` — the spatial grid fuzzed against a brute-force reference over thousands of random points |
| `test/binding.lua` | The exports boundary: that arguments land in the right slots |
| `test/contracts.lua` | The declared surface vs the registered one, plus source-level pins on the fixes that are easy to silently undo |

The live integration suite needs a running server and a connected player, and
lives in [cis_libstest](https://github.com/SpecialStos/cis_libstest).

## Support

- Documentation: <https://docs.cisoko.net>
- Discord: <https://discord.gg/cisoko>
- Issues: <https://github.com/SpecialStos/cis_libs/issues>
