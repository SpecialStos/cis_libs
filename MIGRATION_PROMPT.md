# Migration prompt — rebuild resources onto cis_libs

Copy everything below the line into your agent. It is self-contained: the agent
needs no prior context from this conversation.

---

## Your task

We have a FiveM library called `cis_libs` in `resources/[standalone]/cis_libs`.
It replaces the things our resources each reimplement: player state, callbacks,
zones, inventory access, targeting, door locks, entity sync, a database layer,
and logging. It does not depend on ox_lib or PolyZone.

Rebuild our existing resources to use it properly, then verify the result.

**Read these two files before writing a single line of code.** They contain
behaviour that was measured on a live server, not assumed, and getting any of it
wrong produces silent corruption rather than an error:

- `cis_libs/MEMORY.md` — the traps, and the reasoning behind the API
- `cis_libs/DOCUMENTATION.md` — the full API reference and integration guide

You will also want `cis_libs/README.md` for the short version.

---

## Non-negotiable facts

These were each learned the expensive way. Violating any of them breaks code
without raising an error.

### 1. The `self` trap — read this twice

```lua
exports['cis_libs']:SomeExport(a, b)    -- CORRECT
exports['cis_libs']['SomeExport'](a, b) -- WRONG
```

The bracket form looks identical and is not. It yields an unbound method, so
the exports table is expected as the first argument. Without it, **every
argument shifts one place left**.

`cis_libs` shipped this bug itself. `Cis.zones.box(name, centre, size, {})`
reached the library as `Cis.zones.box(centre, size, {}, ???)` — the zone's
**name became its own coordinates**, and creation silently returned false.

If you must call an export dynamically, the only safe form is:

```lua
local lib = exports['cis_libs']
lib.SomeExport(lib, a, b)
```

Grep every `exports['cis_libs'][` in the codebase. There must be zero.

### 2. A function can be handed back, but not sent over

| Direction | Works? | Notes |
|---|---|---|
| Function as an **argument** | **No** | Arrives `nil` |
| Function as a **return value** | Yes | Arrives as a callable reference table |

`type()` reports `table` for a returned function, not `function`. Never test for
`'function'` when receiving one.

Consequence: **you cannot pass a callback into cis_libs.** Use the event forms
described below.

### 3. `shared_script` copies; it does not share

Each resource has its own Lua VM. Loading a `shared_script` copies the file in.

**Never** `shared_script '@cis_libs/client/cache.lua'` or any other stateful
file. You would get a second player cache, a second 1-second polling thread, a
second `Globals` table, and native calls multiplied by your resource count. This
is the single most damaging mistake available to you.

The pure `shared/` modules (`grid`, `pending`, `histogram`, `config`) contain no
natives and are safe to copy when you genuinely want a private instance.

### 4. Callbacks cross as net events, never as functions

Zone and proximity callbacks have a "Event twin" for exactly this reason:

```lua
Cis.zones.box('shop', centre, size, {
    onEnterEvent = 'myResource:shopEnter',   -- receives (zoneName, x, y, z)
    onExitEvent  = 'myResource:shopExit',
    insideEvent  = 'myResource:shopInside',
})

RegisterNetEvent('myResource:shopEnter', function(zoneName, x, y, z)
    -- ...
end)
```

Same for proximity:

```lua
Cis.player.near(coords, 10.0, nil, nil, 'myResource:nearEnter', 'myResource:nearExit')
```

### 5. Exports return data, not behaviour

Server-side handlers owned by another resource work by name:

```lua
-- in this resource
exports('myResource:handlePurchase', function(src, item, amount) ... end)
Cis.callback.register('purchase', 'myResource:handlePurchase')
```

Known caveat: a handler called this way runs and receives its arguments, but
its **return value may come back `nil`**. Signal results by side effect or an
event until that is resolved.

---

## What to hunt for

Grep the codebase for each of these. They are the work.

