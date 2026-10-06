# Coverage that has not run, and does not exist yet

**Written 2026-10-04.** The companion to `RUNBOOK.md`, which says how to run a
test. This says which tests have never produced a result, and which ones are
not written.

Read this as the honest inventory of what cis_libs 1.0.0 has NOT been shown to
do. A green run is only as wide as this document's first section.

---

## 0. THE DEPLOY WENT TO A FOLDER THE SERVER NEVER LOADS

**Found 2026-10-05. Every live run before this proved the harness, not the
library.** Read this before trusting any run id in this file.

FiveM resolves `ensure cis_libs` against the WHOLE resources tree, and when
two folders are named cis_libs it picks the top-level one and says so:

```
Warning: cis_libs exists in more than one place
  (...resources\cis_libs is used,
   the duplicate is ...resources\[standalone]\cis_libs)
```

`.live-env.json` had `resourcesDir` pointing at `[standalone]`, and the deploy
wrote there. So every run deployed to the copy the server ignored, restarted
the server, and then confirmed the commit **by reading its own copy back**.
The check was structurally incapable of failing.

Three independent signals, and the third had been in the log the whole time:

1. the server warning above, printed on every start;
2. the top-level folder had none of the new code — no `files {}`, no
   `ModuleInfo`;
3. run-20261005-005649 failed with `No such export ModuleInfo in resource
   cis_libs` against a commit that contains it.

**The guard that should have caught it was looking in the wrong tree.**
`findLibFolders` walked `resourcesDir`, which is INSIDE `[standalone]`, so it
could never see the duplicate it existed to find. It now walks the parent —
the tree FiveM actually scans — and `.live-env.json` carries an explicit
`libDir` naming the canonical folder. A guard that inspects the wrong tree is
not a guard.

**What this invalidates:** every run before run-20261005-010419 proved that the
HARNESS deploys, starts and talks correctly. It did not prove that cis_libs
behaves. The 4.10 server-side results are re-proven in run-20261005-010757;
the earlier run ids remain as harness evidence only and should be read that way.

**Also measured, and the plan got it wrong:** the master plan says "verify live
that a plain include really sees no varargs". It sees ONE, and its value is 2.
The premise is false. Nothing breaks, because the module branches on the
*marker* being absent rather than on the vararg list being empty — and had it
gone the other way, every consumer @including a cis_libs module would have
silently received nil.

---

## 1. The player tier — it runs now

**A player connected on 2026-10-04 and the tier executed for the first time in
this project's life.** The box still has no GPU, so the harness cannot *start* a
client; that does not matter, because a person can put a player on the server
anyway. `client.mode` answers "can the harness start a client", not "is anyone
connected", and treating the second as the first is how a real player sat
watching the one tier that needs them report SKIP.

`run-20261004-134953`: **pass 25, fail 0, skip 0**, commit `f033b82`, 1 player.

**`run-20261004-212022`** (commit `4907e98`, 4.10–4.12) is the widest run this
project has produced: **pass 25, fail 0, skip 0, manual 0, error 0** in 22.15 s
across eight suites and 115 recorded checks, with 1 player. Read with the
section below, not on its own — four of those cases report themselves unproven.

| Area | Live proof |
|---|---|
| 3.12 `GetFramework` | answers the method table on the client, not the resolved provider |
| 3.14 doors | `RequestState` reaches the registered `doorsClient` provider, with the identifier |
| 3.3 zone `onExit` | hands the player's real position, ~20 m past the zone centre |
| 3.10 thread resilience | a raising `onEnter` does not stop the zone loop; a later zone still fires |
| 3.4b debug drawing | the draw thread starts with the first debug zone and stops with the last |
| 2.7 player contract | ped back within 1 m of origin in x and z, bucket 0 |
| 4.5 networked entities | a real server-side entity for a **prop, a vehicle and a ped**, each with `netId`, and `entities` matching `networked`; removal takes the entity with it; an unmakeable kind is refused with nothing created |
| 4.3/4.9 ids | two resources both holding `"shared-id"` under their own namespaces; a numeric id arrives as its string and removes as one |
| owner stop | one consumer stopping takes only its own records, and the survivor still streams |
| capability registry | all 10 slots resolve against the fakes; a missing provider refuses with a reason instead of raising; a raising provider never escapes into the consumer; the revoke command works from the console |
| 4.8 snapshot recovery | (unbroken through this run — see the note on `syncSnapshot` below) |

**Still unproven, and no amount of harness work closes them:**

- **3.5 `playerDropped`** — needs a real player to LEAVE with awaits
  outstanding. One player connected, and they are AFK.
- **Second-player cases** — need two. Unit-only until then, on the approved
  SKIP list.
- **The client sync SPAWN path — CLOSED live on 2026-10-05,
  `run-20261005-222148`, docks at 604, -2719, 5.9.**
  `prop_roadcone02a` streams; a valid record spawned and was released;
  string coords and a table model spawned nothing.

  The years of "walk ten seconds, the prop is not resident" were a misread
  of `RequestModelTimeout`. It required `IsModelInCdimage AND IsModelValid`
  before calling `RequestModel`. `IsModelValid` is false for unloaded-but
  legal props, so the request never ran and every live probe returned
  false in milliseconds. Mission Row and the docks failed the same way.
  `prop_barrel_01` is also not in this build's cdimage; the cone is.

  Two things still true: the refusal cases must run AFTER a case that has
  established a model streams; and `TriggerEvent` from cis_test does not
  reach cis_libs's handler.

  Two things learned getting there, both written into the suite so the next
  person does not repeat them: the refusal cases must run AFTER a case that
  has established a model streams, because "nothing spawned" is also what a
  client that cannot spawn anything looks like; and `TriggerEvent` from cis_test
  does not reach cis_libs's handler, so the payload is relayed through the
  server instead.

