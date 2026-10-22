<!-- Independent read-only re-audit, 2026-10-22, of branch claude/vigilant-hamilton-3b0fva at or just before e0561a2. Line numbers may drift slightly. NOT YET ACTED ON. Scratch harness paths it mentions were in the cloud session and are gone. -->

## cis_libs server-side audit (read-only). Overall grade: B-

I read every file in scope in full. I confirmed the main findings with scratch Lua 5.4 harnesses, using stubs whose `exports` raise on a missing export the way FiveM's scheduler does. They are in (cloud session scratchpad, not preserved)  (h.lua is the harness, t1–t6 are the scenarios). `npm test` passes: 3050 assertions, 0 failed.

**Bottom line:** I found no network path where one client can change another player's state or the server's shared state. Every `cis_libs:*` net event only touches the sender's own state, and the per-player tables are bounded and cleared on drop. What keeps this area below an A is three things:
- a privilege-escalation path through command ACE provisioning;
- one bad callback registration can lock every player out of all callbacks;
- the rate limiter can kick legitimate players.

### 1. Exploitable defects

**HIGH: CommandAdd lends cis_libs's `add_ace` right to any resource, for any principal and any command name** (`server/command.lua:196-206, 308-370`). This applies once the operator has added the documented grant `add_ace resource.cis_libs command.add_ace allow`.
- `restricted` only has to match `^[%w_%-%.:]+$` (line 332), so `builtin.everyone` or `group.user` are accepted.
- `name` is never checked against commands that already exist (`GetRegisteredCommands` is never used).
- Scenario: any resource calls `CommandAdd('setjob', {restricted='builtin.everyone'}, fn)`, or uses a builtin name such as `add_principal`. cis_libs then runs `add_ace builtin.everyone command.setjob allow`, which opens another resource's admin command, or a builtin, to every player.
- Verified (t4.lua): it ran `add_ace builtin.everyone command.quit allow` and `add_ace group.user command.add_principal allow`.
- Whether players can reach builtin commands remotely through this ACE should be confirmed on a live server. Opening other resources' restricted script commands follows directly from the ACE model.

**MEDIUM: any resource can replace another resource's net binding** (`server/security.lua:458-506`). For a `"resource:export"` handler, the owner is parsed from the string, not taken from `GetInvokingResource()`. Calling `CisNetOn('bank:withdraw', 'bank:anyExport', {})` therefore matches `binding.owner == 'bank'` and replaces the handler and its opts, which strips the schema and rate limit. Verified (t2.lua): the strict handler was replaced and `amount=1e9` went through.

**MEDIUM: RegisterCapability is not gated** (`server/proxy.lua:291-318`, `shared/registry.lua:234-272`).
- `SetDropPlayerHandler` is gated "because the first caller takes the slot" (proxy.lua:551-559), but `RegisterCapability('security', ...)` reaches the same slot with no allow-list check.
- The same first-come squatting works for `doors`, which then receives every gated door mutation; `database`, which receives all SQL; and `discord`, which receives the webhook URLs Logging passes at logging.lua:155-160.

**MEDIUM: a modded client can permanently remove networked sync records** (`server/sync.lua:1125-1150`). KeepEntity does not stop a client deleting an entity (natives.json for SET_ENTITY_ORPHAN_MODE says client delete requests "will still work"). A client that owns the entity, which is typically the nearest player, deletes it 4 times within 60 s. With `RESPAWN_MAX=3` the record is then dropped from the server for good.

**LOW-MEDIUM: SecureNetOn checks the schema before the rate limit** (`security.lua:426-438`). Every malformed event produces a `CisSecurityReport`: a console line plus a security-provider call or `DropPlayer`. Verified (t2.lua): 500 bad payloads with `maxHits=2` produced 500 console lines. With a custom drop or ban provider, it is called once per queued event until the drop takes effect.

### 2. Correctness bugs

**HIGH: a missing export leaks callback in-flight slots and locks the player out** (`server/callback.lua:80-81, 345-347`).
- `invoke` looks up `exports[res][name]` outside `xpcall`. A missing export raises after `slot.n` is incremented and before it is decremented.
- Triggers: a typo in a `"res:export"` registration (not validated at line 154-161), or a target resource that is stopped when it is not the registrant.
- After 8 such requests, that player gets `busy` on every callback until they reconnect. Verified (t1.lua): a healthy callback then answered `false busy`.
- There is also no watchdog for a handler that never resumes, for example a DB driver restarted mid-await.
- The same unguarded lookup is in `TryAwaitCallback` (raises despite being "non-raising"), `security.lua:416-417` and `client/callback.lua:586-587` (no reply is sent, so the server waits for the timeout).

**MEDIUM-HIGH: the rate-bucket cap refuses legitimate players for the whole session, then kicks them** (`security.lua:215-238, 320-323`).
- Buckets never expire, and there are 256 per player across all net events, `cb:<name>` and `notify:<res>`. Any consumer using `RateOk` with dynamic names fills them.
- After the cap, every new name is refused. A legitimate 1/s net event then reports five consecutive refused windows, and `DropPlayer` (default true, defaults.lua:196) kicks the player.
- Verified (t3.lua): the player was dropped, and callbacks answered `rate`.

