-- The player half of the harness: snapshot, run, restore, verify.
--
-- THE CONTRACT, AND WHY IT IS ATOMIC. A client suite snapshots the player, runs
-- its cases, restores, and VERIFIES the restore -- in one operation, on this
-- side. Splitting those across several server round trips would leave a window
-- where the harness is holding a snapshot of a player it is not currently
-- looking after, and a client suite that drops the connection mid-run would
-- leave the snapshot behind with nothing left to restore from.
--
-- Snapshot then restore then verify is also the ONLY honest order. Restoring
-- without verifying means a restore that silently did nothing still reports
-- success, and the whole contract rests on this being true.
--
-- WHAT IS SNAPSHOTTED. Position, heading, routing bucket, health, armour,
-- frozen, invincible, visible, collision, vehicle and seat, weapons and ammo,
-- current weapon. Everything a case might touch.
--
-- WHAT IS NEVER TOUCHED. The player's identity, their KVP, their settings,
-- their session. Nothing here drops, kicks or bans anybody, and the config the
-- providers supplied has DropPlayer false so nothing here CAN.

local P = {}
CisTestPlayer = P

local SUBJECT = nil

-- ------------------------------------------------------------------ subject

-- THE SUBJECT IS THE LOCAL PLAYER, NOT A SERVER ID.
--
-- The plan picks "the connected player with the lowest server id", which is a
-- SERVER-side notion. Down here the server id is meaningless: FiveM's client-side
-- GetPlayerPed takes a PLAYER INDEX, and the local player's index is 0. Passing
-- server id 5 gets GetPlayerPed(5), which is nil, so P.Snapshot() failed, so
-- RunSuite returned an error envelope with no `restored` field -- and the server
-- reported that as "the restore failed" with a detail of nil, which pointed at
-- the restore rather than at the snapshot that never happened.
--
-- On a client with one connected player, that player IS the subject.
local function subject()
    if SUBJECT then return SUBJECT end
    SUBJECT = PlayerId()
    return SUBJECT
end

function P.ClearSubject() SUBJECT = nil end

-- PlayerPedId, NOT PlayerPed. There is no global called PlayerPed in CfxLua,
-- and the first live player run found that the hard way: the snapshot called
-- a nil global and the whole tier reported "the restore failed" when in fact
-- the snapshot never happened. The realm checker does not cover this file -- it
-- scans cis_libs' manifest, not the harness -- so the name had to come from
-- the natives list like any other.
function P.Ped()
    return PlayerPedId()
end

function P.ServerSrc()
    return GetPlayerServerId(subject() or 0)
end

function P.Origin()
    local ped = P.Ped()
    if not ped or not DoesEntityExist(ped) then return nil end
    return GetEntityCoords(ped)
end

-- --------------------------------------------------------------- the snapshot

-- READ A FIELD ONLY IF THIS BUILD HAS THE NATIVE.
--
-- Not every native exists on the client. Checked against FiveM's own native
-- database, which carries an `apiset` per native:
--   * GET_ENTITY_INVINCIBLE, GET_ENTITY_COLLISION_ENABLED, SET_ENTITY_INVINCIBLE,
--     SET_ENTITY_COLLISION, SET_ENTITY_VISIBLE, SET_ENTITY_HEALTH,
--     SET_ENTITY_COORDS_NO_OFFSET, GET_PED_WEAPONTYPE_INDEX, GET_PED_AMMO and
--     SET_PED_AMMO are not in it at all -- GTA-side natives whose FiveM Lua
--     availability on a client is not guaranteed.
--   * GET_ENTITY_HEALTH, GET_PED_ARMOUR, GET_VEHICLE_PED_IS_IN,
--     GET_PED_IN_VEHICLE_SEAT, FREEZE_ENTITY_POSITION and the routing-bucket
--     family are listed with apiset SERVER, which is the documented surface.
-- Three of them were confirmed nil AT RUNTIME here, one per deploy-and-run
-- cycle, and each surfaced as the whole tier reporting "the restore failed"
-- when the snapshot had never happened at all.
--
-- A field is read only if the native is present, and every field that was
-- skipped is reported in the envelope. An unread field is safe only if no case
-- can touch it either -- and the report is what lets a reader check that
-- rather than assume it.
local SKIPPED = {}

-- FiveM's boolean-ish natives do not agree on a representation: IsEntityVisible
-- answers 1, IsEntityInvincible answers a real boolean. The snapshot normalised
-- one side and the verify did not, so a perfectly good restore compared 1 with
-- true and reported a mismatch. Both sides go through the SAME normalisation now.
local function can(name)
    if type(_G[name]) ~= 'function' then
        SKIPPED[name] = true
        return nil
    end
    return _G[name]
end

-- Reads a native, or answers `fallback` when this build does not have it.
local function read(name, fallback, ...)
    if not can(name) then return fallback end
    return _G[name](...)
end

