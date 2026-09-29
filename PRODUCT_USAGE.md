# Product usage of `cis_libs` — the freeze baseline

**Date:** 2026-09-29
**Purpose:** brief §0.1a Decision 1 — "the freeze protects what the products actually depend on."
**Method:** source scan. `Cis.*` proxy calls and `exports['cis_libs']:Name` calls enumerated
from every product, then each symbol checked for existence against `cis_libs/init.lua`.
**Result:** **zero broken references.** Every symbol the products call exists.

---

## 1. The finding that changes the scope

**The deployed copies under `resources/[standalone]/` are stale and are NOT the baseline.**

| | Deployed `[standalone]/` | Source `Desktop/ZCode/` |
|---|---|---|
| `cis_storeRobberies` | 16 legacy export calls, **0** proxy calls | 5 export calls, **25** proxy calls |
| `cis_tcvs` | resource absent | 1 export call, **21** proxy calls |
| `cis_HawkEyeSurveillance` | **0** — does not touch cis_libs at all | 3 export calls, **21** proxy calls |
| `cis_BetterFightEvolved` | **0** | **0** — does not touch cis_libs at all |
| `cis_pacificBankRobbery` | **0** | no source copy found |
| `cis_paletoBankRobbery` | **0** | 0 in source |
| `realisticVehicleSystem` | **0** | no source copy (deployed-only name) |

Five of six deployed products show **zero** usage. The source copies show heavy proxy usage.
Anyone auditing the deployed tree would conclude the products barely depend on `cis_libs` — and
freeze an almost-empty surface. That would be wrong.

**Baseline decision: the source copies in `Desktop/ZCode/` are authoritative. The deployed tree
is a stale artefact and must be re-synced from source before the next release.** No commit in
this repository records that, which is itself worth fixing as part of Decision 3.

---

## 2. `cis_libs` declarations per product

Every product that uses the proxy declares it the same way:

```lua
shared_script '@cis_libs/init.lua'
```

`cis_tcvs`, `cis_storeRobberies`, `cis_HawkEyeSurveillance`, `cis_paletoBankRobbery`,
`cis_housing`, and `cis_phone` all do. `cis_BetterFightEvolved` does not, and correspondingly
makes no calls. The declaration and the usage agree everywhere — **no product is using the
proxy without declaring it**, so the freeze does not need to account for undeclared coupling.

---

## 3. The proxy surface actually consumed — 37 calls

| Call | Used by |
|---|---|
| `Cis.db.query` | tcvs · storeRobberies · HawkEye · phone |
| `Cis.db.single` | tcvs · storeRobberies · phone |
| `Cis.db.scalar` | tcvs · storeRobberies |
| `Cis.db.insert` | tcvs · HawkEye · phone |
| `Cis.db.update` | tcvs · HawkEye · phone |
| `Cis.db.transaction` | housing · phone |
| `Cis.log.debug` | tcvs · storeRobberies · HawkEye |
| `Cis.log.info` | tcvs · storeRobberies · HawkEye |
| `Cis.log.error` | tcvs · storeRobberies · HawkEye |
| `Cis.log.warn` | tcvs · storeRobberies · HawkEye |
| `Cis.player.coords` | tcvs · storeRobberies · HawkEye |
| `Cis.player.ped` | tcvs · storeRobberies · HawkEye · phone |
| `Cis.player.on` | tcvs · storeRobberies · housing |
| `Cis.player.serverId` | storeRobberies · HawkEye · housing |
| `Cis.player.vehicle` | housing |
| `Cis.player.weapon` | housing |
| `Cis.player.near` | storeRobberies |
| `Cis.framework.player` | tcvs · storeRobberies · HawkEye · phone |
| `Cis.framework.notify` | tcvs · storeRobberies · HawkEye |
| `Cis.inventory.add` | tcvs · storeRobberies · HawkEye |
| `Cis.inventory.remove` | HawkEye |
| `Cis.inventory.count` | housing |
| `Cis.inventory.has` | *one caller, unidentified* |
| `Cis.security.report` | tcvs · storeRobberies · HawkEye · phone |
| `Cis.net.on` | tcvs · storeRobberies · HawkEye · housing · phone |
| `Cis.streaming.model` | tcvs · storeRobberies · HawkEye · housing · phone |
| `Cis.callback.register` | storeRobberies |
| `Cis.doors.add` | storeRobberies |
| `Cis.doors.setState` | storeRobberies |
| `Cis.zones.box` | tcvs |
| `Cis.zones.poly` | tcvs · storeRobberies |
| `Cis.zones.sphere` | HawkEye · housing |
| `Cis.zones.remove` | tcvs · storeRobberies · HawkEye |
| `Cis.target.add` | storeRobberies · HawkEye |
| `Cis.target.remove` | storeRobberies · HawkEye |
| `Cis.sync.prop` | housing |
| `Cis.sync.remove` | housing |