**MEDIUM: an id-less sync upsert can silently overwrite an explicit record.** `nextId` (sync.lua:46-49) generates `prop_<seq>` without checking for collisions. Verified (t5.lua): explicit id `prop_1` (a chair) was replaced by an id-less table.

**LOW-MEDIUM: callback names are replaced silently across owners** (callback.lua:176-181, and client/callback.lua:668-678). Net events refuse a different owner (security.lua:507); callbacks do not, so a name collision quietly hijacks.

**LOW-MEDIUM: syncGaveUp is sent once per key, but the limit is 8/s** (client/sync.lua:274 against security.lua defaults).
- With 9 or more records using a bad model, the extra gave-ups are dropped, so the server keeps believing the client holds them and never re-offers them.
- With 109 or more, the burst exceeds `RATE_WARN_LIMIT` and players in range are kicked.

**LOW: other correctness issues**
- **Case-sensitive command name strip** (command.lua:247): `parsed[1] == name` is case-sensitive, so `/GIVE 5 bread` passes `GIVE` as argument 1 (verified in t4.lua). This assumes the platform matches commands case-insensitively; confirm live.
- **Apostrophes break the command parser** (command.lua:56): `'` opens a quote, so `me I'm sure it's fine` becomes `Im sure its|fine` (t6.lua).
- **Restriction frozen at first registration** (command.lua:357-361): the `restricted` flag is set once, so re-adding a command unrestricted leaves it ACE-gated.
- **Missing nil guard in the zone pass** (zones.lua:397): `enter(zones[id])` has none, unlike line 380. An enter handler that removes a zone aborts the pass for the remaining players.
- **Entity handle leaked on timeout** (sync.lua:442-446): when an entity never appears, the handle is not deleted.
- **String-keyed rate buckets never freed** (security.lua:221): `RateOk` with a string src (ids from `GetPlayers()` are strings) is never cleared on drop.

### 3. Performance

**MEDIUM: `upsert` → `push` (sync.lua:594-609) does no batching.**
- Each upsert calls `playerPositions()`, which is O(players) natives, and sends one reliable event per record per nearby player.
- Verified (t5.lua): 300 upserts produced 300 events to one player. This contradicts the "one batch per player per pass" design.

**LOW performance items**
- **Callback refusal replies** (callback.lua:298): over-budget requests still get a `TriggerClientEvent` each, echoing a client-chosen `key`, and are never escalated. The platform's own net-event limiter bounds this.
- **Console output not rate-limited** (logging.lua:120): only Discord is.
- **Large sync scopes** (grid.lua MAX_CELLS=4096): any `scope` above roughly 1638 m falls into `unindexed` and is scanned per player per pass, with an Error log for each.

The hot paths are otherwise sound: cached limits, hoisted pass state, grid-indexed zones and sync, a cheap pending sweep.

### 4. Design gaps versus a production server
- `SetConfig` is first-caller-wins unless `cis_config_supplier` is pinned. `Security` is not merged with defaults, so a supplier that leaves out `DropPlayer` silently turns kicks off (proxy.lua:212-259).
- Callbacks are client-reachable by default (`remote=true`, callback.lua:136).
- Enforcement goes straight from first strike to kick: one schema mismatch from a client-side bug drops every player who hits it.
- Net events get none of the payload bounding callbacks get (only the first argument's schema). The schema cannot express integer or finite values, and ±inf passes without min/max.
- Capability slots have no allow-list.
- The fixed-window limiter has no bucket eviction.
- The manifest floor `/server:4500` predates natives the code relies on (`SetEntityOrphanMode`, `GetEntityFromStateBagName`). The guards fall back silently instead of failing at boot; confirm the real minimum build.

**Items not found:** cross-player exploits from a client, unbounded per-player memory growth, and wrong native signatures. I checked creation, ACE, orphan mode, bucket, state-bag and metadata calls against tools/natives.

### What keeps it from an A
1. Constrain command ACE provisioning to `group.*` principals and to command names not already registered (check `GetRegisteredCommands`).
2. Take the net-binding owner from `GetInvokingResource()`, not from the reference string.
3. Gate `RegisterCapability` the same way `SetDropPlayerHandler` is.
4. Guard the export lookups in `invoke` and `dispatch`, decrement the in-flight slot even on failure, and add a reclaim for stuck slots.
5. Evict expired rate buckets instead of refusing new names at the cap, and never escalate cap refusals to a kick.
6. Rate-limit before the schema check, and report once per flood.
7. Replace the respawn drop-after-3 with backoff so clients cannot delete records.
8. Make `nextId` collision-proof.
9. Batch `push` into the pass.
10. Add owner checks for callback names.
11. Batch or raise the limit for syncGaveUp.
12. Fix the command case and apostrophe handling, and the zone nil guard.
