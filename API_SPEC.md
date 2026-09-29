# API_SPEC.md — the `api.lua` contract format

**Applies to:** every `cis_*` resource that consumes or is consumed by
`cis_libs`, starting with `cis_libs` itself.

**Status:** normative. A resource that ships an `api.lua` is bound by this
document. A resource that does not is unaffected — nothing here changes how a
resource runs, only what a manifest may claim.

**Enforcement:** `tools/validate-api.js`, wired into
`.github/workflows/tests.yml`. Run it yourself with
`npm run test:api` and `npm run test:api-selftest`.

---

## 1. What `api.lua` is for

`api.lua` is a **pure-data declaration of a resource's public surface**, in a
form a machine can check against the source that actually implements it.

The problem it solves is narrow and real: a library's exported surface is
discoverable by reading it, but a *declared* surface drifts. A function is
renamed, a parameter is added, an export is added and forgotten. Nothing breaks
at the moment it happens. It breaks later, in someone else's resource, on a
live server, as a shifted argument that no type check catches — the same
failure shape as the `self` trap in `MEMORY.md` §1.

A manifest that is only ever written does not prevent that. A manifest that CI
compares against the source does.

**It is a contract, not a census.** It does not record which exports a given
consumer happens to call. That is `PRODUCT_USAGE.md` and `COMPATIBILITY.md`,
which are documentation and are allowed to be out of date. `api.lua` is allowed
to be out of date only if CI has gone red.

---

## 2. Hard requirements

### 2.1 Pure data

`api.lua` **MUST** be a single `return { ... }` expression containing only
strings, numbers, booleans, and tables of those.

It **MUST NOT** contain:

- any function, however harmless it looks;
- any call other than the single `return`;
- any reference to a FiveM native, to `exports`, or to another resource;
- any `require`, `dofile`, `os.*`, or `io.*`.

This is what makes it loadable without starting or executing the provider:

```lua
local api = assert(loadfile('resources/cis_libs/api.lua'))()
```

No fxserver, no started resources, no provider. The validator loads the file in
a bare Lua state with only the standard library, which is the same proof.

The validator rejects an executable value outright (`E000`), because a manifest
that can run code is a manifest nobody can read safely.

### 2.2 One file, at the resource root

Named `api.lua`, at the resource root, next to `fxmanifest.lua`.

**It is deliberately NOT listed in `fxmanifest.lua`.** Adding it as a
`shared_script` would execute it inside the resource's own VM and publish a
global that no consumer could reach anyway, because
`shared_script '@cis_libs/init.lua'` **copies** the file into the consumer's VM
rather than sharing it (`MEMORY.md` §4). There is no runtime benefit and one
more thing that can break at load. Read it on demand.

---

## 3. Shape

```lua
return {
    name    = 'cis_storeRobberies',
    version = '1.4.0',     -- the product's own version
    api     = 1,           -- contract major, an integer
    schema  = 0,           -- migration set id, an integer

    exports = {
        ['ExportName'] = {
            since      = '1.0.0',   -- required
            ['until']  = false,     -- `until` is a Lua keyword: bracket syntax
            stable     = true,
            deprecated = false,
            use        = 'the supported path a consumer should call',
            signature  = '(a, b)',
            realm      = 'server',   -- 'server' | 'client' | 'both'
        },
    },

    events = {
        ['cis_thing:event'] = {
            since   = '1.0.0',
            payload = '(what the arguments are, and which way they travel)',
        },
    },
}
```

### 3.1 Top level

| Key | Type | Required | Meaning |
|---|---|---|---|
| `name` | string | yes | The resource name. Must equal the folder name. |
| `version` | `MAJOR.MINOR.PATCH` | yes | The **product's** version. Independent of everything below. |
| `api` | integer | yes | The **contract major**. See `COMPATIBILITY.md` §3. |
| `schema` | integer | no | The **migration set id**. Defaults to `0`. See §3.4. |
| `exports` | table | yes | Export name → declaration. May be empty. |
| `events` | table | no | Event name → declaration. Omit if the resource uses none. |

### 3.2 Export declaration

| Key | Type | Required | Meaning |
|---|---|---|---|
| `since` | `MAJOR.MINOR.PATCH` | **yes** | The release that introduced the entry. |
| `until` | `false` or semver | no | The earliest major that may remove it. `false` (the default) = not scheduled. |
| `stable` | boolean | yes | `false` means the shape may still change within the same contract major. |
| `deprecated` | boolean | yes | `true` means kept, warned about, and scheduled for removal. |
| `use` | string | yes | What a consumer should call instead, or what the entry is for when it is not deprecated. |
| `signature` | string or table | yes | Parameter list. See §3.3. |
| `realm` | `server`\|`client`\|`both` | no | Where it is registered. Defaults to `both`. |