-- Calls a native when this build has it, and says whether it did.
local function write(name, ...)
    if not can(name) then return false end
    _G[name](...)
    return true
end

function P.SkippedFields()
    local out = {}
    for name in pairs(SKIPPED) do out[#out + 1] = name end
    table.sort(out)
    return out
end

-- ---------------------------------------------------------------- the snapshot

function P.SnapshotWeapons(ped)
    local out = {}
    if not can('GetPedWeapontypeIndex') then return out end
    local current = read('GetSelectedPedWeapon', 0, ped)
    for _, weapon in ipairs({ current, 0xA2719263, 0xB1B0AD6D, 0x3BBD2C6B, 0x8E6DC4E6 }) do
        if type(weapon) == 'number' and weapon > 0 then
            out[weapon] = read('GetPedAmmo', 0, ped, weapon)
        end
    end
    return out
end

function P.Snapshot()
    local ped = P.Ped()
    if not ped or not DoesEntityExist(ped) then
        return nil, 'no ped for the subject'
    end
    local vehicle = read('GetVehiclePedIsIn', 0, ped, false)
    return {
        src = P.ServerSrc(),
        ped = ped,
        coords = GetEntityCoords(ped),
        heading = read('GetEntityHeading', 0.0, ped),
        bucket = read('GetEntityRoutingBucket', 0, ped),
        health = read('GetEntityHealth', nil, ped),
        maxHealth = read('GetEntityMaxHealth', nil, ped),
        armour = read('GetPedArmour', nil, ped),
        frozen = read('IsEntityPositionFrozen', nil, ped) == true,
        invincible = read('GetEntityInvincible', nil, ped) == true,
        visible = read('IsEntityVisible', true, ped) ~= false,
        collision = read('GetEntityCollisionEnabled', true, ped) ~= false,
        vehicle = (vehicle ~= nil and vehicle ~= 0) and vehicle or nil,
        seat = read('GetPedInVehicleSeat', nil, ped, -1),
        weapons = P.SnapshotWeapons(ped),
        currentWeapon = read('GetSelectedPedWeapon', nil, ped),
    }
end

-- ---------------------------------------------------------------- the restore

function P.Restore(snap)
    if not snap then return false, 'nothing to restore' end
    local ped = snap.ped
    -- The handle can go stale across a respawn or a model change. Restoring
    -- onto whatever now holds it would be worse than refusing.
    if not DoesEntityExist(ped) then
        return false, 'the subject ped no longer exists'
    end

    write('SetPlayerRoutingBucket', PlayerId(), snap.bucket or 0)
    write('SetEntityCoordsNoOffset', ped, snap.coords.x, snap.coords.y, snap.coords.z, false, false, false)
    write('SetEntityHeading', ped, snap.heading or 0.0)
    write('SetEntityHealth', ped, snap.health or 200)
    write('SetPedArmour', ped, snap.armour or 0)
    write('SetEntityInvincible', ped, snap.invincible == true)
    write('SetEntityCollision', ped, snap.collision ~= false, true)
    write('SetEntityVisible', ped, snap.visible ~= false, false)
    write('FreezeEntityPosition', ped, snap.frozen == true)

    for weapon, ammo in pairs(snap.weapons or {}) do
        write('SetPedAmmo', ped, weapon, ammo)
    end
    if snap.currentWeapon then
        write('SetPedCurrentWeapon', ped, snap.currentWeapon, true)
    end
    return true
end

-- Restore, then CHECK. The check is the contract; the restore is the intent.
function P.RestoreAndVerify(snap)
    local ok, why = P.Restore(snap)
    if not ok then return false, why end

    local ped = P.Ped()
    if not ped or not DoesEntityExist(ped) then
        return false, 'the subject ped vanished during the run'
    end

    local problems = {}
    local function near(name, got, want, eps)
        if type(got) ~= 'number' or math.abs(got - want) > (eps or 0.5) then
            problems[#problems + 1] = ('%s: got %s, want %s'):format(name, tostring(got), tostring(want))
        end
    end
    -- A field whose NATIVE IS ABSENT is not compared at all. The snapshot
    -- stored a fallback for it, so comparing the verify's nil against that
    -- fallback reports a mismatch for a field nobody ever captured -- which is
    -- what the first verified run did, for four fields, on a restore that had
    -- in fact put the player back.
    local function same(name, native, got, want)
        if not can(native) then return end
        if got ~= want then
            problems[#problems + 1] = ('%s: got %s, want %s'):format(
                name, tostring(got), tostring(want))
        end
    end

    local coords = GetEntityCoords(ped)
    near('x', coords.x, snap.coords.x, 0.75)
    near('y', coords.y, snap.coords.y, 0.75)
    near('z', coords.z, snap.coords.z, 0.75)
    near('heading', read('GetEntityHeading', nil, ped), snap.heading, 1.0)
    same('health', 'GetEntityHealth', read('GetEntityHealth', nil, ped), snap.health)
    same('armour', 'GetPedArmour', read('GetPedArmour', nil, ped), snap.armour)
    same('bucket', 'GetEntityRoutingBucket', read('GetEntityRoutingBucket', nil, ped), snap.bucket)
    same('frozen', 'IsEntityPositionFrozen', read('IsEntityPositionFrozen', nil, ped) == true, snap.frozen)
    same('invincible', 'GetEntityInvincible', read('GetEntityInvincible', nil, ped) == true, snap.invincible)
    same('visible', 'IsEntityVisible', read('IsEntityVisible', true, ped) ~= false, snap.visible)
    same('collision', 'GetEntityCollisionEnabled', read('GetEntityCollisionEnabled', true, ped) ~= false, snap.collision)

    if #problems == 0 then return true end
    -- All of them, not just the first: a restore that fixed position and missed
    -- health is a different bug from one that fixed health and missed position.
    return false, table.concat(problems, '; ')
end

-- ---------------------------------------------------------------- the suites
--
-- A case is { name, run } and `run` answers (ok, message). ONE shape: the first
-- draft had two, and the results were harder to read than the code.

local SUITES = {}

function P.RegisterSuite(name, cases)
    SUITES[name] = cases or {}
    return true
end

function P.HasSuite(name) return SUITES[name] ~= nil end

function P.SuiteNames()
    local out = {}
    for name in pairs(SUITES) do out[#out + 1] = name end
    table.sort(out)
    return out
end

-- ------------------------------------------------------------- observation
--
-- What a case reads to see what the library DID rather than what it returned.
-- A returned value proves the call answered; only these prove the callback
-- fired, which is the entire subject of the zone cases.

local LOGS = { enter = {}, exit = {}, near = {} }

function P.ClearEnterLog() LOGS.enter = {} end
function P.ClearExitLog() LOGS.exit = {} end
function P.ClearNearLog() LOGS.near = {} end
function P.EnterLog() return LOGS.enter end
function P.ExitLog() return LOGS.exit end
function P.NearLog() return LOGS.near end

function P.NoteEnter(coords) LOGS.enter[#LOGS.enter + 1] = coords or true end
function P.NoteExit(coords) LOGS.exit[#LOGS.exit + 1] = coords or true end
function P.NoteNear(which) LOGS.near[#LOGS.near + 1] = which end

-- ------------------------------------------------------------------ movement
--
-- The ped is FROZEN for the duration of a suite, and stepping it with
-- SetEntityCoordsNoOffset is the plan's deterministic walk. Stepping rather
-- than teleporting matters: a teleport can cross a zone boundary between two
-- zone-loop passes and look like the player walked through it.

function P.StepTowards(target, steps)
    steps = steps or 20
    local ped = P.Ped()
    if not ped or not DoesEntityExist(ped) then return false end
    local from = GetEntityCoords(ped)
    for i = 1, steps do
        local t = i / steps
        write('SetEntityCoordsNoOffset', ped,
            from.x + (target.x - from.x) * t,
            from.y + (target.y - from.y) * t,
            from.z + (target.z - from.z) * t,
            false, false, false)
        Wait(0)
    end
    return true
end

function P.WaitFor(fn, timeoutMs)
    local deadline = GetGameTimer() + (timeoutMs or 1000)
    while GetGameTimer() < deadline do
        if fn() then return true end
        Wait(50)
    end
    return false
end

-- ---------------------------------------------------------------- execution

function P.RunSuite(name)
    local cases = SUITES[name]
    if not cases then
        return { ok = false, error = 'no such client suite: ' .. tostring(name) }
    end

    local snap, why = P.Snapshot()
    if not snap then
        return { ok = false, error = 'could not snapshot the player: ' .. tostring(why) }
    end

    local ped = P.Ped()
    if ped and DoesEntityExist(ped) then
        write('FreezeEntityPosition', ped, true)
        write('SetEntityInvincible', ped, true)
    end
    LOGS.enter, LOGS.exit, LOGS.near = {}, {}, {}

    local results = {}
    for _, c in ipairs(cases) do
        local ok, msg = xpcall(c.run, function(m)
            return debug.traceback(tostring(m), 2)
        end)
        if not ok then
            -- A case that RAISED is a failure with the stack attached, not a
            -- crash that loses every case after it.
            results[#results + 1] = { name = c.name, ok = false, msg = tostring(msg) }
        else
            results[#results + 1] = { name = c.name, ok = msg ~= false, msg = msg }
        end
    end

    -- Always, whatever the cases did.
    local restored, restoreWhy = P.RestoreAndVerify(snap)

    local pass, fail = 0, 0
    for _, r in ipairs(results) do
        if r.ok then pass = pass + 1 else fail = fail + 1 end
    end

    return {
        ok = (fail == 0 and restored) and true or false,
        suite = name,
        pass = pass,
        fail = fail,
        restored = restored,
        restoreWhy = restoreWhy,
        skipped = P.SkippedFields(),
        results = results,
    }
end
