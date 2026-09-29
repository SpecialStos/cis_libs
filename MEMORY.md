# MEMORY.md

What we know about FiveM's resource boundary, why `cis_libs` is shaped the way
it is, and the traps that cost us time. Everything here was **measured** on a
live server, not assumed — where something is still a guess it says so.

Read this before changing the API. The `self` trap in particular will silently
corrupt every call in the library and will not raise an error.

---

## 1. The `self` trap — the most important thing here

```lua
exports['cis_libs']:SomeExport(a, b)    -- CORRECT
exports['cis_libs']['SomeExport'](a, b) -- WRONG
```

The bracket form looks equivalent and is not. It yields an **unbound method**:
the exports table is expected as the first argument. Without it, every argument
shifts one place left.

`cis_libs` shipped this bug in `init.lua`'s `exportCall`, and it silently broke
the whole library:

| Sent | Received | Effect |
|---|---|---|
| `CisZonesCreate('box', name, coords, size, opts)` | `CisZonesCreate(name, coords, size, opts)` | zone **name** became its own **coordinates** |
| `RegisterCallback('x', handler)` | `RegisterCallback(handler)` | handler logged as the name |
| `Cis.zones.box(name, centre, size, {})` | kind=`name`, name=`centre` | create returned false, silently |

It only surfaced where a type check happened to catch it. Anything without a
guard — `Cis.doors.add`, `Cis.sync.*`, `Cis.db.*` — was receiving shifted
arguments and reporting nothing.

**The fix**, now in `init.lua`:

```lua
local EXPORT_TABLE = exports[RESOURCE]
local function exportCall(name, ...)
    return EXPORT_TABLE[name](EXPORT_TABLE, ...)
end
```

Passing the table explicitly is exactly what the colon syntax does.

**If you write dynamic export calls anywhere in your own resources, use the
colon form.** `lib.SomeExport(lib, a, b)` is the only safe dynamic equivalent.

---

## 2. What survives the boundary

Measured with a purpose-built probe (`cis_libstest`), then removed once it had
answered the question.

| Value | Result |
|---|---|
| Number, string, boolean | Preserved |
| Table (nested, arrays) | Preserved |
| `vector3` / `vector4` | Preserved |
| `nil` | Dropped — the key vanishes from a returned table |
| Multiple return values | **Collapsed to the first value only** |
| **Function as an argument** | **Dropped** |
| **Function as a return value** | Arrives as a **callable reference table** |

### The asymmetry: a function can be handed back, but not sent over

A returned function comes back as:

```lua
{ __cfx_functionReference = 'resource:line:col' }
```

and **it is callable** — verified with both `ref()` and `ref(ref)`.

**`type()` reports `table`, not `function`.** A `type(x) == 'function'` check
rejects a perfectly good handler. Check for `__cfx_functionReference` instead.
This bit us: we declared the remote-handler path impossible on the strength of
`type()` alone, and it worked all along.

**Open question:** a handler invoked *through* a reference table appears to run
(its side effects land, its arguments arrive intact) but its **return value may
come back as `nil`**. `cis_test:number` sets `seenNumber = 42` and returns `42`;
`seenNumber` is correct while the awaited return is `nil`. Suspect the reference
wrapper swallows the return. The harness now records the actual value instead of
asserting, so the next run settles it. If it holds, a remote handler must
communicate its result by side effect or via an event, not by return.

### What each direction means for the API

| You want | Possible? | How |
|---|---|---|
| Call a function in another **server-side** resource | **Yes** | Export it, register by `'resource:exportName'` |
| Get a function back (e.g. an unsubscribe handle) | **Yes** | It arrives callable |
| Pass a callback **in** to an export | **No** | It arrives nil |
| A `cis_libs` zone `onEnter` from a consumer | **No** | Use `onEnterEvent` |

---

## 3. The event relay (how callbacks work from a consumer)

Because a function cannot be sent over but a net event can, every callback
option has an **Event twin**:

```lua
-- inside cis_libs (or via a local helper) -- function form
Cis.zones.box('shop', centre, size, { onEnter = function(coords) end })

-- from another resource -- event form
Cis.zones.box('shop', centre, size, {
    onEnterEvent  = 'myResource:shopEnter',   -- receives (zoneName, x, y, z)
    onExitEvent   = 'myResource:shopExit',
    insideEvent   = 'myResource:shopInside',
})
RegisterNetEvent('myResource:shopEnter', function(zone, x, y, z) end)
```

Same for proximity watchers:

```lua
Cis.player.near(coords, 10.0, nil, nil, 'myResource:nearEnter', 'myResource:nearExit')
```

`CisCache.watchNear` returns `(unsubscribe, id)`; the unsubscribe handle crosses
as a callable reference.

**General rule for this codebase: exports return data, net events carry
callbacks.** If you find yourself wanting to pass a function into `cis_libs`,
you want an event name instead.

---

## 4. `shared_script` copies; it does not share

Each resource runs in its own Lua VM. A `shared_script` **copies** the file into
your VM. A consumer that loads `cis_libs/init.lua` gets a *proxy table*, not
access to `CisReadyState`, `Config`, `Globals`, or the zone grid.

Consequences:

- **Never** `shared_script '@cis_libs/client/cache.lua'`. You would get a second
  cache, a second 1s watchdog, a second `Globals`, and native calls multiplied
  by your resource count.
- The pure modules (`shared/grid.lua`, `pending.lua`, `histogram.lua`,
  `config.lua`) have **zero** native references, so a local copy is safe when
  you genuinely want one.
- Server-only and client-only globals are simply absent. Use the introspect
  exports: `GetConfigSummary`, `GetClientConfig`, `IsReady`, `GetLibsPrefix`,
  `InvokingAllowed`, `RateOk`.

---

## 5. Bugs we found and fixed

Recorded because the *reasoning* matters more than the diff.

### Critical

- **QBOX detection returned success on failure.** `provider = 'QBOX'` sat
  outside the `if ok and core` guard, so a failed `GetCoreObject` produced a
  library that reported ready while every player lookup returned nil. Same flaw
  in the QBCORE branch.
- **Client logging swallowed everything.** `Logging.Log` returned early for all
  levels when debug was off. Every `CisLog('error', ...)` — cache listener
  failures, zone callback crashes, sync model failures — was dropped in
  production. Now only DEBUG is gated. The server version was already correct;
  the asymmetry is what gave it away.
- **Dynamic entity sync recreated every entity every 2s.** The client handler
  did `despawn` then `spawn` unconditionally. Fixed by fingerprinting records
  server-side and moving the existing entity client-side when the model is
  unchanged. A model or kind change is the only thing that forces a respawn.
- **`SecurityReport` ignored the configured drop function.** `Security.DropPlayer`
  is a boolean and a `function` in the shipped config, but the code tested the
  boolean and called the global. The function was dead code.
- **`GiveMoney` returned `true` on failure** — the framework's result was
  discarded.

### Security

- **Callback keys were not bound to a player.** Keys are sequential integers, so
  a client could guess another player's pending key and resolve it with forged
  data. Keys are now bound to the player they were sent to.
- **`Security.AuthorizedResources` is read once at load** by `rebuildAuthorized()`
  in `server/security.lua` and is never rebuilt, so a runtime console change to
  the list is ignored. *(An earlier draft of this file claimed it was fixed;
  it is not. Verified against the source during Unit 0.1.)*
- `lastChange[src]` in the doorlock never cleared on disconnect (leak).

### Correctness

- **Vehicle seat read from the wrong array index.** `data['seatIndex'] or
  data.seatIndex or data[1]` — the first two are the same key, and `data[1]` is
  the *vehicle handle*. A "seat" of 1234567 was then cached permanently because
  the derivation only ran when the value was nil.
- **`Cis.callback.call` reinterpreted a numeric first argument as a player id**,
  so `Cis.callback.call('x', cb, 5)` silently became a client round trip. Split
  into `call`/`callClient`.
- **DB awaits could park a coroutine forever.** No timeout existed despite the
  README promising one. Now bounded by `Database.Timeout`.
- **Zone exits fired up to 32 units late** — the grid pass only ran after
  half a cell of movement. Added a cheap recheck of already-entered zones.
