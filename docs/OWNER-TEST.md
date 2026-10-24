# cis_libs v1: owner test

Written 2026-10-24 for branch `cis-libs-a-grade`. Takes about 15 minutes per
server. The agent cannot do this part: the VPS has no GPU, so only a real
client can read client resmon and see the UI.

## 1. What changed tonight

Commits on `cis-libs-a-grade` since 00:00, newest last in each group. The full
list is `CHANGELOG.md` [Unreleased]; the decisions taken for you are in
`docs/V1.md` section 7.

- **The v1 surface is written down** (`docs/V1.md`): what is frozen, what is
  deprecated, the bars and their evidence.
- **Deprecation.** The slots and detection that move to cis_bridge and cis_core
  (framework, inventory, target, doors, database, dataProbe, migration, and the
  `Detect*` exports) still work, and log one warning per calling resource. They
  are removed in 2.0.0, after cis_bridge stops using them.
- **Security.**
  - On the client, a forged resource start can no longer replay another
    resource's registrations into cis_libs. The server has no such guard
    yet (D26).
  - A callback's echoed key is bounded (64 characters).
  - Every `SecureNetOn` event's payload is bounded before its schema runs: 32
    arguments, 4096-byte strings, 256 entries, depth 8.
  - Schemas refuse infinity and can ask for `integer`.
  - The bad-payload report re-arms after a quiet period instead of staying
    silent.
  - `SetConfig`'s `security` table is merged over the defaults. A supplier
    that leaves out `DropPlayer` keeps kicks on (D14).
- **NUI.** The page's `escape` and `ready` messages carry a session token the
  page gets from Lua, so another page cannot close or re-initialise the UI.
- **Server idle.** The server zone pass runs only while a zone exists, so an
  idle server no longer wakes cis_libs every 500 ms for it. The restrictive
  warning says the list is empty once, not twice.
- **Utilities.** The shared util and algo fixes from the re-audit (A-M2 to
  A-M10, A-L1 to A-L15 in `CHANGELOG.md`). Two change behaviour a consumer can
  see: `mathx.clamp` refuses reversed bounds and NaN (D15), and `locale.t`
  formats whenever an argument is given (D16).
- **Tooling** (no in-game effect): cis-lint (static checks for the Cisoko
  rules), real test assertions, CI actions pinned by SHA, release checksums,
  and a mutation gate that counts only a test failure as a kill. The gate now
  runs on GitHub CI as 20 shards of at most 45 minutes each.
- **Second wave, after the first owner-test pin.**
  - The NUI page runs under a Content-Security-Policy and in strict mode, and
    every NUI callback validates its payload and answers.
  - A context menu option may fire only its own resource's events
    (`<resource>:*`); `cis_libs:*`, `__cfx_*` and the resource start/stop
    events are refused. Anything else goes through `onSelect`.
  - Progress bar props are local objects, not networked entities.
  - `CommandAdd` grants ACEs only to the groups in the convar
    `cis_command_ace_groups` (default `group.admin`), and never revokes one
    (D24).
  - A forged `onResourceStop` no longer releases another resource's
    registrations on the server (D25).
  - Sync, context, radial, target and near-watcher records belong to the
    resource that made them; another resource cannot change or remove them.
  - `RateOk` keeps separate buckets per calling resource, so a consumer cannot
    spend the budget of cis_libs' own net events.
  - A menu, dialog or radial the page refuses (over the NUI message cap)
    releases focus and the player's controls.

## 2. What the agent already proved

At commit `d7dcebb` the release zip booted on all four VPS servers with no
`SCRIPT ERROR`, `cis_doctor` printed `self-check: ok`, and the server profile
showed cis_libs at 0.002 to 0.005 ms per frame with no player and no consumer
(`docs/V1.md` section 10, third run). The `cis_test` live suite passed with
your PC connected (run-20261024-115302: pass 38, fail 0). At the 1.1.0
release candidate `62ab3df` the same zip booted again on `esx`, `qbcore` and
`qbox` with no `SCRIPT ERROR`, `self-check: ok`, 0.002 to 0.004 ms per frame,
and `cis_bridge test` passing beside it (`docs/V1.md` section 10, fourth
run). What is left is client resmon and how it looks and feels: that is this
test.

## 3. Before you start

cis_libs `62ab3df` (`d7dcebb` on `cis_core`) and the test consumer
`cis_libs_ownertest` are installed in `resources/[cis]/` on every server, but neither is in `server.cfg`, so a server
restart leaves both stopped. Nothing in `server.cfg` was changed.

On your PC, check that no agent is using the VPS (no output means free):

```bash
ssh CisFiveM 'ls /tmp/cis-agent-vps.lock 2>/dev/null'
```

Then, for the server you are testing (`esx` shown; use `qbcore`, `qbox` or
`cis_core` for the others), run these four lines in order:

```bash
ssh CisFiveM 'fivem-switch esx'
```

```bash
ssh CisFiveM 'fivem-status'
```

Run it again until its output has a line `health: health ok` (alerts and the
last log lines print after it), then:

```bash
ssh CisFiveM 'fivem-console refresh; fivem-console ensure cis_libs; fivem-console ensure cis_libs_ownertest'
```

```bash
ssh CisFiveM 'fivem-logs 40 | grep -E "Started resource cis_libs|SCRIPT ERROR"'
```

Expected: `Started resource cis_libs` and `Started resource cis_libs_ownertest`,
and no `SCRIPT ERROR`. The yellow `SECURITY: door and sync mutations are
REFUSED` block is expected: no resource is authorised yet.

