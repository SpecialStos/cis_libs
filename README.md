# cis_libs

**The shared boundary.** Zero-dependency. Free, always.

A server owner deletes libraries when they are unhappy. They cannot delete
their player records. `cis_libs` is the half of the CIsoko platform that
respects that line, and it respects it in a way the test suite enforces rather
than a README promises:

> No file this resource loads may contain a `CREATE TABLE`, an `INSERT INTO`, or
> a call to any third-party resource. Both are asserted in `test/contracts.lua`
> against every path in `fxmanifest.lua`, and the manifest is parsed to build
> that list — so the first person who adds one breaks the suite, not the promise.

It also owns no config file. `shared/defaults.lua` states the floor in code,
where it cannot be edited by accident, and a product hands over the real table
at boot.

## What is in the box

Zones, callbacks, entity sync, the client cache, spatial hashing, security
gating, logging, and 15 pure algorithm modules — curve fitting, interpolation,
LRU, heaps, rate limiting, sliding windows, sparse sets, interpolation, JSON,
semver, validation, time, table and string utilities.

## What it is not

It reaches no framework, runs no query and drives no target resource. Those are
products that plug in *behind* it:

| Resource | What it is | Price |
|---|---|---|
| **`cis_libs`** | This. The boundary: naming, marshalling, gating, primitives. | Free, always |
| **`cis_core`** | Platform services that hold data: framework abstraction, state, inventory service, config, migrations. | Free with purchase |
| **`cis_bridge`** | One adapter + one conformance test per third-party target. | Free with purchase |
| **`cis_keys`** | Doors, keys, PINs, guest passes, access ledger. | Paid, private |

## Install

```cfg
ensure cis_libs
ensure cis_core      # optional
ensure cis_bridge    # optional
```

With none of the products installed this resource still boots and still serves
zones, callbacks, sync, caching and logging. Run `cis_debug` in the server
console: it prints a capability table, one line per slot, naming the resource
that owns it or saying that nothing does. That table is the answer to "why is
the database nil", in one line, without reading any source.

## Use

One line in your manifest, unchanged since 1.0:

```lua
shared_script '@cis_libs/init.lua'
```

```lua
local ok, reason = Cis.zones.box('shop', vec3(1.0, 2.0, 3.0), vec3(4.0, 4.0, 3.0), {
    -- MUST be event names, not functions. A function cannot cross the
    -- exports boundary; it arrives nil and silently never fires.
    onEnterEvent = 'shop:client:enterShop',
})
if not ok then print(reason) end

local rows = Cis.db.query('SELECT * FROM properties WHERE owner = ?', { identifier })
```

Every `Cis.*` name and signature from 1.0 still works. Nothing about a
consumer's code changed when the platform was split — that was the constraint
the split was designed around.

## The three rules

1. **`exports['cis_libs']:Name(...)` — colon form only.** The bracket form is an
   unbound method and shifts every argument one slot left, raising nothing. This
   bug lived in this library itself.
2. **A function can be handed back across the boundary, but not sent over.** Use
   the `*Event` options for every zone and proximity callback.
3. **Never `shared_script` a stateful file.** Twelve files hold process-global
   state; `init.lua` is the only one meant for consumers.

## Requirements

OneSync on. Server build 4500+. MIT licensed.

## Tests

```
npm install
npm test          # 486 assertions, no FiveM server required
npm run test:all  # the above + a syntax check + the api contract self-test
```

`api.lua` at the resource root is a machine-readable contract declaring the
public surface. It is plain data, it is not a script, and
`tools/validate-api.js` fails if it ever drifts from what the code actually
registers — catching a renamed export, a changed parameter list, an undeclared
event, and a declared-but-missing export.

---

**Author:** Cisoko · **Docs:** <https://docs.cisoko.net> · **Discord:** <https://discord.gg/cisoko>