Two cross-checks the validator enforces, because they are the two ways a
deprecation goes wrong:

- `deprecated = true` **MUST** carry a non-empty `use` and a `until` major. A
  deprecation with no destination and no end date is a rumour, not a plan.
- `until` **MUST NOT** be earlier than `since`.

### 3.3 `signature`

A **parameter list**, written with the names the implementation uses:

```lua
signature = '(src, item, amount, metadata)'
```

The names are checked, not just the count. A rename is caught as drift — which
is deliberate, because `MEMORY.md` §1 is entirely about a name arriving in the
wrong slot, and a rename is how that class of bug starts.

When a name is registered in **both** realms with different parameter lists,
use the table form. This is common, not exotic: `Notify`, `InventoryCount`,
`InventoryHas`, `LogError`, `RegisterCallback` and `AutoLogError` all do it in
`cis_libs`.

```lua
signature = {
    server = '(src, message, kind)',
    client = '(message, kind)',
},
```

A table form is **required** when the two realms differ, and rejected when a
realm in `realm` has no entry — otherwise the missing half would pass silently.

#### How the validator knows the real signature

It reads it out of the source. For every file the resource's `fxmanifest.lua`
lists, it finds `exports('Name', <value>)` and resolves `<value>`:

| Form in the source | Resolved as |
|---|---|
| `exports('N', function(a, b) ... end)` | that function's parameter list |
| `exports('N', Name)` | `function Name(a, b)` in the same file |
| `exports('N', Tbl.Name)` | `function Tbl.Name(a, b)` in the same file |
| `exports('N', wrapper(x))` | the single `return function(...)` in the same file |

Anything else is reported as `unresolved` and **fails** under `--strict`, which
is the default. A signature nobody could check is not a signature anybody should
rely on, and a guess in a contract checker is worse than a hole because the
hole is visible.

`cis_libs` resolves 107 of 107 (52 server, 55 client).

### 3.4 The four independent numbers

Every resource carries four numbers that move independently. Conflating them is
the mistake this section exists to prevent.

| Field | Answers | Bumped when | Read by |
|---|---|---|---|
| `version` | *Which build of this product is it?* | Every release. | Humans, logs, the escrow record. |
| `api` | *Which contract major can it speak?* | Only on a breaking change to its public surface. | A consumer, to decide whether it can talk to it at all. |
| `schema` | *Which migration set does its stored data assume?* | When the on-disk or in-database shape changes. | Migrations. |
| `cis_min_libs` | *What platform floor does it need?* | When it starts using a newer `cis_libs` capability. | The installer and the boot check. |

A resource **MUST** carry all four. `cis_min_libs` lives in the resource's
`fxmanifest.lua` rather than in `api.lua`, because it is a property of the
build and not of the declared surface:

```lua
-- fxmanifest.lua
version       '1.4.0'
cis_min_libs  '1.0.0'
```

Rules:

- `api` is an **integer**, not a semver. `api = 1` means contract major 1.
- `schema` is an **integer**, not a version string. It is a set id, not an
  ordering: migration set 3 is not "more than" set 2 unless the migration graph
  says so.
- `cis_min_libs` is a **floor on `cis_libs`' `version`**, not on its `api`. A
  product may need a bug fix in `cis_libs` 1.2.0 without needing anything from
  contract major 2.
- Raising `api` **MUST** raise `cis_min_libs` to the `cis_libs` version that
  first shipped the new contract, and vice versa: a `cis_libs` that raises its
  own `api` **MUST** ship a `CHANGELOG` entry naming the consumer majors it
  still accepts.

---

## 4. Events

```lua
events = {
    ['cis_thing:event'] = { since = '1.0.0', payload = '(src, reason), server to client' },
}
```

`payload` **MUST** say which way the event travels and what the arguments are.
The direction is the part people get wrong: `cis_libs:cb` is the *same name in
both directions* with different payloads, and a consumer that reads the name
alone will mis-handle it.

### 4.1 Events with computed names

Five `cis_libs` events are **computed from `Security.EventPrefix`**:

```
${Security.EventPrefix}:doorlock:requestState
${Security.EventPrefix}:doorlock:updateState
${Security.EventPrefix}:doorlock:addDoor
${Security.EventPrefix}:doorlock:addDoorGroup
${Security.EventPrefix}:doorlock:doorBroken
```

**A consumer cannot hardcode these names.** The prefix is an operator setting
and it can be anything. A manifest therefore writes them with the literal
placeholder `${Security.EventPrefix}`, which is what `cis_libs/api.lua` does and
what the validator matches against.

A consumer that needs the real name reads it:

