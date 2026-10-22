# Handoff — cis_libs "everything A" push

Written 2026-10-22 at the end of a cloud session, for picking the work up on a
local PC. Branch: **`cis-libs-a-grade`** (same commit as
`claude/vigilant-hamilton-3b0fva`, `e0561a2` + this handoff).

## Goal and ground rules

Make cis_libs the most secure, most optimized, most complete standalone
FiveM library — every area graded **A** by an independent audit — then
integrate the owner's own database system **last**.

- Standalone. No oxmysql, no ox_lib, no external runtime dependency.
- No `provide`.
- Every fix ships with a regression test that fails on the old code, a
  mutation row in `test/mutations.json` where it guards a real defect, and
  updated `api.lua` / generated types / docs / `CHANGELOG.md` ([Unreleased]).
- `npm run test:all` green before every push.

## Where things stand

| Area | Grade | State |
|---|---|---|
| Original audit defects (Phase 0) | — | All fixed and merged |
| Live-server CI job (Phase 1) | — | Built and merged; has never run on GitHub (see CI below) |
| Consumer-VM runtime (Phase 2) | — | Merged (`e0561a2`) |
| Built-in NUI + DX modules (Phase 4) | NUI **B** | Merged; re-audit findings **not fixed** |
| Server | **B-** | Re-audit findings **not fixed** |
| Client / consumer runtime | **B-** | Re-audit findings **not fixed** |
| Modules, tests, CI, docs | not graded | Re-audit was stopped before it reported |
| Database integration | — | Not started (by design, last) |

Test status at `e0561a2`: `npm run test:all` green (3050 Lua assertions,
web 47/47). Full mutation gate last ran on `8c47746` (the commit before the
Phase 2 merge): **248/248 killed, 0 survivors, 0 stale**. `mutations.json` now
has 288 rows — the 40 Phase 2 rows were run individually at merge time, but
**run the full gate once on the current HEAD** before trusting it.

## The work left, in order

The three re-audit reports are next to this file, unedited. Each ends with a
"What keeps it from an A" list — that list is the work.

1. **Client — [reaudit-client.md](reaudit-client.md).** Do the security items first:
   - `cis_libs:cb`, `cis_libs:cb:res` (client/callback.lua) and
     `cis_libs:client:syncBatch` (client/sync.lua) accept **local** forgeries:
     add the `source ~= ''` / `fromServer()` check (pattern in
     client/initialize.lua), and make pending keys random tokens instead of
     sequential (shared/pending.lua) on both realms. Bound the sync batch number.
   - Forged `onResourceStop`: every stop handler must check
     `GetResourceState(name) == 'stopping'`. Suggested shared helper
     `CisResourceStopping(name)`.
   - Callback name hijack, capability-slot squatting (also gate client-side
     registration: replicate the authorized-resource names in the client config
     payload), `RemoveNearWatcher` owner check.
   - Then correctness (vehicle windows, zones/points validation, restart
     re-registration, mirror clearing), native-argument fixes, performance,
     and the ox_lib parity gaps listed in the report.
2. **Server — [reaudit-server.md](reaudit-server.md).** Top items: `CommandAdd`
   ACE provisioning must only allow `group.*` principals and command names not
   already registered; net-binding owner from `GetInvokingResource()`; gate
   `RegisterCapability`; guard export lookups in callback `invoke`/`dispatch`
   so in-flight slots can't leak; rate-bucket eviction instead of
   refuse-then-kick; rate-limit before schema check; respawn backoff;
   collision-proof `nextId`; batch `push`.
3. **NUI — [reaudit-nui.md](reaudit-nui.md).** Top items: replace standalone
   `translate:`/`rotate:` CSS (needs Chromium 104; FiveM CEF may be 103 —
   check in game first); random NUI callback tokens + `e.source` check; input
   dialog stuck-focus paths; validate input answers in Lua as api.lua promises;
   icon names; ox-compatible textarea `min`/`max`; skill-check watchdog.
4. **Re-audit modules, tests, CI, docs** (shared/util, shared/algo,
   client/core, test/, tools/, .github/, README/DOCUMENTATION/CHANGELOG). This
   never finished; run it fresh, then fix its list.
5. **Merge + gate.** After all fixes: full mutation gate on HEAD
   (`npm run test:mutate`, ~tens of minutes), then an independent re-grade of
   every area. Repeat until every area is A.
6. **Database integration** — the owner's own DB system, standalone.

Overlap warning if you run fixes in parallel: the server fixes touch
`client/callback.lua` and `client/sync.lua` too, and so do the client fixes.
Do those two files in one stream, or sequence them.

## CI — read this before relying on GitHub

- **`main`'s workflows are broken.** They use `runs-on: ${{ env.RUNNER }}`,
  which GitHub rejects, so every run since ~Oct 6 failed instantly with zero
  jobs (the wall of red runs). This branch fixes both files (`ci: workflows
  that start…`, `771adda`), but `tests.yml` now triggers only on push to
  `main`, pull requests, nightly and manual dispatch — so nothing has run on
  GitHub since the fix. It needs a PR to `main` or a manual
  `workflow_dispatch` on this branch.
- **Live server tier** (`live-server` job; `tools/ci-fxserver.sh`,
  `tools/ci-live.js`) needs the **`FIVEM_LICENSE_KEY`** repository secret.
  Without it the job skips with a notice. Verified in the cloud container:
  pinned build 35245 downloads, SHA-256 matches, the key authenticates, all
  resources deploy. It then failed only because that container had IPv6
  disabled (FXServer opens its UDP socket as AF_INET6). GitHub runners and a
  normal PC have IPv6, so it is expected — not yet proven — to boot.
- Locally: `FIVEM_LICENSE_KEY=... npm run live:ci` (Linux/WSL). Never commit
  the key; `tools/ci-live.js` reads it from the environment only.

## Owner to-dos

- Add the `FIVEM_LICENSE_KEY` GitHub secret. The key was pasted in the cloud
  chat — **regenerate it** on the Cfx.re keymaster and use the new one.
- Decide `Toast` vs `Notify` for the notification export name.
- Licence decision (open question).
- Merge or PR this branch to `main` so CI actually runs.

## Useful commands

```
npm ci
npm run test:all            # the whole gate (lint, realms, both Lua runtimes, web, api, docs, package)
npm run test:mutate         # full mutation gate
node tools/mutate.js M12 M40 # just some rows
npm run gen-types           # after api.lua changes
npm run gen-natives         # needs tools/natives/natives_cfx.json and natives_gta.json (gitignored): download
                            # https://runtime.fivem.net/doc/natives_cfx.json and .../doc/natives.json (saved as natives_gta.json)
npm run live:ci             # real headless FXServer, needs FIVEM_LICENSE_KEY
```

Merge notes learned the hard way:
- Generated files (`types/cis_libs.lua`, `DOCUMENTATION.md` tables,
  `.luacheckrc`, `test/.luacheckrc`, `tools/natives/*.json`) — on conflict take
  either side and regenerate, never hand-merge.
- `test/mutations.json` ids collide when branches each add rows. Keep one
  side's ids, renumber the other side's new rows after the max id, and then
  run those rows.
- `tools/mutate.js` copies the working tree; don't edit files while it runs.

## Reference

- Original audit and plan (Claude Docs): https://claude.ai/artifact/AMbr8XhRsSfrbpgpVYoxAv
- `CHANGELOG.md` [Unreleased] lists everything this push changed.
- `test/live/RUNBOOK.md` — live harness, including the CI section.
