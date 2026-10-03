-- cis_ctl: the agent's console.
--
-- WHY A FILE AND NOT THE txAdmin WEB CONSOLE. The PC session spent several
-- attempts on this: Playwright's click() on the prompt input times out, fill()
-- alone does not submit, and the only thing that worked was a coordinate click
-- on the visible prompt line followed by Enter. A control step that fragile is
-- not a control step, it is a coin flip that happens to work on a 1920x1080
-- window. This resource removes it: the agent writes a file, and the server
-- executes it. Nothing to click, no browser, and -- unlike the console -- the
-- whole command surface can be asserted in a unit test.
--
-- IT DEPENDS ON NOTHING. No `dependencies` block, no export from cis_libs, no
-- require of the harness. Restarting cis_libs or any cis_test* resource cannot
-- take this down, which is the only property that makes it usable as the thing
-- that puts those resources back.
--
-- THE LOOP. Every POLL_MS it reads inbox.json, a two-field object
-- { "id", "cmd" }. An id it has not seen before is run exactly once. The answer
-- goes to outbox.json as { "id", "ok", "state", "error" }. Nothing is
-- acknowledged that has not been executed, and a command whose answer cannot be
-- produced -- a malformed inbox, a missing field -- is reported as a refusal
-- rather than retried forever.
--
-- THE STARTUP RULE THAT STOPS THE LOOP. An id already present in inbox.json at
-- startup is recorded as ALREADY SEEN and never run. Without that, `restart
-- cis_ctl` would restart, come back up, find its own command still in the inbox,
-- and restart again, forever. The resource is not allowed to be a thing that
-- takes the server down by being asked to restart itself.

local RESOURCE = GetCurrentResourceName()

local POLL_MS = 500
-- The doc's 15 s. Generous on purpose: a stop can take seconds while FiveM
-- tears a resource down, and a harness that reports "stopped" while the resource
-- is still running is worse than a slow one.
local STATE_TIMEOUT_MS = 15000
local STATE_POLL_MS = 100

-- ------------------------------------------------------------------- files

-- Loading the allow-list by path rather than listing it in the manifest, which
-- the design note calls for: the manifest names exactly one server script, so
-- this file is reached at runtime instead. The path comes from the resource
-- root, so it is correct wherever the server data folder lives.
--
-- LOADED WHEN A COMMAND USES IT, NOT ONCE AT START. It was loaded once, and
-- that made a deploy which CHANGED the allow-list invisible until somebody
-- restarted the resource -- which meant the agent either ran through the old
-- rules without noticing, or had to restart the one process it was talking to
-- and lose the bridge mid-run. Both are worse than re-reading a small file a
-- few dozen times per run, which costs nothing and cannot go stale.
--
-- A failed load REFUSES. A cis_ctl that cannot read its rules must not fall
-- back to having none: a bridge that executes anything is strictly worse than
-- no bridge, because the operator would believe the console surface was closed.
local ALLOW_PATH = GetResourcePath(RESOURCE) .. '/server/allow.lua'

local function loadAllow()
    local fh = io.open(ALLOW_PATH, 'rb')
    if not fh then
        return nil, ('allow-list is missing at server/allow.lua')
    end
    local src = fh:read('a')
    fh:close()
    local chunk, err = load(src, '@server/allow.lua', 't')
    if not chunk then
        return nil, ('allow-list failed to load: %s'):format(tostring(err))
    end
    chunk()
    local allow = CisCtlAllow
    CisCtlAllow = nil
    if type(allow) ~= 'table' or type(allow.Check) ~= 'function' then
        return nil, 'allow-list did not define CisCtlAllow.Check'
    end
    return allow
end

-- Checked once at startup so a missing or broken allow-list is loud and early,
-- rather than discovered on the first command an hour later.
do
    local ok, why = loadAllow()
    if not ok then
        print('[cis_ctl] refusing to start: ' .. tostring(why))
        return
    end
end

-- io.open is the reader, and LoadResourceFile the fallback.
--
-- cis_libs_vps_setup.md W2 asks this to be checked rather than assumed: does
-- LoadResourceFile see a file changed on disk while the resource runs? The probe
-- below answers it once, at startup, by writing a file and reading it straight
-- back. io.open is used either way -- it is a real filesystem read with no
-- caching question behind it, and server-side Lua has io. LoadResourceFile stays
-- as the fallback for a build where it does not.
local IO_OK = type(io) == 'table' and type(io.open) == 'function'

local function abs(rel)
    return GetResourcePath(RESOURCE) .. '/' .. rel
end