```lua
local prefix = exports['cis_libs']:GetLibsPrefix()          -- 'cis_libs' by default
RegisterNetEvent(prefix .. ':doorlock:updateState', handler)
```

This is not a stylistic preference. `cis_storeRobberies` calls
`AddDoorToSystem` and receives the resulting events, and on a server that
changed the prefix it would be listening on names that do not exist.

---

## 5. Validation

### 5.1 Running it

```bash
npm run test:api                        # api.lua against this resource
npm run test:api-selftest               # the validator against itself
node tools/validate-api.js --api path/to/api.lua --resource path/to/resource
node tools/validate-api.js --api api.lua --resource . --no-strict
```

Exit `0` clean, `1` findings, `2` usage error.

### 5.2 Checks

| Code | Fails when |
|---|---|
| `E000` | The file does not load, does not return a table, or contains an executable value. |
| `E001` | `name`, `version` or `api` missing or malformed. |
| `E002` | `exports` missing or not a table. |
| `E010` | An export has no `since`, or `since` is not `MAJOR.MINOR.PATCH`. |
| `E011` | `['until']` is neither `false` nor a semver, is before `since`, or is missing on a deprecated entry. |
| `E012` | `stable` or `deprecated` is not a boolean. |
| `E013` | `use` missing or empty. |
| `E014` | `signature` missing, malformed, or missing a realm the entry claims. |
| `E020` | `realm` is not `server`, `client` or `both`. |
| `E030` | **Declared but not registered** — the manifest promises an export the resource never registers. |
| `E031` | **Registered but not declared** — a working export nobody has taken responsibility for. |
| `E032` | **Signature mismatch** — the declared parameter list differs from the source. |
| `E033` | The signature could not be read from the source, so it could not be checked. |
| `E040` | An event entry is missing `since` or `payload`. |
| `E041` | An event is declared that no source file references. |
| `E042` | An event is used in the source but not declared. |
| `E050` | `fxmanifest.lua` lists a script that does not exist. |

`E030`, `E031`, `E032` and `E042` are the four drift checks. They are the
reason the validator exists; the rest are schema hygiene so that a manifest
which passes is worth reading.

### 5.3 The validator is itself tested

`npm run test:api-selftest` runs the validator against fixtures in
`test/api/broken/`, each of which is the **real manifest with exactly one thing
changed**, plus an `expect.txt` naming the diagnostic it must raise.

| Fixture | Change | Must raise |
|---|---|---|
| `missing-since` | `DbQuery.since = nil` | `E010` |
| `signature-mismatch` | `InventoryAdd` declared `(src, item)`, registered `(src, item, amount, metadata)` | `E032` |
| `phantom-export` | `TeleportPlayer` declared, never registered | `E030` |
| `undeclared-export` | `DbScalar` removed, still registered | `E031` |
| `missing-event` | `cis_libs:client:toggleDoor` removed, still used | `E042` |

Deriving each fixture from the real manifest is deliberate: it means the *only*
thing wrong with a fixture is the thing it is named for. A fixture that fails
for an unrelated reason — a typo, a stale signature elsewhere — would make the
self-test pass while proving nothing.

**A validator that has only ever been seen to pass has not been tested.** If a
fixture starts validating clean, the self-test fails: the check it exercises
has stopped working, and the fixtures are what noticed.

### 5.4 What the validator does not check

Stated plainly, so nobody assumes more than it does:

- **Return values and their shapes.** A manifest declares parameter lists, not
  results. `Cis.zones.box` returning `false, 'zones disabled by config'` is
  behaviour, documented in `DOCUMENTATION.md` and `MEMORY.md` §8, and not
  machine-checkable from the source.
- **Behaviour of any kind.** The validator reads names and parameter lists. It
  does not run the code.
- **Cross-resource compatibility.** It validates one resource's manifest
  against that resource's own source.
- **Whether a declaration is *true*.** It checks that the declaration matches
  the signature. A resource that registers `function Wrong(a, b)` and declares
  `(a, b)` passes. The manifest is a description of the shape, not a judge of
  the implementation.

---

## 6. Checklist for a new `cis_*` resource

- [ ] `api.lua` at the resource root, pure data, one `return`.
- [ ] `name`, `version`, `api` present; `schema` and `cis_min_libs` in the
      manifest.
- [ ] Every export declared, with a `since`, a `use`, a `signature`, and a realm.
- [ ] Every export the resource registers declared — `E031` will tell you.
- [ ] Every net event used, declared, with its direction in `payload`.
- [ ] Computed event names written with the `${...}` placeholder.
- [ ] `npm run test:api` clean.
- [ ] A broken fixture added if the resource introduces a new export *shape*.
- [ ] A `CHANGELOG` page, per `COMPATIBILITY.md` §10.
