-- The NUI interface layer (client/interface/*.lua, server/interface.lua),
-- under fengari and a real Lua 5.4, with no game and no browser.
--
-- Same principle as test/client.lua: every native is a stub that RECORDS what
-- it was asked, so a test asserts the effect (SetNuiFocus(false, false) was
-- called, the prop was deleted) rather than "it did not throw".
--
-- ONE DIFFERENCE, AND IT IS THE POINT OF THIS HARNESS: threads are real
-- coroutines. CreateThread makes one; Wait yields it; env.step(n) resumes
-- every live thread n frames. Citizen.Await yields until the promise settles,
-- exactly like the scheduler, so a test can spawn a caller of AlertDialog,
-- look at the focus stack while the dialog is open, answer it through the NUI
-- callback, step once, and read what the caller got back. "The thread exists
-- only while active" is then a count of live coroutines, not an inference.
--
-- Unknown globals are NOT stubbed with a permissive fallback: a native this
-- layer calls that the harness does not know raises, so a new native cannot
-- slip in untested.

local passed, failed = 0, 0
local failures = {}

TEST_CASES = {}

local function check(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = msg
    end
    TEST_CASES[#TEST_CASES + 1] = { name = msg, status = cond and 'passed' or 'failed' }
end

local FILES = {
    'client/interface/nui.lua',
    'client/interface/focus.lua',
    'client/interface/theme.lua',
    'client/interface/notify.lua',
    'client/interface/textui.lua',
    'client/interface/progress.lua',
    'client/interface/alert.lua',
    'client/interface/input.lua',
    'client/interface/context.lua',
    'client/interface/menu.lua',
    'client/interface/radial.lua',
    'client/interface/skillcheck.lua',
}

local function readSource(rel)
    if CIS_TEST_FILES and CIS_TEST_FILES[rel] then
        return CIS_TEST_FILES[rel]
    end
    local f = io.open('./' .. rel, 'r')
    if not f then
        error('interface suite: cannot read ' .. rel, 0)
    end
    local body = f:read('*a')
    f:close()
    return body
end

local function loadModule(rel)
    local chunk, err = load(readSource(rel), '@' .. rel)
    if not chunk then
        error(('%s: %s'):format(rel, tostring(err)), 0)
    end
    chunk()
end

local STUBBED = {
    'CisInterface', 'CisLog', 'exports', 'json', 'promise', 'Citizen', 'source',
    'CreateThread', 'Wait', 'GetGameTimer', 'GetCurrentResourceName', 'GetInvokingResource',
    'SetNuiFocus', 'SetNuiFocusKeepInput', 'SendNuiMessage', 'RegisterNUICallback',
    'RegisterNetEvent', 'AddEventHandler', 'RegisterCommand', 'RegisterKeyMapping',
    'TriggerEvent', 'TriggerServerEvent', 'TriggerClientEvent', 'PlaySoundFrontend',
    'PlayerPedId', 'PlayerId', 'IsEntityDead', 'IsPedRagdoll', 'IsPedCuffed', 'IsPedFalling',
    'IsPedSwimming', 'RequestAnimDict', 'HasAnimDictLoaded', 'RemoveAnimDict', 'TaskPlayAnim',
    'StopAnimTask', 'IsEntityPlayingAnim', 'TaskStartScenarioInPlace', 'ClearPedTasks',
    'IsModelValid', 'RequestModel', 'HasModelLoaded', 'SetModelAsNoLongerNeeded',
    'GetEntityCoords', 'CreateObject', 'AttachEntityToEntity', 'GetPedBoneIndex',
    'DoesEntityExist', 'DetachEntity', 'DeleteEntity', 'DisableControlAction',
    'DisablePlayerFiring', 'IsControlJustPressed', 'IsDisabledControlJustPressed',
    'IsDisabledControlPressed', 'IsPauseMenuActive', 'joaat', 'GetPlayerName',
}

local function newEnv()
    local env = {
        saved = {},
        clock = 0,
        invoking = nil,
        threads = {},
        threadErrors = {},
        nui = {},
        messages = {},
        focusCalls = {},
        keepCalls = {},
        handlers = {},
        netEvents = {},
        commands = {},
        mappings = {},
        events = {},
        sounds = {},
        flags = {},
        pressed = {},
        held = {},
        disabled = {},
        anims = {},
        stoppedAnims = {},
        scenarios = {},
        clearedTasks = 0,
        created = {},
        deleted = {},
        logged = {},
        nextEntity = 1000,
    }
    for _, name in ipairs(STUBBED) do
        env.saved[#env.saved + 1] = { name = name, value = rawget(_G, name) }
    end
    CisInterface = nil

    function CisLog(level, message)
        env.logged[#env.logged + 1] = { level = level, message = message }
    end

    -- ------------------------------------------------------------ scheduler
    local function resume(co)
        local ok, err = coroutine.resume(co)
        if not ok then
            env.threadErrors[#env.threadErrors + 1] = tostring(err)
        end
    end
    function CreateThread(fn)
        local co = coroutine.create(fn)
        env.threads[#env.threads + 1] = co
    end
    -- A caller: started at once (like a script calling an export), parked by
    -- Await, and resumed by step().
    function env.spawn(fn)
        local co = coroutine.create(fn)
        env.threads[#env.threads + 1] = co
        resume(co)
        return co
    end
    function Wait(ms)
        env.clock = env.clock + (tonumber(ms) or 0)
        local _, main = coroutine.running()
        if not main then
            coroutine.yield()
        end
    end
    function env.step(frames)
        for _ = 1, frames or 1 do
            local list = env.threads
            env.threads = {}
            for _, co in ipairs(list) do
                if coroutine.status(co) == 'suspended' then
                    resume(co)
                end
            end
            for _, co in ipairs(list) do
                if coroutine.status(co) ~= 'dead' then
                    env.threads[#env.threads + 1] = co
                end
            end
        end
    end
    function env.live()
        local n = 0
        for _, co in ipairs(env.threads) do
            if coroutine.status(co) ~= 'dead' then n = n + 1 end
        end
        return n
    end

    promise = {
        new = function()
            local p = { done = false }
            function p.resolve(self, v)
                if self.done then return end
                self.done, self.value = true, v
            end
            function p.reject(self, v)
                if self.done then return end
                self.done, self.value, self.rejected = true, v, true
            end
            return p
        end,
    }
    Citizen = {
        Await = function(p)
            local _, main = coroutine.running()
            if main then
                error('Citizen.Await outside a thread', 2)
            end
            while not p.done do
                coroutine.yield()
            end
            if p.rejected then error(p.value, 2) end
            return p.value
        end,
    }

    function GetGameTimer() return env.clock end
    function GetCurrentResourceName() return 'cis_libs' end
    function GetInvokingResource() return env.invoking end

    -- ------------------------------------------------------------ NUI
    function SetNuiFocus(focus, cursor)
        env.focusCalls[#env.focusCalls + 1] = { focus = focus, cursor = cursor }
        env.focus = { focus = focus, cursor = cursor }
    end
    function SetNuiFocusKeepInput(keep)
        env.keepCalls[#env.keepCalls + 1] = keep
        env.keep = keep
    end
    json = { encode = function(t) return t end }
    function SendNuiMessage(m)
        if env.failSend and m.action == env.failSend then
            error('json.encode: cannot encode', 0)
        end
        env.messages[#env.messages + 1] = m
    end
    function RegisterNUICallback(name, fn)
        env.nui[name] = fn
    end
    -- What the page does: POST a body to a callback. Returns the reply.
    function env.post(name, data)
        local reply
        local fn = env.nui[name]
        if not fn then error('no NUI callback ' .. tostring(name), 2) end
        fn(data, function(r) reply = r end)
        return reply
    end
    function env.msgs(action)
        local out = {}
        for _, m in ipairs(env.messages) do
            if m.action == action then out[#out + 1] = m.data end
        end
        return out
    end
    function env.last(action)
        local list = env.msgs(action)
        return list[#list]
    end

    -- ------------------------------------------------------------ events
    function AddEventHandler(name, fn)
        env.handlers[name] = env.handlers[name] or {}
        env.handlers[name][#env.handlers[name] + 1] = fn
    end
    function RegisterNetEvent(name, fn)
        env.netEvents[name] = fn
    end
    function env.fire(name, ...)
        for _, fn in ipairs(env.handlers[name] or {}) do fn(...) end
    end
    function env.net(name, src, ...)
        source = src
        env.netEvents[name](...)
        source = nil
    end
    function TriggerEvent(name, ...)
        env.events[#env.events + 1] = { kind = 'local', name = name, args = table.pack(...) }
    end
    function TriggerServerEvent(name, ...)
        env.events[#env.events + 1] = { kind = 'server', name = name, args = table.pack(...) }
    end
    function TriggerClientEvent(name, target, ...)
        env.events[#env.events + 1] = { kind = 'client', name = name, target = target, args = table.pack(...) }
    end
    function RegisterCommand(name, fn)
        env.commands[name] = fn
    end
    function RegisterKeyMapping(command, description, mapper, key)
        env.mappings[#env.mappings + 1] = { command = command, description = description, mapper = mapper, key = key }
    end
    function PlaySoundFrontend(id, name, set)
        env.sounds[#env.sounds + 1] = { id = id, name = name, set = set }
    end

    -- ------------------------------------------------------------ the ped
    function PlayerPedId() return 1 end
    function PlayerId() return 0 end
    function IsEntityDead() return env.flags.dead == true end
    function IsPedRagdoll() return env.flags.ragdoll == true end
    function IsPedCuffed() return env.flags.cuffed == true end
    function IsPedFalling() return env.flags.falling == true end
    function IsPedSwimming() return env.flags.swimming == true end
    function RequestAnimDict() end
    function HasAnimDictLoaded() return env.flags.dictMissing ~= true end
    function RemoveAnimDict(dict) env.removedDict = dict end
    function TaskPlayAnim(ped, dict, clip, blendIn, blendOut, duration, flag)
        env.anims[#env.anims + 1] = { ped = ped, dict = dict, clip = clip, flag = flag, duration = duration }
    end
    function StopAnimTask(ped, dict, clip)
        env.stoppedAnims[#env.stoppedAnims + 1] = { ped = ped, dict = dict, clip = clip }
    end
    function IsEntityPlayingAnim() return env.flags.animStopped ~= true end
    function TaskStartScenarioInPlace(ped, name)
        env.scenarios[#env.scenarios + 1] = name
    end
    function ClearPedTasks() env.clearedTasks = env.clearedTasks + 1 end
    function IsModelValid() return true end
    function RequestModel() end
    function HasModelLoaded() return true end
    function SetModelAsNoLongerNeeded() end
    function GetEntityCoords() return { x = 1.0, y = 2.0, z = 3.0 } end
    function CreateObject(model)
        env.nextEntity = env.nextEntity + 1
        env.created[#env.created + 1] = { handle = env.nextEntity, model = model }
        env.alive = env.alive or {}
        env.alive[env.nextEntity] = true
        return env.nextEntity
    end
    function AttachEntityToEntity(obj, ped, bone)
        env.attached = env.attached or {}
        env.attached[#env.attached + 1] = { obj = obj, ped = ped, bone = bone }
    end
    function GetPedBoneIndex(_, bone) return bone end
    function DoesEntityExist(h) return env.alive ~= nil and env.alive[h] == true end
    function DetachEntity() end
    function DeleteEntity(h)
        env.deleted[#env.deleted + 1] = h
        if env.alive then env.alive[h] = nil end
    end
    function joaat(s)
        local h = 0
        for i = 1, #s do h = (h * 31 + s:byte(i)) % 0x7FFFFFFF end
        return h
    end

    -- ------------------------------------------------------------ controls
    function DisableControlAction(_, control)
        env.disabled[control] = (env.disabled[control] or 0) + 1
    end
    function DisablePlayerFiring() env.firingDisabled = (env.firingDisabled or 0) + 1 end
    -- A press is consumed by the first query, like a one-frame edge.
    local function take(control)
        if env.pressed[control] then
            env.pressed[control] = nil
            return true
        end
        return false
    end
    function IsControlJustPressed(_, control) return take(control) end
    function IsDisabledControlJustPressed(_, control) return take(control) end
    function IsDisabledControlPressed(_, control) return env.held[control] == true end
    function IsPauseMenuActive() return false end

    function GetPlayerName(id) return (id == 7 and 'seven') or nil end

    -- ------------------------------------------------------------ exports
    local EXPORTS = setmetatable({}, { __call = function(t, name, fn) rawset(t, name, fn) end })
    exports = EXPORTS
    env.X = EXPORTS

    function env.reset()
        for i = #env.saved, 1, -1 do
            rawset(_G, env.saved[i].name, env.saved[i].value)
        end
    end

    function env.load(ready)
        for _, rel in ipairs(FILES) do loadModule(rel) end
        if ready ~= false then
            env.post('ready', {})
        end
    end

    return env
end

local function lastFocus(env)
    return env.focusCalls[#env.focusCalls]
end

-- ===================================================== 1. the focus stack
do
    local env = newEnv()
    env.load()
    local F = CisInterface.focus

    check(#env.focusCalls == 0, 'focus: loading the layer touches no focus native (idle cost zero)')
    check(env.live() == 0, 'focus: loading the layer starts no thread')

    F.push('a', {})
    check(lastFocus(env).focus == true and lastFocus(env).cursor == true, 'focus: first push takes focus with a cursor')
    check(env.keep == nil, 'focus: keepInput untouched while it stays false')

    F.push('b', { keepInput = true })
    check(env.keep == true, 'focus: a keepInput entry on top sets SetNuiFocusKeepInput(true)')
    local calls = #env.focusCalls
    check(calls == 1, 'focus: second push with the same focus/cursor issues no redundant SetNuiFocus')

    F.pop('b')
    check(env.keep == false, 'focus: popping the keepInput entry restores keepInput false for the one below')
    check(lastFocus(env).focus == true, 'focus: the entry below still holds focus')

    F.push('b', {})
    F.pop('a')
    check(F.top() == 'b' and lastFocus(env).focus == true, 'focus: popping from the middle leaves the top in charge')

    F.pop('b')
    check(lastFocus(env).focus == false and lastFocus(env).cursor == false, 'focus: an empty stack releases focus and cursor')
    check(F.pop('nothing') == false, 'focus: popping an unknown key is a no-op')

    local escaped = {}
    F.push('low', { onEscape = function() escaped[#escaped + 1] = 'low' end })
    F.push('high', { onEscape = function() escaped[#escaped + 1] = 'high' end })
    F.push('nohandler', {})
    F.escape()
    check(escaped[1] == 'high' and #escaped == 1, 'focus: Escape goes to the topmost entry WITH a handler, only that one')

    F.push('boom', { onEscape = function() error('kaboom') end })
    F.escape()
    check(not F.has('boom'), 'focus: an escape handler that raises is popped, so focus cannot strand')

    F.push('owned', { owner = 'res_x' })
    env.fire('onResourceStop', 'res_x')
    check(not F.has('owned') and F.has('high'), 'focus: an owner stopping pops only its entries')

    env.fire('onResourceStop', 'cis_libs')
    check(#F.stack() == 0 and lastFocus(env).focus == false, 'focus: cis_libs stopping clears the stack and releases focus')
    check(env.keep == false, 'focus: and keepInput is forced back off')
    env.reset()
end

-- ===================================================== 2. NUI bridge: ready, buffering, validation
do
    local env = newEnv()
    env.load(false)
    check(env.X.Toast({ description = 'early' }) == true, 'bridge: a toast before the page loads is accepted')
    check(#env.messages == 0, 'bridge: nothing is sent to a page that has not loaded')
    env.X.SetUiTheme({ accent = '#ff0000' })
    env.post('ready', {})
    check(env.messages[1] and env.messages[1].action == 'init', 'bridge: ready is answered with init first')
    check(env.messages[1].data.theme.accent == '#ff0000', 'bridge: init carries the theme set before load')
    local early = env.msgs('notify')
    check(#early == 1 and early[1].description == 'early', 'bridge: the buffered toast is delivered after init')

    for _, bad in ipairs({ 'string', 42, true }) do
        local reply = env.post('alert', bad)
        check(reply and reply.ok == false, ('bridge: a %s body is rejected'):format(type(bad)))
    end
    local before = CisInterface.stats.rejected
    check(env.post('alert', { id = 'x', result = 'confirm' }).ok == false, 'bridge: a string id is rejected')
    check(env.post('alert', { id = 1.5, result = 'confirm' }).ok == false, 'bridge: a fractional id is rejected')
    check(env.post('alert', { result = 'confirm' }).ok == false, 'bridge: a missing id is rejected')
    check(env.post('alert', { id = 1, result = {} }).ok == false, 'bridge: a mistyped field is rejected')
    check(env.post('context', { token = 1, action = 'select', index = 'one' }).ok == false,
        'bridge: an optional field with the wrong type is rejected')
    check(CisInterface.stats.rejected == before + 5, 'bridge: every rejection is counted')
    check(env.post('alert', { id = 999, result = 'confirm' }).ok == true,
        'bridge: a well-formed payload for an unknown id is accepted and ignored')
    local long = string.rep('x', 5000)
    check(env.post('error', { message = long }).ok == false, 'bridge: an over-long string is rejected')

    -- I.str keeps strings UTF-8 safe, so json.encode cannot raise on them.
    local s = CisInterface.str('\255\254abc')
    check(s == '??abc', 'bridge: invalid UTF-8 bytes are replaced, not sent')
    local cut = CisInterface.str('ééé', 2)
    check(cut == 'éé', 'bridge: truncation counts characters, never splits one')
    env.reset()
end

-- ===================================================== 3. alert dialog
do
    local env = newEnv()
    env.load()
    local got
    env.invoking = 'res_a'
    env.spawn(function() got = { env.X.AlertDialog({ header = 'Sure?', content = '**bold**', cancel = true }) } end)
    env.invoking = nil
    local open = env.last('alert:open')
    check(open and open.header == 'Sure?' and open.cancel == true, 'alert: the page is asked to open it')
    check(CisInterface.focus.top() == 'alert' and lastFocus(env).focus == true, 'alert: it pushes focus while open')
    check(got == nil, 'alert: the caller is parked until it is answered')
    local again = {}
    env.spawn(function() again = { env.X.AlertDialog({ header = 'second' }) } end)
    check(again[1] == nil and again[2] == 'an alert dialog is already open', 'alert: a second one is refused, not stacked')

    env.post('alert', { id = open.id + 1, result = 'confirm' })
    env.step()
    check(got == nil, 'alert: an answer for another id does not settle it')
    env.post('alert', { id = open.id, result = 'confirm' })
    env.step()
    check(got and got[1] == 'confirm', 'alert: confirm resolves the caller with "confirm"')
    check(lastFocus(env).focus == false, 'alert: focus is released when it closes')
    check(env.last('alert:close').id == open.id, 'alert: the page is told to close it')

    env.spawn(function() got = { env.X.AlertDialog({ header = 'x' }) } end)
    env.post('alert', { id = env.last('alert:open').id, result = 'something-else' })
    env.step()
    check(got[1] == 'cancel', 'alert: any result other than confirm is cancel')

    env.spawn(function() got = { env.X.AlertDialog({ header = 'x' }) } end)
    env.post('escape', {})
    env.step()
    check(got[1] == 'cancel' and lastFocus(env).focus == false, 'alert: Escape resolves it as cancel and releases focus')

    env.spawn(function() got = { env.X.AlertDialog({ header = 'x' }) } end)
    check(env.X.CloseAlertDialog() == true, 'alert: CloseAlertDialog closes the open one')
    env.step()
    check(got[1] == 'cancel', 'alert: CloseAlertDialog resolves the caller as cancel')
    check(env.X.CloseAlertDialog() == false, 'alert: CloseAlertDialog with nothing open is false')

    env.invoking = 'res_b'
    env.spawn(function() got = { env.X.AlertDialog({ header = 'owned' }) } end)
    env.invoking = nil
    env.fire('onResourceStop', 'someone_else')
    env.step()
    check(CisInterface.focus.top() == 'alert', 'alert: another resource stopping leaves it open')
    env.fire('onResourceStop', 'res_b')
    env.step()
    check(got[1] == 'cancel' and lastFocus(env).focus == false, 'alert: its caller stopping cancels it and releases focus')

    local bad = { env.X.AlertDialog('nope') }
    check(bad[1] == nil and type(bad[2]) == 'string', 'alert: a non-table is refused with a reason')

    -- The page reloading: what it showed is gone, so the caller must not hang.
    env.spawn(function() got = { env.X.AlertDialog({ header = 'reload' }) } end)
    env.post('ready', {})
    env.step()
    check(got[1] == 'cancel' and lastFocus(env).focus == false, 'alert: a page reload cancels it and releases focus')
    check(#env.threadErrors == 0, 'alert: no thread raised (' .. tostring(env.threadErrors[1]) .. ')')
    env.reset()
end

-- ===================================================== 4. input dialog
do
    local env = newEnv()
    env.load()
    local got
    local rows = {
        'Name',
        { type = 'number', label = 'Age', required = true, min = 1, max = 120 },
        { type = 'checkbox', label = 'Agree' },
        { type = 'select', label = 'Pick', options = { { value = 'a', label = 'A' }, { value = 'b' } }, onSelect = function() end },
        { type = 'multi-select', label = 'Many', options = { 'x', 'y' } },
        { type = 'date-range', label = 'When' },
    }
    env.spawn(function() got = { env.X.InputDialog('Form', rows, { allowCancel = true }) } end)
    local open = env.last('input:open')
    check(open and #open.rows == 6, 'input: every row is sent')
    check(open.rows[1].type == 'input' and open.rows[1].label == 'Name', 'input: a string row becomes a text input')
    check(open.rows[4].onSelect == nil and open.rows[4].options[2].label == 'b', 'input: rows are copied field by field (no functions cross)')

    local function answer(values)
        env.post('input', { id = open.id, values = values })
        env.step()
    end
    answer({ 'Bob', 'thirty', false, 'a', {}, { '2026-01-01', '2026-01-02' } })
    check(got == nil, 'input: a value of the wrong type is ignored and the dialog stays open')
    answer({ 'Bob', nil, false, 'a', {}, nil })
    check(got == nil, 'input: a missing required value is ignored')
    answer({ 'Bob', 30, false, 'zzz', {}, nil })
    check(got == nil, 'input: a select value that was not offered is ignored')
    answer({ 'Bob', 30, false, 'a', { 'x', 'nope' }, nil })
    check(got == nil, 'input: a multi-select value that was not offered is ignored')
    answer({ 'Bob', 30, true, 'b', { 'y' }, { '2026-01-01', '2026-01-02' } })
    check(got and got[1] and got[1][1] == 'Bob' and got[1][2] == 30 and got[1][3] == true
        and got[1][4] == 'b' and got[1][5][1] == 'y' and got[1][6][2] == '2026-01-02',
        'input: a valid answer resolves the caller with one value per row')
    check(lastFocus(env).focus == false, 'input: focus released on submit')

    env.spawn(function() got = { env.X.InputDialog('Form', { 'a' }) } end)
    env.post('input', { id = env.last('input:open').id, cancelled = true })
    env.step()
    check(got[1] == nil and lastFocus(env).focus == false, 'input: cancel resolves nil and releases focus')

    env.spawn(function() got = { env.X.InputDialog('Form', { 'a' }, { allowCancel = false }) } end)
    env.post('escape', {})
    env.step()
    check(CisInterface.focus.top() == 'input', 'input: Escape does nothing when allowCancel is false')
    env.X.CloseInputDialog()
    env.step()
    check(got[1] == nil and lastFocus(env).focus == false, 'input: CloseInputDialog still closes it')

    local r = { env.X.InputDialog('x', {}) }
    check(r[1] == nil and type(r[2]) == 'string', 'input: no rows is refused with a reason')
    env.reset()
end

-- ===================================================== 5. progress
do
    local env = newEnv()
    env.load()
    local got
    check(env.live() == 0, 'progress: no thread before one starts')
    env.invoking = 'res_p'
    env.spawn(function()
        got = { env.X.ProgressBar({
            duration = 1000, label = 'Working', canCancel = true,
            anim = { dict = 'amb@x', clip = 'idle' },
            prop = { { model = 'prop_a', bone = 18905 }, { model = 'prop_b' } },
            disable = { move = true, combat = true },
        }) }
    end)
    env.invoking = nil
    check(env.X.ProgressActive() == true, 'progress: active while running')
    check(env.live() == 2, 'progress: exactly one frame thread (plus the parked caller) while active')
    check(#env.created == 2 and env.attached[1].bone == 18905, 'progress: both props spawned and attached to the asked bone')
    check(env.attached[2].bone == 60309, 'progress: a prop with no bone uses the default hand bone')
    check(env.anims[1] and env.anims[1].dict == 'amb@x' and env.anims[1].flag == 49, 'progress: the animation is played with the default flag')
    local start = env.last('progress:start')
    check(start and start.kind == 'bar' and start.duration == 1000 and start.canCancel == true, 'progress: the page is told to draw a bar')

    env.step(2)
    check((env.disabled[30] or 0) >= 2 and (env.disabled[24] or 0) >= 2, 'progress: move and combat controls are disabled every frame')
    check((env.firingDisabled or 0) >= 2, 'progress: firing is disabled every frame when combat is')
    check(env.disabled[71] == nil, 'progress: a group not asked for (car) is left alone')

    local again = { env.X.ProgressCircle({ duration = 10 }) }
    check(again[1] == false and again[2] == 'a progress is already running', 'progress: a second one is refused')

    env.flags.animStopped = true
    env.step()
    check(#env.anims >= 2, 'progress: an animation something else stopped is played again')
    env.flags.animStopped = nil

    env.clock = env.clock + 1000
    env.step()
    env.step()
    check(got and got[1] == true, 'progress: completion resolves true')
    check(env.live() == 0, 'progress: the frame thread is gone once it finishes')
    check(#env.deleted == 2, 'progress: both props deleted on completion')
    check(env.stoppedAnims[1] and env.stoppedAnims[1].clip == 'idle' and env.removedDict == 'amb@x',
        'progress: the animation is stopped and its dictionary released')
    check(env.last('progress:stop').completed == true, 'progress: the page is told it completed')

    -- cancel key
    env.created, env.deleted, env.stoppedAnims = {}, {}, {}
    env.spawn(function() got = { env.X.ProgressCircle({ duration = 5000, canCancel = true, prop = { model = 'p' } }) } end)
    env.step()
    env.pressed[73] = true
    env.step(2)
    check(got[1] == false, 'progress: X cancels when canCancel')
    check(#env.deleted == 1 and env.live() == 0, 'progress: the prop is deleted and the thread ends on cancel')

    -- the cancel key does nothing when canCancel is off
    env.spawn(function() got = { env.X.ProgressBar({ duration = 5000 }) } end)
    env.pressed[73] = true
    env.step(2)
    check(env.X.ProgressActive() == true, 'progress: X is ignored without canCancel')
    check(env.X.CancelProgress() == true, 'progress: CancelProgress cancels it')
    env.step()
    check(got[1] == false and env.live() == 0, 'progress: CancelProgress resolves false and ends the thread')
    check(env.X.CancelProgress() == false, 'progress: CancelProgress with nothing running is false')

    -- interruption
    env.spawn(function() got = { env.X.ProgressBar({ duration = 5000 }) } end)
    env.flags.ragdoll = true
    env.step(2)
    check(got[1] == false, 'progress: ragdolling interrupts it unless allowRagdoll')
    env.spawn(function() got = { env.X.ProgressBar({ duration = 50, allowRagdoll = true }) } end)
    env.step()
    check(env.X.ProgressActive() == true, 'progress: allowRagdoll keeps it running while ragdolled')
    env.flags.ragdoll = nil
    env.clock = env.clock + 100
    env.step(2)
    check(got[1] == true, 'progress: and it completes')
    env.flags.dead = true
    local dead = { env.X.ProgressBar({ duration = 10 }) }
    check(dead[1] == false, 'progress: refused while dead unless useWhileDead')
    env.flags.dead = nil

    -- scenario, then the caller stopping
    env.created, env.deleted = {}, {}
    env.invoking = 'res_s'
    env.spawn(function() got = { env.X.ProgressBar({ duration = 5000, anim = { scenario = 'WORLD_HUMAN_HAMMERING' }, prop = { model = 'hammer' } }) } end)
    env.invoking = nil
    check(env.scenarios[1] == 'WORLD_HUMAN_HAMMERING', 'progress: a scenario is started')
    local cleared = env.clearedTasks
    env.fire('onResourceStop', 'res_s')
    env.step(2)
    check(got[1] == false, 'progress: the calling resource stopping cancels it')
    check(#env.deleted == 1 and env.clearedTasks == cleared + 1, 'progress: and its prop and scenario are cleaned up')
    check(env.live() == 0, 'progress: and its thread ends')

    -- cis_libs itself stopping
    env.created, env.deleted = {}, {}
    env.spawn(function() got = { env.X.ProgressBar({ duration = 5000, prop = { model = 'z' } }) } end)
    env.fire('onResourceStop', 'cis_libs')
    env.step(2)
    check(got[1] == false and #env.deleted == 1, 'progress: cis_libs stopping cleans up too')
    check(#env.threadErrors == 0, 'progress: no thread raised (' .. tostring(env.threadErrors[1]) .. ')')
    env.reset()
end

-- ===================================================== 6. skill check
do
    local env = newEnv()
    env.load()
    local got
    env.spawn(function() got = { env.X.SkillCheck({ 'easy', { areaSize = 30, speedMultiplier = 2 } }, { 'w', 'A' }) } end)
    local start = env.last('skill:start')
    check(start and #start.rounds == 2 and start.rounds[1] == 'easy' and start.rounds[2].areaSize == 30,
        'skill: the rounds are sent')
    check(start.keys[2] == 'a', 'skill: key names are normalised to lower case')
    check(env.X.SkillCheckActive() == true and env.live() == 2, 'skill: active, with one input thread')
    check(#env.focusCalls == 0, 'skill: the game keeps focus (no NUI focus taken)')
    env.pressed[34] = true
    env.step()
    check(env.last('skill:key') and env.last('skill:key').key == 'a', 'skill: a press is forwarded to the page')
    check((env.disabled[32] or 0) >= 1 and (env.disabled[24] or 0) >= 1, 'skill: its keys and attack are disabled while active')
    env.post('skill', { id = start.id + 7, success = true })
    env.step()
    check(got == nil, 'skill: a result for another id is ignored')
    env.post('skill', { id = start.id, success = true })
    env.step(2)
    check(got and got[1] == true, 'skill: success resolves true')
    check(env.live() == 0, 'skill: the input thread is gone afterwards')

    env.spawn(function() got = { env.X.SkillCheck('hard') } end)
    env.post('skill', { id = env.last('skill:start').id, success = false })
    env.step()
    check(got[1] == false, 'skill: failure resolves false')

    env.spawn(function() got = { env.X.SkillCheck('medium') } end)
    check(env.X.CancelSkillCheck() == true, 'skill: CancelSkillCheck cancels it')
    env.step(2)
    check(got[1] == false and env.live() == 0, 'skill: cancelled resolves false and the thread ends')

    local bad = { env.X.SkillCheck('impossible') }
    check(bad[1] == false and type(bad[2]) == 'string', 'skill: an unknown difficulty is refused')
    local badKey = { env.X.SkillCheck('easy', { 'f12' }) }
    check(badKey[1] == false, 'skill: an unsupported key is refused')

    env.invoking = 'res_k'
    env.spawn(function() got = { env.X.SkillCheck('easy') } end)
    env.invoking = nil
    env.fire('onResourceStop', 'res_k')
    env.step(2)
    check(got[1] == false and env.live() == 0, 'skill: its caller stopping resolves false and ends the thread')
    env.reset()
end

-- ===================================================== 7. text UI and notify
do
    local env = newEnv()
    env.load()
    env.invoking = 'res_t'
    check(env.X.ShowTextUI('[E] Open', { position = 'left-center', key = 'E' }) == true, 'textui: shows')
    env.invoking = nil
    local shown = env.last('textui:show')
    check(shown.position == 'left-center' and shown.key == 'E', 'textui: options are sent')
    local open, text = env.X.IsTextUIOpen()
    check(open == true and text == '[E] Open', 'textui: isOpen answers true and the text')
    check(env.X.ShowTextUI('') == false, 'textui: empty text is refused')
    env.post('ready', {})
    check(#env.msgs('textui:show') == 2, 'textui: re-drawn after a page reload')
    env.fire('onResourceStop', 'res_t')
    check(env.X.IsTextUIOpen() == false and env.last('textui:hide') ~= nil, 'textui: hidden when the resource that showed it stops')
    check(env.X.HideTextUI() == true, 'textui: hiding nothing is still true')

    check(env.X.Toast({ title = 'T', description = 'D', type = 'info', duration = 10, position = 'nowhere',
        sound = { name = 'SELECT', set = 'HUD_FRONTEND_DEFAULT_SOUNDSET' } }) == true, 'notify: accepted')
    local n = env.last('notify')
    check(n.type == 'inform' and n.duration == 500 and n.position == nil, 'notify: info aliases inform, duration clamps, an unknown position is dropped')
    check(env.sounds[1] and env.sounds[1].name == 'SELECT', 'notify: the sound is played')
    check(env.X.Toast({}) == false, 'notify: no title and no description is refused')
    check(env.X.Toast('plain') == true and env.last('notify').description == 'plain', 'notify: a string is the description')

    local count = #env.msgs('notify')
    env.net('cis_libs:client:uiNotify', 65535, { description = 'from server' })
    check(#env.msgs('notify') == count + 1, 'notify: the net event from the server (numeric source) is shown')
    env.net('cis_libs:client:uiNotify', '', { description = 'spoofed' })
    check(#env.msgs('notify') == count + 1, 'notify: the same event raised locally (empty source) is ignored')
    env.reset()
end

-- ===================================================== 8. context menus
do
    local env = newEnv()
    env.load()
    local selected, exited, backs = {}, 0, 0
    env.invoking = 'res_c'
    local ok = env.X.RegisterContext({
        {
            id = 'main', title = 'Main', onExit = function() exited = exited + 1 end,
            options = {
                { title = 'Run', onSelect = function(args) selected[#selected + 1] = args end, args = { n = 1 },
                  event = 'my:event', serverEvent = 'my:server', metadata = { Weight = '2kg' } },
                { title = 'Off', disabled = true, onSelect = function() selected[#selected + 1] = 'disabled' end },
                { title = 'Info', readOnly = true, serverEvent = 'never' },
                { title = 'More', menu = 'sub' },
            },
        },
        { id = 'sub', title = 'Sub', menu = 'main', onBack = function() backs = backs + 1 end, options = { { title = 'Leaf' } } },
        { id = 'locked', title = 'Locked', canClose = false, options = {} },
    })
    env.invoking = nil
    check(ok == true, 'context: a list of contexts registers')
    local badOk, badErr = env.X.RegisterContext({ id = 'bad', options = { { title = 'x', onSelect = 'notafunction' } } })
    check(badOk == false and type(badErr) == 'string', 'context: a non-callable onSelect is refused')
    check(env.X.ShowContext('nope') == false, 'context: an unknown id is refused')

    check(env.X.ShowContext('main') == true, 'context: shows')
    local open = env.last('context:open')
    check(open.title == 'Main' and #open.options == 4 and open.options[4].hasMenu == true, 'context: options are sent')
    check(open.options[1].onSelect == nil and open.options[1].serverEvent == nil and open.options[1].args == nil,
        'context: no handler, event name or args reaches the page')
    check(open.options[1].metadata[1].label == 'Weight' and open.options[1].metadata[1].value == '2kg', 'context: map metadata becomes label/value rows')
    check(env.X.GetOpenContextMenu() == 'main' and CisInterface.focus.top() == 'context', 'context: open, and holding focus')

    env.post('context', { token = open.token, action = 'select', index = 2 })
    check(#selected == 0 and env.X.GetOpenContextMenu() == 'main', 'context: a disabled option cannot be selected from the page')
    env.post('context', { token = open.token, action = 'select', index = 3 })
    check(#env.events == 0, 'context: a read-only option fires nothing')
    env.post('context', { token = open.token, action = 'select', index = 99 })
    env.post('context', { token = open.token + 50, action = 'select', index = 1 })
    env.post('context', { token = open.token, action = 'select', index = 1, event = 'evil:event', serverEvent = 'evil:server' })
    check(#selected == 1 and selected[1].n == 1, 'context: a valid select runs onSelect with args; bad index and stale token do not')
    local server = {}
    for _, e in ipairs(env.events) do if e.kind == 'server' then server[#server + 1] = e end end
    check(#server == 1 and server[1].name == 'my:server' and server[1].args[1].n == 1,
        'context: serverEvent is the REGISTERED name, fired by the client with args; names in the payload are ignored')
    check(env.events[1].kind == 'local' and env.events[1].name == 'my:event', 'context: event fires as a local event')
    check(env.X.GetOpenContextMenu() == nil and lastFocus(env).focus == false, 'context: selecting closes it and releases focus')

    env.X.ShowContext('main')
    env.post('context', { token = env.last('context:open').token, action = 'select', index = 4 })
    check(env.X.GetOpenContextMenu() == 'sub' and env.last('context:open').hasBack == true, 'context: a submenu option opens the submenu with a back button')
    env.post('context', { token = env.last('context:open').token, action = 'back' })
    check(backs == 1 and env.X.GetOpenContextMenu() == 'main', 'context: back runs onBack and returns to the parent')

    -- context + alert: Escape closes the top one only
    local got
    env.spawn(function() got = { env.X.AlertDialog({ header = 'over the menu' }) } end)
    check(CisInterface.focus.top() == 'alert', 'context+alert: the dialog is on top of the menu')
    env.post('escape', {})
    env.step()
    check(got[1] == 'cancel' and env.X.GetOpenContextMenu() == 'main', 'context+alert: Escape cancels the dialog and leaves the menu')
    check(lastFocus(env).focus == true, 'context+alert: the menu keeps focus after the dialog closes')
    env.post('escape', {})
    check(env.X.GetOpenContextMenu() == nil and exited == 1, 'context+alert: a second Escape closes the menu and runs onExit')
    check(lastFocus(env).focus == false, 'context+alert: focus released at the bottom of the stack')

    env.X.ShowContext('locked')
    env.post('escape', {})
    env.post('context', { token = env.last('context:open').token, action = 'close' })
    check(env.X.GetOpenContextMenu() == 'locked', 'context: canClose = false ignores Escape and the close button')
    check(env.X.HideContext(false) == true and env.X.GetOpenContextMenu() == nil, 'context: HideContext still closes it')

    env.X.ShowContext('main')
    env.X.HideContext(true)
    check(exited == 2, 'context: HideContext(true) runs onExit')

    -- ownership
    env.invoking = 'res_other'
    env.X.RegisterContext({ id = 'theirs', options = {} })
    env.invoking = nil
    env.X.ShowContext('main')
    env.fire('onResourceStop', 'res_c')
    check(env.X.GetOpenContextMenu() == nil and lastFocus(env).focus == false, 'context: the owner stopping closes its open menu and releases focus')
    check(exited == 2, 'context: without calling into the stopped resource (no onExit)')
    check(env.X.ShowContext('main') == false and env.X.ShowContext('sub') == false, 'context: and unregisters all of its menus')
    check(env.X.ShowContext('theirs') == true, 'context: another resource\'s menu survives')
    env.reset()
end

-- ===================================================== 9. list menu
do
    local env = newEnv()
    env.load()
    local log = {}
    env.invoking = 'res_m'
    env.X.RegisterMenu({
        id = 'list', title = 'List',
        options = {
            { label = 'First', args = 'a1' },
            { label = 'Scroll', values = { 'x', { label = 'y', description = 'why' } }, args = 'a2' },
            { label = 'Toggle', checked = false, args = 'a3' },
            { label = 'Stay', close = false, args = 'a4' },
        },
        onSelected = function(sel) log[#log + 1] = 'sel' .. sel end,
        onSideScroll = function(sel, idx) log[#log + 1] = ('side%d:%d'):format(sel, idx) end,
        onCheck = function(sel, checked) log[#log + 1] = ('check%d:%s'):format(sel, tostring(checked)) end,
        onClose = function(key) log[#log + 1] = 'close:' .. tostring(key) end,
    }, function(sel, scroll, args) log[#log + 1] = ('cb%d:%s:%s'):format(sel, tostring(scroll), tostring(args)) end)
    env.invoking = nil
    check(env.live() == 0, 'menu: registering starts no thread')
    check(env.X.ShowMenu('list') == true and env.X.GetOpenMenu() == 'list', 'menu: shows')
    check(env.live() == 1, 'menu: one input thread while open')
    check(#env.focusCalls == 0, 'menu: no NUI focus (keyboard is read by the game)')
    env.step()
    check((env.disabled[172] or 0) >= 1 and (env.disabled[200] or 0) >= 1, 'menu: navigation and pause are disabled while open')
    check(env.disabled[30] == nil, 'menu: movement is left alone without disableInput')

    env.pressed[173] = true -- down
    env.step()
    check(log[1] == 'sel2' and env.last('menu:state').selected == 2, 'menu: down selects the next option and calls onSelected')
    env.pressed[175] = true -- right
    env.step()
    check(log[2] == 'side2:2' and env.last('menu:state').scrollIndex == 2, 'menu: right scrolls the values and calls onSideScroll')
    env.pressed[175] = true
    env.step()
    check(log[3] == 'side2:1', 'menu: scrolling wraps')
    env.pressed[173] = true
    env.step()
    env.pressed[191] = true -- enter on the checkbox
    env.step()
    check(log[5] == 'check3:true' and env.X.GetOpenMenu() == 'list', 'menu: Enter on a checkbox toggles it, calls onCheck, stays open')
    env.pressed[173] = true
    env.step()
    env.pressed[191] = true
    env.step()
    check(log[7] == 'cb4:nil:a4' and env.X.GetOpenMenu() == 'list', 'menu: close = false confirms without closing')
    env.pressed[172] = true -- up, wraps from 4 to 3
    env.step()
    check(env.last('menu:state').selected == 3, 'menu: up moves back')

    -- held key repeat
    env.pressed[172] = true
    env.held[172] = true
    env.step()
    local sel = env.last('menu:state').selected
    env.clock = env.clock + 400
    env.step()
    check(env.last('menu:state').selected == sel - 1, 'menu: a held key repeats after the delay')
    env.held[172] = nil

    env.pressed[200] = true -- escape
    env.step(2)
    check(env.X.GetOpenMenu() == nil and log[#log] == 'close:Escape', 'menu: Escape closes it and calls onClose with the key')
    check(env.live() == 0, 'menu: and its thread ends')

    env.X.ShowMenu('list', 1)
    env.pressed[191] = true
    env.step(2)
    check(log[#log] == 'cb1:nil:a1' and env.X.GetOpenMenu() == nil, 'menu: Enter confirms, closes, and calls the callback')
    check(env.live() == 0, 'menu: no thread after it closed on confirm')

    env.X.ShowMenu('list')
    check(env.X.SetMenuOptions('list', { label = 'Replaced' }, 1) == true, 'menu: SetMenuOptions replaces one option')
    check(env.last('menu:state').options[1].label == 'Replaced', 'menu: and the open menu is redrawn')
    check(env.X.SetMenuOptions('list', { { label = 'Only' } }) == true and #env.last('menu:state').options == 1,
        'menu: SetMenuOptions replaces the whole list')
    env.fire('onResourceStop', 'res_m')
    env.step()
    check(env.X.GetOpenMenu() == nil and env.live() == 0, 'menu: the owner stopping closes it and ends the thread')
    check(env.X.ShowMenu('list') == false, 'menu: and unregisters it')

    env.X.RegisterMenu({ id = 'locked', title = 'L', canClose = false, disableInput = true, options = { { label = 'x' } } })
    env.X.ShowMenu('locked')
    env.pressed[200] = true
    env.step()
    check(env.X.GetOpenMenu() == 'locked', 'menu: canClose = false ignores Escape')
    check((env.disabled[30] or 0) >= 1, 'menu: disableInput disables movement')
    check(env.X.HideMenu() == true and env.X.GetOpenMenu() == nil, 'menu: HideMenu closes it')
    env.step()
    check(env.live() == 0, 'menu: thread ends after HideMenu')
    check(#env.threadErrors == 0, 'menu: no thread raised (' .. tostring(env.threadErrors[1]) .. ')')
    env.reset()
end

-- ===================================================== 10. radial
do
    local env = newEnv()
    env.load()
    check(#env.mappings == 0 and env.commands['+cis_libs_radial'] == nil, 'radial: no keybind until an item exists')
    local picked = {}
    env.invoking = 'res_r'
    check(env.X.AddRadialItem({ id = 'car', label = 'Car', menu = 'carsub' }) == true, 'radial: an item is added')
    env.invoking = nil
    check(#env.mappings == 1 and env.mappings[1].command == '+cis_libs_radial', 'radial: the keybind is registered with the first item')
    env.X.AddRadialItem({ { id = 'wave', label = 'Wave', onSelect = function(menu, i) picked[#picked + 1] = { menu, i } end } })
    check(#env.mappings == 1, 'radial: and only once')
    env.X.RegisterRadial({ id = 'carsub', items = { { label = 'Lock', onSelect = function(menu, i) picked[#picked + 1] = { menu, i } end } } })

    env.commands['+cis_libs_radial']()
    local open = env.last('radial:open')
    check(open and #open.items == 2 and open.items[1].hasMenu == true, 'radial: the key opens it with the items')
    check(lastFocus(env).focus == true and env.keep == true, 'radial: with focus and keepInput (the player can walk)')
    check(env.live() == 1, 'radial: one control thread while open')
    env.step()
    check((env.disabled[1] or 0) >= 1 and (env.disabled[200] or 0) >= 1, 'radial: looking and pause are disabled while open')

    env.post('radial', { token = open.token, action = 'select', index = 1 })
    local sub = env.last('radial:open')
    check(sub.token ~= open.token and sub.hasBack == true and sub.items[1].label == 'Lock', 'radial: an item with a menu opens the submenu')
    env.post('radial', { token = open.token, action = 'select', index = 2 })
    check(#picked == 0, 'radial: the old token is stale once the submenu is drawn')
    env.post('radial', { token = sub.token, action = 'select', index = 1 })
    check(picked[1] and picked[1][1] == 'carsub' and picked[1][2] == 1, 'radial: a submenu item runs onSelect(menuId, index)')
    check(lastFocus(env).focus == false and env.keep == false, 'radial: selecting closes it and restores focus and keepInput')
    env.step()
    check(env.live() == 0, 'radial: the control thread ends with it')

    env.X.DisableRadial(true)
    env.commands['+cis_libs_radial']()
    check(env.last('radial:open').token == sub.token, 'radial: disabled, the key does not open it')
    env.X.DisableRadial(false)
    env.commands['+cis_libs_radial']()
    env.post('escape', {})
    check(lastFocus(env).focus == false, 'radial: Escape closes it')

    env.commands['+cis_libs_radial']()
    env.fire('onResourceStop', 'res_r')
    local redraw = env.last('radial:open')
    check(#redraw.items == 1 and redraw.items[1].label == 'Wave', 'radial: the owner stopping removes its items and redraws')
    check(env.X.RemoveRadialItem('wave') == true, 'radial: RemoveRadialItem removes')
    check(lastFocus(env).focus == false, 'radial: removing the last item closes it')
    env.step()
    check(env.live() == 0, 'radial: no thread left behind')
    env.reset()
end

-- ===================================================== 11. theme and locale
do
    local env = newEnv()
    env.load()
    check(env.X.SetUiTheme({ accent = 'url(https://evil/x.png)' }) == false, 'theme: a url() accent is refused')
    check(env.X.SetUiTheme({ colors = { bg = 'red;background:url(x)' } }) == false, 'theme: an injected colour token is refused')
    check(env.X.SetUiTheme({ radius = 'big' }) == false, 'theme: a non-number radius is refused')
    check(env.X.SetUiTheme({ notifyPosition = 'moon' }) == false, 'theme: an unknown position is refused')
    check(env.last('theme') == nil, 'theme: nothing is sent for a refused theme')
    check(env.X.SetUiTheme({ accent = '#4c8dff', radius = 99, fontScale = 1.2, mode = 'light', textUIPosition = 'top-center' }) == true, 'theme: a valid theme applies')
    local th = env.last('theme')
    check(th.radius == 32 and th.mode == 'light', 'theme: numbers are clamped and sent')
    check(env.X.SetUiTheme({ fontScale = 1.0 }) == true and env.last('theme').accent == '#4c8dff', 'theme: later calls merge')
    env.X.ShowTextUI('x')
    check(env.last('textui:show').position == 'top-center', 'theme: the default position is used by components')
    check(env.X.SetUiLocale({ confirm = 'Bestätigen', bogus = 'x', cancel = 5 }) == true, 'locale: accepted')
    local loc = env.last('locale')
    check(loc.confirm == 'Bestätigen' and loc.bogus == nil and loc.cancel == '5', 'locale: known keys only, coerced to strings')
    env.reset()
end

-- ===================================================== 12. server NotifyPlayer
do
    local env = newEnv()
    loadModule('server/interface.lua')
    check(env.X.NotifyPlayer(7, { title = 'Hi', description = string.rep('d', 3000), sound = { name = 'x' }, junk = function() end }) == true,
        'server: NotifyPlayer to a connected player')
    local e = env.events[1]
    check(e and e.kind == 'client' and e.name == 'cis_libs:client:uiNotify' and e.target == 7, 'server: sent on the namespaced event to that player')
    local p = e.args[1]
    check(#p.description == 2048 and p.sound == nil and p.junk == nil, 'server: the payload is rebuilt, bounded, known fields only')
    check(env.X.NotifyPlayer(-1, 'everyone') == true and env.events[2].target == -1, 'server: -1 broadcasts')
    check(env.X.NotifyPlayer(8, 'x') == false, 'server: an unknown player is refused')
    check(env.X.NotifyPlayer(0, 'x') == false and env.X.NotifyPlayer('abc', 'x') == false, 'server: a bad id is refused')
    check(env.X.NotifyPlayer(7, {}) == false, 'server: an empty notification is refused')
    env.reset()
end

-- ===================================================== 13. an error while opening never strands focus
do
    local env = newEnv()
    env.load()
    env.X.RegisterContext({ id = 'c', options = { { title = 'x' } } })
    env.failSend = 'context:open'
    local ok = env.X.ShowContext('c')
    check(ok == false and env.X.GetOpenContextMenu() == nil, 'errors: a context menu that fails to draw reports false and is not open')
    check(lastFocus(env).focus == false and #CisInterface.focus.stack() == 0, 'errors: and its focus is released')

    env.failSend = 'alert:open'
    local got
    env.spawn(function() got = { env.X.AlertDialog({ header = 'x' }) } end)
    check(got and got[1] == nil and type(got[2]) == 'string', 'errors: an alert that fails to open returns nil and a reason')
    check(lastFocus(env).focus == false, 'errors: and does not keep focus')

    env.failSend = 'input:open'
    env.spawn(function() got = { env.X.InputDialog('x', { 'a' }) } end)
    check(got[1] == nil and lastFocus(env).focus == false, 'errors: an input dialog that fails to open releases focus')

    env.failSend = 'radial:open'
    env.X.AddRadialItem({ id = 'r', label = 'r' })
    env.commands['+cis_libs_radial']()
    check(lastFocus(env).focus == false and env.keep == false, 'errors: a radial that fails to draw releases focus and keepInput')
    check(env.live() == 0, 'errors: and starts no thread')
    env.failSend = nil
    check(#env.logged > 0, 'errors: each failure is logged')
    env.reset()
end

-- ===================================================== 14. not ready: blocking components do not hang
do
    local env = newEnv()
    env.load(false)
    local got
    env.spawn(function() got = { env.X.AlertDialog({ header = 'early' }) } end)
    for _ = 1, 80 do
        env.step()
    end
    check(got and got[1] == nil and got[2] == 'ui not ready', 'not ready: an alert gives up after the wait instead of holding focus forever')
    check(#env.focusCalls == 0, 'not ready: and never took focus')
    check(env.X.ShowContext('missing') == false, 'not ready: an unknown context is still refused')
    env.reset()
end

-- ===================================================== 15. cis_libs stopping releases everything
do
    local env = newEnv()
    env.load()
    env.X.RegisterContext({ id = 'c', options = { { title = 'x' } } })
    env.X.ShowContext('c')
    local got
    env.spawn(function() got = { env.X.InputDialog('x', { 'a' }) } end)
    env.X.AddRadialItem({ id = 'r', label = 'r' })
    env.X.ShowTextUI('t')
    env.fire('onResourceStop', 'cis_libs')
    env.step(2)
    check(got and got[1] == nil, 'stop: an open input dialog resolves nil')
    check(lastFocus(env).focus == false and lastFocus(env).cursor == false, 'stop: focus and cursor released')
    check(env.X.GetOpenContextMenu() == nil and env.X.IsTextUIOpen() == false, 'stop: menus and text UI closed')
    check(env.live() == 0, 'stop: no thread survives')
    env.reset()
end

-- ==================================================================== report
for i = 1, #failures do
    io.stderr:write('FAIL(interface): ' .. failures[i] .. '\n')
end
io.write(('interface passed=%d failed=%d\n'):format(passed, failed))
if failed > 0 then
    os.exit(1)
end