local function probeNativeSeesDiskWrites()
    if type(LoadResourceFile) ~= 'function' or not IO_OK then return nil end
    local name = 'loadprobe.tmp'
    local body = ('cis_ctl probe %s'):format(tostring(GetGameTimer()))
    local fh = io.open(abs(name), 'wb')
    if not fh then return nil end
    fh:write(body)
    fh:close()
    local ok, seen = pcall(LoadResourceFile, RESOURCE, name)
    os.remove(abs(name))
    if not ok then return false, tostring(seen) end
    return seen == body, seen == body and 'fresh' or 'stale or absent'
end

local function readFile(rel)
    if IO_OK then
        local fh = io.open(abs(rel), 'rb')
        if not fh then return nil end
        local body = fh:read('a')
        fh:close()
        return body
    end
    local ok, body = pcall(LoadResourceFile, RESOURCE, rel)
    if not ok or type(body) ~= 'string' then return nil end
    return body
end

-- Whole-file write through a temp file and a rename, so a reader polling this
-- path never sees half a document. Written with io where io exists, and through
-- SaveResourceFile otherwise.
local function writeFile(rel, body)
    if not IO_OK then
        if type(SaveResourceFile) ~= 'function' then return false end
        local ok, res = pcall(SaveResourceFile, RESOURCE, rel, body, #body)
        return ok and res ~= false, res
    end
    local tmp = rel .. '.tmp'
    local fh = io.open(abs(tmp), 'wb')
    if not fh then return false, 'cannot open ' .. tmp end
    fh:write(body)
    fh:close()
    local renamed = os.rename(abs(tmp), abs(rel))
    if renamed then return true end
    -- os.rename over an existing file fails on some Windows configurations, and
    -- outbox.json always exists after the first command. Fall back to writing
    -- the target directly; fx.js retries a torn read, which is why that is safe.
    local direct = io.open(abs(rel), 'wb')
    if not direct then return false, 'cannot open ' .. rel end
    direct:write(body)
    direct:close()
    os.remove(abs(tmp))
    return true
end

-- -------------------------------------------------------------------- json

-- The only JSON this resource reads is written by tools/fx.js, and the only JSON
-- it writes is two strings and a boolean. A full parser would be more surface
-- for the same result, so the read is a pair of anchored string extractions and
-- the write is a fixed-shape encoder. Anything unexpected is REFUSED: a field
-- this cannot read exactly is not a field to guess at.
local function readInbox(body)
    if type(body) ~= 'string' or body == '' then return nil, 'inbox is empty' end
    local id = body:match('"id"%s*:%s*"([^"]*)"')
    local cmd = body:match('"cmd"%s*:%s*"([^"]*)"')
    if not id or id == '' then return nil, 'inbox has no id' end
    if not cmd then return nil, 'inbox has no cmd' end
    return id, cmd
end

local function jsonEscape(s)
    return (tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"')
        :gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t'))
end

local function encodeOutbox(id, ok, state, err)
    local parts = {
        ('"id":"%s"'):format(jsonEscape(id)),
        ('"ok":%s'):format(ok and 'true' or 'false'),
        ('"state":%s'):format(state and ('"%s"'):format(jsonEscape(state)) or 'null'),
    }
    parts[#parts + 1] = ('"error":%s'):format(
        (err and err ~= '') and ('"%s"'):format(jsonEscape(err)) or 'null')
    return '{' .. table.concat(parts, ',') .. '}'
end

-- --------------------------------------------------------------- execution

local function waitForState(resource, want, timeoutMs)
    local deadline = GetGameTimer() + (timeoutMs or STATE_TIMEOUT_MS)
    while GetGameTimer() < deadline do
        if GetResourceState(resource) == want then return true end
        Wait(STATE_POLL_MS)
    end
    return GetResourceState(resource) == want
end

-- Runs one command. Never raises: a raise inside the poll loop would stop the
-- loop, and a stopped loop is a cis_ctl that silently ignores every later
-- command -- the failure mode where the tool looks alive and does nothing.
local function run(id, cmd)
    local allow, loadWhy = loadAllow()
    if not allow then
        writeFile('outbox.json', encodeOutbox(id, false, nil, loadWhy))
        print(('[cis_ctl] refused %s: %s'):format(id, tostring(loadWhy)))
        return
    end
    local ok, action, resource, args, reason = allow.Check(cmd)
    if not ok then
        writeFile('outbox.json', encodeOutbox(id, false, nil, reason))
        print(('[cis_ctl] refused %s: %s'):format(id, reason))
        return
    end

    -- Restarting cis_ctl kills this thread, so the answer is written BEFORE the
    -- restart rather than after it. Everything else is reported after the
    -- command has been observed to have happened.
    if action == 'restart' and resource == 'cis_ctl' then
        writeFile('outbox.json', encodeOutbox(id, true, 'restarting', nil))
        print(('[cis_ctl] %s: restarting cis_ctl'):format(id))
        ExecuteCommand('restart cis_ctl')
        return
    end

    local command = (action == 'refresh') and 'refresh'
        or (action == 'cis_test') and ('cis_test ' .. args)
        or (action .. ' ' .. resource)

    -- ASK FIRST, BECAUSE A REFUSED COMMAND IS INDISTINGUISHABLE FROM A NO-OP.
    --
    -- `ExecuteCommand` returns void and never sets a result, so from Lua the
    -- only signal a denied command produces is one console line ("Access denied
    -- for command X.") that goes to the server log, not to the caller. So a
    -- denied `stop cis_test` on a resource that was ALREADY stopped looks
    -- exactly like a successful one, and this resource reported it as
    -- `stopped (true)`. The agent read that as the ACEs being in place when the
    -- server had restarted and taken them all -- which is how an entire live run
    -- reported success while running against stale permissions.
    --
    -- Parameter order is (principal, object), which is the opposite of what this
    -- file's own comment used to claim and could not be checked while the ACEs
    -- were absent. Confirmed against FiveM's own native declaration
    -- (ext/native-decls/IsPrincipalAceAllowed.md, namespace CFX, apiset shared).
    if type(IsPrincipalAceAllowed) == 'function' then
        local principal = 'resource.' .. RESOURCE
        local object = 'command.' .. ((action == 'refresh') and 'refresh'
            or (action == 'cis_test') and 'cis_test'
            or action)
        if not IsPrincipalAceAllowed(principal, object) then
            local reason = ('cis_ctl is not allowed to run %q (%s -> %s). Add this '
                .. 'line to server.cfg and restart, or type it into the console: '
                .. 'add_ace %s %s allow'):format(command, principal, object, principal, object)
            writeFile('outbox.json', encodeOutbox(id, false, nil, reason))
            print(('[cis_ctl] refused %s: %s'):format(id, reason))
            return
        end
    end

    ExecuteCommand(command)

    if action == 'refresh' then
        writeFile('outbox.json', encodeOutbox(id, true, 'refreshed', nil))
        return
    end

    if action == 'cis_test' then
        -- No state to poll: cis_test is already running, and the command starts
        -- a thread inside it. Reporting "accepted" and nothing more is the
        -- honest answer -- the run's own results file is the proof that it
        -- happened, and tools/live-run.js waits for exactly that.
        writeFile('outbox.json', encodeOutbox(id, true, 'accepted', nil))
        print(('[cis_ctl] %s: %s'):format(id, command))
        return
    end

    local want = allow.ExpectedState(action)
    local reached = waitForState(resource, want)
    local actual = GetResourceState(resource)
    writeFile('outbox.json', encodeOutbox(id, reached, actual,
        reached and nil or ('expected %s, still %s'):format(tostring(want), tostring(actual))))
    print(('[cis_ctl] %s: %s -> %s (%s)'):format(id, command, tostring(actual), tostring(reached)))
end

-- ------------------------------------------------------------------- loop

-- The id already in the inbox when this resource started. Marked seen, never
-- run: it is almost always the `restart cis_ctl` that brought this instance up.
local lastId = nil
do
    local existing = readFile('inbox.json')
    if existing then
        local id = select(1, readInbox(existing))
        if id then
            lastId = id
            print(('[cis_ctl] started; inbox already holds %s, treated as seen'):format(id))
        end
    end
end

CreateThread(function()
    while true do
        Wait(POLL_MS)
        local ok, err = pcall(function()
            local body = readFile('inbox.json')
            if not body then return end
            local id, cmd = readInbox(body)
            -- A half-written inbox is not an answer. Leave lastId alone so the
            -- command is still pending, and read it again next tick.
            if not id then
                print(('[cis_ctl] inbox not readable yet: %s'):format(tostring(cmd)))
                return
            end
            if id == lastId then return end
            lastId = id
            run(id, cmd)
        end)
        if not ok then
            print(('[cis_ctl] loop error: %s'):format(tostring(err)))
        end
    end
end)

local _, probeWhy = probeNativeSeesDiskWrites()
print(('[cis_ctl] ready. reader=%s LoadResourceFile sees disk writes: %s')
    :format(IO_OK and 'io.open' or 'LoadResourceFile', tostring(probeWhy or 'not probed')))

return true