- **A VACUOUS PASS USED TO BE INDISTINGUISHABLE FROM A REAL ONE, and that was
  fixed on 2026-10-04.** The client suites answer a case with `nil` to say
  "the code is not wrong but nothing was proved here", and `runCase:record`
  stored `detail` **only on failure** — so that explanation was discarded on
  exactly the path it was written for. `run-20261004-191413` and every run
  before it therefore reported `pass 1 fail 0 skip 0` with no way to tell an
  empty run from a full one. `Case:eq`/`Case:ok` now take an optional note that
  survives a pass, the player suite forwards the client's message on the
  success path, and `notes` is carried into `results.json` and emitted as
  `case_note` rows. `run-20261004-212022` carries 115 of them.

  **Read the notes, not the tally.** A case that passes with a note saying
  "nothing was proved" has proved nothing.

- **THE LOOK** of the debug draw, the notifications and the points debug text.
  MANUAL by the plan, and MANUAL is never counted as automated coverage.
- **Death and respawn** — `cis_test_allow_death` is `0`, which is the safe
  default and keeps these on the approved SKIP list.

### What the player found that no unit test could

Two harness bugs, both invisible without a real client:

- The client suite timeout was 30 s. An unfocused FiveM client throttles its
  own frame loop, so a **working** client was reported as not answering — the
  player tier passed in 9 s focused and failed in 35 s unfocused. Now 60 s with
  one retry.
- `waitForPlayer` read `player.mode` off a third argument the caller never
  passed. It never crashed because the only branch reaching it required
  `client.mode` to be on, and the file's sole exercise was the path that
  avoids it.

---

## 2. Written, ran, but against code that has since changed

`run-20261004-101815` (pass 24, fail 0, skip 1) is the last confirmed live run,
on deployed commit `39bfe93`. It is the first run that includes **3.10, 3.11,
3.12, 3.13, 3.14, 3.15, 3.16, 3.4b, 4.3 and 4.5** — every change to the
background loops and the self-check, plus the networked sync path.

Before it, `run-20261003-223351` (pass 17, fail 0) was the last confirmed run.
`run-20261004-091704` is kept because it is the one that **failed**, and its
failure is the reason a live fixture was wrong: the `syncids` case asserted that
`cis_test_b` owned a sync record, and `cis_test_b` is deliberately off
`AuthorizedResources`, so every mutating export it calls is refused. The case
could never pass. It was fixed in favour of `cis_test_c` and the run above is
green.

### Still unproven, and it is a client-shaped hole

Task 4.5's networked path is proven **on the server**: real entities for a prop,
a vehicle and a ped, created with the server RPC natives with no player
connected, and deleted with their record. What is not proven is the other half —
a client seeing the entity, resolving its netId, and despawning on a remove, and
the "player in range at creation" half of the RPC question. `test/LIVE.md` lists
both under "Not covered".

---

## 3. Not written — Stage 2.11

The plan's Stage 2 gate needs these two tiers and **they do not exist**:

- **`perf`** — fixed scenarios with fixed budgets: idle zone pass under
  0.02 ms, 100 mixed zones under 0.05 ms, and the rest of §8.2's list. Each
  result published with hardware, player count, server build and date, per the
  plan's hard rule.
- **`soak`** — a long run meant to catch what a five-second pass cannot.

Stage 2's gate is therefore open even with a server up and a player
connected. The harness has the machinery (`Suite(..., { tier = ... })` accepts
any tier name and `cis_test list` already prints the distinct tiers) — the
scenarios simply have not been written.

---

## 4. Unit-only by nature — the approved SKIP list

Some cases cannot be produced on this server at all. Per the plan they are on
the approved SKIP list and **never count as done**:

- A **second player**. One real player is connected at most.
- A **real player drop** mid-assertion (the unit tests simulate it).
- **Death and respawn** unless `cis_test_allow_death` is `1`, which it is not,
  and must stay `0` while the client would be the owner's own character.

---

## 5. Known-violation debt

**None.** `check-realms` reports zero known violations and zero new ones. The
three model-request natives that used to sit in `server/sync.lua` are gone; the
networked path is created with the server RPC natives, and the
`knownViolations` list in the checker is empty, so any violation from here on is
new and fails the build.

One correction came with it: `tools/natives/runtime.json` had
`SetEntityRoutingBucket` hand-listed as client-only, which made the checker
report the server call as a violation when the server setter is exactly what the
native is for. A name that is in `natives_cfx.json` does not belong in that
hand-curated list at all — its realm comes from the database's `apiset`.

---

## 6. What the mutation gate does and does not cover

31 rows, all killed. It proves specific security and boundary checks bite. It
does **not** prove the absence of a defect nobody wrote a mutation for — which
is how `DrawText3D` shipped two non-existent natives, and how
`declaresDependencyOnUs` shipped a doubled path that could never match.

The honest summary: **the mutation gate is a floor, not a ceiling.** One of the 31
rows (M34) was written after its test had already been seen to pass — and it
passed against the *broken* code, because the stub's handle was not alive and
`despawn`'s own existence guard meant the delete never ran. The row did not
catch that; the fix to the test did. A green test is only evidence once it has
been watched red.