| Anti-pattern | Replace with |
|---|---|
| `CreateThread` + `Wait(0)` + `PlayerPedId`/`GetEntityCoords` | `Cis.player.coords()`, `Cis.player.ped()` |
| `Wait(0)` loops polling player or vehicle state | `Cis.player.on('vehicle', cb)` and friends |
| Custom "is player near X" loops | `Cis.player.near()` or `Cis.zones.*` |
| `ox_lib` / `PolyZone` imports and zone calls | `Cis.zones.box` / `.sphere` / `.poly` |
| Direct `exports.ox_inventory:GetItemCount` for reads | `Cis.inventory.count(item)` |
| `TriggerServerEvent` for request/response | `Cis.callback.*` |
| Per-frame `exports.ox_lib:...` or `exports.qb_*:...` | `Cis.*` equivalents |
| Custom entity-streaming threads | `Cis.sync.ped` / `.prop` / `.vehicle` |
| Per-resource framework branching (`if esx ... else qb`) | `Cis.framework.player(src)` |
| Custom door state tables + per-frame distance loops | `Cis.doors.add` / `.setState` |
| Own log prefix and level scheme | `Cis.log.debug` / `.info` / `.warn` / `.error` |
| `exports['cis_libs'][` (bracket form) | colon form — see fact 1 |

Also add, to each resource's manifest:

```lua
shared_script '@cis_libs/init.lua'
```

and gate startup on readiness:

```lua
Cis.ready(function(ok)
    if not ok then return end
    -- safe to use the Cis API from here
end)
```

`ensure cis_libs` must come before any resource that uses it in `server.cfg`.

---

## How to work

### Phase 1 — Audit (do this yourself, do not delegate)

Read every resource's manifest and Lua files yourself. Build a list: which
resources use cis_libs already, which use ox_lib or PolyZone, and which are
self-contained. This map drives the work and is wrong if you delegate it
without reading the code.

Produce a short written audit before changing anything. Note anything ambiguous
rather than guessing.

### Phase 2 — Migrate (delegate this)

**Split the work across sub-agents.** One agent per resource, or one agent per
concern (zones / callbacks / doors / sync) if a single resource is large. Run
them concurrently.

Each sub-agent prompt must include, verbatim:

1. The five non-negotiable facts above, in full.
2. The path to `cis_libs/MEMORY.md` and `cis_libs/DOCUMENTATION.md`, with the
   instruction to read them before writing code.
3. Exactly one resource or concern to handle, named explicitly.
4. The rule: do not edit `cis_libs` itself. If something looks missing or wrong
   in the library, report it back rather than patching it.
5. The rule: do not guess. If the API is ambiguous, read the docs, then say so.

Give each agent a disjoint file set so they cannot collide.

### Phase 3 — Verify (do this yourself)

Do not trust a green report from a sub-agent. Read the diffs.

Then, with a test server running:

```
ensure cis_libs
ensure cis_libstest
```

`/cistest` in the console or as admin runs both realms, teleports the player
around to exercise zone enter/exit, and writes a JSON report into the
`cis_libstest` folder. `node test/run.js` runs the pure unit tests with no
server.

**The teleport tests hold the player in place for seconds and will trip
heartbeat-based anti-cheat.** Run them on a test instance.

Anything the JSON reports as `skipped` was not verified. Say so explicitly
rather than counting it as a pass.

---

## Definition of done

- Zero occurrences of `exports['cis_libs'][` anywhere.
- Zero self-written `Wait(0)` loops that poll player, vehicle, or weapon state.
- Zero ox_lib or PolyZone imports left in migrated resources.
- Every resource's manifest has `shared_script '@cis_libs/init.lua'` and its
  startup is gated on `Cis.ready`.
- `node test/run.js` passes.
- `/cistest` runs with **zero failures**, and every remaining `skipped` is
  listed with the reason it was skipped.
- Anything deliberately left alone is stated out loud with the reason.

## Reporting back

Report: what changed per resource, what you deliberately did not change and
why, anything in `cis_libs` you believe is a bug (do not fix it), and the final
test result including every skip. If you are unsure about a decision, say you
were unsure rather than presenting it as settled.
