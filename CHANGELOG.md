# Changelog

All notable changes to `cis_libs`. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

The **contract** is versioned separately and is still `api = 1`. Nothing in
2.2.0 changes a `Cis.*` signature, an export name, an argument order or a
return shape.

## [2.2.0] — unreleased

### Behaviour change

**An empty `Security.AuthorizedResources` is now always restrictive. There is
no legacy exception, and nothing is classified, inferred or written to disk.**

This is the one behaviour change in the release and the reason it is called out
first. Before 2.2.0 the empty list was resolved by asking the server about
itself: a marker file inside the resource folder, and a `dataProbe` capability
that reported whether the installed database held rows. A populated store meant
"legacy", i.e. permissive — so a resource that merely *had* a database was
granted the right to add, break and rewrite every door on the server.

Three separate ways that went wrong, all recorded as D-07:

- **An update silently downgraded security.** The marker lived inside
  `cis_libs/`, which is exactly where an update puts a new version. Replacing
  the folder deleted the operator's own record of their restrictive decision,
  and the missing file was then read as "nothing recorded" — so the install
  fell through to permissive. A restrictive install became permissive because
  it was *upgraded*.
- **The decision depended on somebody else's latency.** The `dataProbe` thread
  left the posture undecided for up to 30 seconds while a database answered,
  and undecided meant permissive. A store that was merely slow unlocked every
  door for half a minute on every boot.
- **A marker carrying the wrong flag was read as evidence of history.** Presence
  was read as "a written config exists", which meant legacy, which meant
  permissive — so the restrictive boot wrote a file whose presence made the
  *next* boot permissive.

The posture is now a pure function of the operator's own configuration, decided
at load. `cis_libs` writes no files and asks nobody.

#### Migrating

Nothing is required. A server that already configured
`Security.AuthorizedResources` is unaffected — an explicit list behaves exactly
as it always has.

A server that relied on the legacy/permissive path — that is, one with an empty
list and products mutating doors — will now see those refusals, and each refusal
names the resource and the exact key to add:

```text
cis_libs refused PublishJobUpdate from cis_migrate: add 'cis_migrate' to Security.AuthorizedResources
```

The old behaviour is still available, deliberately and loudly:

```lua
Security.AllowAnyResource = true   -- default false; warns on every boot
```

A named `AuthorizedResources` still governs when both are set, so the more
careful configuration is never the weaker one.

### Added

- `Security.AllowAnyResource` — the opt-in escape hatch described above.
  Validated as a boolean, default `false`, warned about on every boot while on.
- `GetLastRefusal()` — the reason for the most recent capability refusal made by
  **this** resource. A read refusal answers `nil`, and a `nil` first value
  truncates the return list at the exports boundary, so `nil, reason` is a shape
  that structurally cannot deliver an explanation. The reason travels out of
  band instead; no existing return shape moves. Scoped per calling resource,
  and cleared by the next successful call.
- `cis_audit [n]` and a `GetAuditLog(n)` export (task 3.9).

### Fixed

- **`cis_force_unregister` was open to any player.** The console command that
  strips a capability was registered without FiveM's restricted flag and
  ignored its source, so any connected player could revoke `security`,
  `database` or `framework` out of their own chat. It is now restricted,
  refuses a non-console source, and audits the attempt.
- **One resource stopping wiped every resource's sync records.** The
  `onResourceStop` handler reset the record table, the content index and the
  per-player sets for *any* resource. The drop was silent — a table going empty
  sends nothing — so every client holding another resource's synced prop kept
  it permanently, owned by nobody and despawnable by nobody.
- **`NotifyClient` and `Notify` disagreed about safety.** `NotifyClient`
  refused `src` 0 and −1 with a bare `false` and no reason while the rate limit
  one line below refused with one, and fired at a server id nobody was
  connected to while reporting success. `Notify`'s no-framework fallback had no
  guards at all, so the bounded path was the rarer one. Both now share one
  guarded delivery.
- **A pending callback outlived what created it.** A server-to-client await
  aimed at a player who had already left parked the caller for the full callback
  timeout. `playerDropped` now rejects that player's awaits at once with
  `player dropped`, and `onResourceStop` drops the stopped resource's own
  entries.
- **The zone debug drawing called two natives that do not exist**
  (`GetGameplayCamCoords` and `DrawText`), so `DrawText3D` raised on first call.
- **`server/selfcheck.lua` read a doubled path with `io.open`**, so its
  dependency check had never once reported anything.

### Removed

- The install marker (`configs/install.json`) and everything that read or wrote
  it. See the behaviour change above.
- The legacy/permissive classification and the deferred `dataProbe` probe.
  `dataProbe` remains a registrable capability slot for compatibility — a
  product that registers it is not refused — but nothing asks it anything.

### Fixed — documentation

- `reportRestrictive` cited "COMPATIBILITY.md section 6", which does not exist.
  The fix is now stated inline.