To keep cis_libs running across restarts, add this line to that server's
`server.cfg`, after the framework and `oxmysql` and before any resource that
uses cis_libs. It is your call; the agent did not add it.

```cfg
ensure cis_libs
```

### Enable resmon first

A FiveM client on the normal (Release) update channel refuses `resmon 1` with
"Command resmon is disabled in production mode", and F8 cannot change that.
Pick one, then restart FiveM:

- Add `+set moo 31337` to the end of the FiveM shortcut's Target field, after
  the closing quote of the path. Or:
- In FiveM Settings, set the update channel to Beta or Latest.

Source: citizenfx `ConsoleHostGui.cpp` lines 1024-1040 and 1205-1207 at
`46de79b`.

## 4. In game, on each server

Do this on `esx`, `qbcore`, `qbox` and `cis_core`. The steps are the same on
each; only the framework around them changes.

1. **Connect and spawn.** Finish character selection. Stand still outdoors.
2. **Idle resmon.** Press F8, type `resmon 1`. If F8 answers "Command resmon
   is disabled in production mode", do section 3 "Enable resmon first" and
   come back. Wait 30 s after spawning, then
   watch the `cis_libs` row for 60 s.
   - Expected: 0.00 ms. 0.01 to 0.02 ms is display noise and passes (D12).
   - Write down the value it shows most of the time, and the highest value you
     see.
3. **F8 errors.** Scroll the F8 console. Expected: no red line that names
   `cis_libs`.
4. **Build the active case.** In F8, type `cis_ownertest`.
   - Expected: a toast and an F8 line,
     `built: 1 zone, 20 points. Step out and back in to see the text UI.`
5. **Zone and text UI.** Walk more than 10 m away, then walk back to where you
   typed the command.
   - Expected: on entering, a text UI box reads `[cis_libs] owner test zone`.
   - Expected: a toast reads `callback ok=true server time=<a number>`.
   - Walk out again: the text UI box disappears.
6. **Status.** Stand where you typed the command and type
   `cis_ownertest_status`.
   - Expected: `zones now: cis_libs_ownertest; points inside: 20 of 20`.
7. **Active resmon.** Still standing there, with the text UI showing, watch
   resmon for 30 s.
   - Read two rows: `cis_libs` and `cis_libs_ownertest` (the zone and point
     checks run in the consumer, by design).
   - Expected: each at most 0.2 ms on average. Any 5 s stretch above 0.5 ms is
     a defect.
8. **Restart recovery.** On your PC run
   `ssh CisFiveM 'fivem-console restart cis_libs; fivem-console ensure cis_libs_ownertest'`.
   The second command is needed: the test consumer declares
   `dependency 'cis_libs'`, and the live harness's own restart step
   (`test/live/cis_test/server/commands.lua` line 403) ensures its dependents
   again the same way. Wait 10 s, type `cis_ownertest`, then walk out of the
   zone and back in.
   - Expected: the same text UI and `callback ok=true` toast as step 5, and no
     red F8 line.
   - Note whether the text UI from before the restart stayed on screen. It
     should not.
9. **Back to idle.** Type `cis_ownertest_clear`.
   - Expected: `cleared: no zone, no point, no text UI`, and within 5 s the
     `cis_libs` resmon row is back to the step 2 value.
10. **NUI under its CSP.** Type `cis_ownertest_ui`.
    - Expected: an F8 line and toast,
      `foreign event option refused: true (...)`, where the reason names
      `cis_libs_ownertest:` as the prefix the event must start with.
    - Expected: a context menu titled `cis_libs owner test` with two options,
      drawn with its fonts and icons, and no red F8 line naming `cis_libs`.
    - Pick `Fire this resource's own event`. Expected: the menu closes and a
      toast reads `own event fired: 1`.
    - Type `cis_ownertest_ui` again and press Escape. Expected: the menu
      closes and the mouse cursor is gone.
    - Type it again and pick `Progress bar with a prop`. Expected: a 3 s bar
      labelled `Holding a cone`, a road cone attached to your ped while it
      runs, and gone afterwards; then `progress finished: true`. Run it once
      more and press X: `progress finished: false`, and the cone is gone.
    - If a second player is connected, they should not see the cone: the
      prop is local to your client.
11. **`cis_debug`** in F8. Expected: one line starting `[cis_libs] ped=`.

Then switch to the next server (section 3) and repeat.

## 5. What to send back

For each server, one line like this:

```
esx: idle 0.00 (max 0.01) | active cis_libs 0.03, ownertest 0.05 | text UI yes | callback yes | restart yes | ui menu yes, foreign refused yes, cone yes | F8 errors none
```

Add the first red F8 line exactly as shown if there was one.

## 6. What this test does not cover

- **A sync batch arriving** (part of the active bar). Sync writes need an
  authorised resource, and authorising one is a server config change. Not
  tested tonight.
- **The NUI escape handshake.** The test consumer opens no focused UI, so
  `escape` is never sent. Covered by unit tests only (`test/interface.lua`,
  `test/web/`).
- **The `cis_test` live suite** is not part of this test: the agent ran it on
  the VPS `cis_core` server with your PC connected (run-20261024-115302 at
  `d7dcebb`: pass 38, fail 0, skip 0, error 0; `docs/V1.md` section 10, third
  run). It covers the client cases, not client resmon or how the UI looks.
