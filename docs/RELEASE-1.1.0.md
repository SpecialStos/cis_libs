# cis_libs 1.1.0: draft release note

Draft for the owner. Paste the part below the line into the draft GitHub
release that the `v1.1.0` tag creates. Not shipped in the zip.

---

**cis_libs 1.1.0** is the free base library of the Cisoko platform: zones,
points, callbacks, secure net events, commands, keybinds, state bag sync and a
built-in UI (notify, text UI, progress, context, menu, radial, alert, input,
skill check), with zero runtime dependencies. No framework, ox_lib or oxmysql
is needed for cis_libs itself. Contract `api = 1`.

### Install

1. Download `cis_libs-1.1.0.zip` and `SHA256SUMS` below. Check the zip:
   `sha256sum -c SHA256SUMS` on Linux, or `Get-FileHash cis_libs-1.1.0.zip`
   in PowerShell and compare.
2. Unzip into `resources`. Keep the folder name `cis_libs` exactly.
3. In `server.cfg`, `ensure cis_libs` after your framework and `oxmysql`, and
   before every resource that uses it.
4. In the server console, `cis_doctor` prints `[cis_libs] self-check: ok`.

Needs OneSync and server build 4500 or later. Full steps: README.md § Install.

### What is in it

- **Secure by default.** Every client net event and callback is rate-limited
  and size-bounded, and checked against its schema when it has one, before
  your handler runs; names (callbacks, commands,
  keybinds, events, zones, sync records) belong to the resource that made
  them, and a forged stop event cannot release them. Door and sync writes are
  refused until you authorise a resource, and the console says how.
- **Idle at 0.002 to 0.005 ms per server frame**, measured with the FXServer
  profiler on Linux with no player and no consumer.
- **A first-party NUI** under a Content-Security-Policy, with a session token
  so no other page can drive or close it.
- **24 pure-Lua modules** (`Cis.require`): timers, cron, locale, semver, LRU,
  rate limits, easing, validation and more.
- **Coming from ox_lib?** `docs/MIGRATING-FROM-OX_LIB.md` maps the calls.

### Upgrading from 1.0.0

Read **Upgrading from 1.0.0** in CHANGELOG.md first: empty authorisation is
restrictive, several calls now answer `false, reason`, and names are owned.
Framework, inventory, target, door and database helpers still work but log a
one-time `deprecated` line; they move to cis_bridge and leave in 2.0.0.

### Tested

<!-- Filled at the release candidate 62ab3df (docs/V1.md sections 8 and 10).
     If the tag lands on a later commit, check these against its CI run. -->
- Full gate: 4250 assertions across 10 suites, Lua 5.3 (fengari) and a real
  Lua 5.4, on GitHub CI run 40125264420 (all 22 jobs green).
- Mutation gate: 732 known defects, every one caught by the tests (20 CI
  shards, 0 survivors).
- Live: boots with no script error on ESX, QBCore and Qbox test servers;
  `cis_doctor` ok; idle 0.002 to 0.004 ms per server frame; the cis_bridge
  conformance suite passes beside it on all three. The live suite with a game
  client connected: run-20261024-115302, pass 38, fail 0.

### Security

Report a vulnerability privately: Security tab, **Report a vulnerability**
(SECURITY.md). Do not post it publicly.

Licence: see LICENSE.md. Source-available, not open source.