- **`aabbFromPoints({})` returned infinities** for an empty point list.
- **`Target.Remove` reported failure for successful removals** — `ox_target`'s
  `removeZone` returns nothing, and its return value was used as the success
  flag.
- **Discord queue was unbounded** and drained one message per 1.2s forever.

### Performance

- **`queryNeighbors` did 9× the work of `queryPoint` for an identical result.**
  Verified by fuzzing 3,000 random points against a brute-force reference: zero
  differences. Because `insert` registers an id in every cell its AABB
  overlaps, the single containing cell is provably sufficient. All three call
  sites moved to `queryPoint`.
- **The DrawText3D door loop called a cross-resource export every frame** to
  resolve the door mode. Now cached and invalidated on target resource
  start/stop.
- `lastApplied[vehicle]` grew forever; pruned for dead entities.
- The sync broadcast re-read every player's coords per record; now one pass.

---

## 6. Test harness lessons

`cis_libstest` is the instrument that found most of the above. Its own bugs are
worth recording, because **all four produced a suite that reported success
while testing nothing.**

1. **Shared context across tests.** Bodies received a *capture callback*
   instead of a context, so `check(ctx).equal(...)` evaluated on nil, `pcall`
   swallowed it, and the suite context (named `"server"`, status `passed`) was
   recorded 40 times. 77/84 "passed", none real. Fixed: one context per test,
   created and named *before* the body runs.
2. **`ok and nil or tostring(err)`.** When `ok` is true, `ok and nil` is nil, so
   the `or` branch ran and every *passing* test was reported as
   `failed / crash / "nil"`.
3. **Forward-declared locals shadowed by `local function`.** `local collect`
   followed by `local function collect()` creates two different locals; the one
   captured by an earlier handler stayed nil forever.
4. **Self-deception in my own tooling.** A scripted edit silently failed to
   match while printing success, and I told you the deployed file was stale. It
   was my change that never landed. **Verify edits with `grep`, not with the
   exit status of the script that made them.**

### The technique that actually worked

When behaviour was ambiguous, add a probe that returns what *actually* arrived,
and let the data speak:

- `EchoArgs('alpha', 7, true)` proved argument order was fine.
- `ProbeTypes()` proved functions return as callable reference tables.
- Returning `false, '<reason>'` from a refusal, and having the harness record
  it, turned `"name arrived as vector3"` into the `self` trap diagnosis in one
  run.

**When a test fails mysteriously, make the library explain itself before you
form a theory.** Every one of those probes was faster than the round of guessing
it replaced, and two of my theories were simply wrong.

### Telporting

Zone behaviour cannot be tested by polling a position — the player has to move.
The harness teleports with `SetEntityCoordsNoOffset`, waits two frames for the
cache, then polls `Cis.zones.contains`. `HOME` is captured once and restored
after every test so cases stay independent. Note this holds the client for
seconds at a time and will trip heartbeat-based anti-cheat
(`phylax_ac` did, twice) — run it on a test instance.

---

## 7. Still open

- **Zone callbacks from a consumer** now work via `onEnterEvent`, but there is
  no `Cis.zones.*` shorthand that hides the event wiring. Consider
  `Cis.zones.watch(name, { onEnter = 'myResource:fn' })` for ergonomics.
- **`GetFramework` returns a table of callable references.** It works, but by
  accident of implementation. Documented as not-an-API; `Cis.framework.*` is the
  supported path.
- **`Config.CheckVersion` phones home** to a personal GitHub Pages URL on every
  start. The remote file is stale (reports `Latest: 0.1.0` against `1.0.0`).
  Should default off.
- **Everything here has only run under `cis_libstest` on one server build.** The
  pure suite (`node test/run.js`, 105 assertions) covers `shared/` and the JSON
  encoder. Everything touching natives is integration-tested, not unit-tested.

---

## 8. Reference: what a refusal tells you

Every fallible call returns a reason as a second value, because a caller on the
other side cannot read our console:

```lua
local ok, why = Cis.zones.box('shop', coords, size, {})
-- why: 'zones disabled by config'
--      'name arrived as vector3'      <- the self trap, or a shifted call
--      'coords arrived as nil (the exports boundary dropped them)'
```

When something returns `false` for no visible reason, **print the second value
first**. It is almost always more informative than the stack trace.