**All 37 exist in `init.lua`. Nothing is called that does not exist.**

---

## 4. The export surface actually consumed — 7 calls

| Export | Called by | Note |
|---|---|---|
| `AddDoorToSystem` | storeRobberies | legacy door path, alongside `Cis.doors.add` |
| `LockDoors` | storeRobberies | legacy, alongside `Cis.doors.setState` |
| `GetFramework` | storeRobberies | |
| `GetGlobals` | storeRobberies | |
| `GetLibsPrefix` | HawkEye | |
| `GetConfigSummary` | *one caller* | |
| `RateOk` | *one caller* | |

**All 7 exist.** `cis_libstest` additionally exercises ~28 more (it is a test resource, not a
product, so it is excluded from the freeze surface).

The **deployed** `cis_storeRobberies` additionally calls `DrawText3D`, `CreateTarget`,
`RemoveTarget`, `GetPolyzones`, `LogDebug/Info/Error`, `GetClientLogging`, `GetLogging`,
`CheckResourceVersion`, `UnlockDoors` — all of which also exist. Nothing is broken in either
location.

---

## 5. API defined but never called by any product

Eleven proxy functions. **Not** candidates for removal in 1.x — they are documented surface and
the freeze protects it — but they tell you where the products' real needs are thin.

```
Cis.callback.call          Cis.callback.await          Cis.callback.callClient
Cis.callback.awaitClient   Cis.doors.get               Cis.player.heading
Cis.sync.ped               Cis.sync.vehicle            Cis.target.exists
Cis.target.update          Cis.zones.contains
```

Two readings, both worth knowing:

- **`cis_BetterFightEvolved` and `cis_pacificBankRobbery` consume nothing at all.** They are
  not protected by this freeze because they do not depend on `cis_libs`. Whether that is
  deliberate (they were never migrated) or accidental (migration was abandoned) is worth
  answering before Wave 1 assumes they are on the platform.
- **`Cis.player.near` is used by exactly one caller** (storeRobberies) and takes a callback
  that cannot cross the exports boundary. That call is almost certainly receiving `nil`
  callbacks today. It is the clearest candidate for migrating to the `onEnterEvent` form, and
  it should be treated as a live bug, not a working integration.

---

## 6. What this means for `COMPATIBILITY.md`

Unit 0.1 should document the full 52/55 export surface and all 50 proxy entry points, because
the freeze is about the published contract, not just observed usage. But it should mark:

- the **37 consumed** proxy calls and **7 consumed** exports as *exercised by production code*,
  with the caller list from §3 and §4;
- the remaining surface as *published but unexercised*;
- the five `:doorlock:*` events as **computed from `Security.EventPrefix`** and therefore not
  hardcodable by a consumer — `storeRobberies` calls `AddDoorToSystem` but cannot name the
  resulting events.

And it should carry the §1 caveat forward: `AddDoorToSystem`, `LockDoors`, `GetGlobals`,
`GetFramework`, and `GetPolyzones` are all compat shims. `storeRobberies` depends on five of
them. That dependency is real and is the strongest argument in the programme for keeping the
shims until 3.0 rather than retiring them on a use-count basis.
