-- Key bindings, on RegisterKeyMapping and the +name / -name pair.
--
-- THE MAPPING BELONGS TO THE RESOURCE THAT REGISTERED IT, and that is not a
-- detail this file can fix -- it is a fact the caller has to know. A key
-- mapping is written into the PLAYER's settings, under the name of whichever
-- resource registered it, and it does not go away when that resource stops.
-- Renaming a binding therefore creates a SECOND binding rather than renaming the
-- first, so a player who had the old name bound now has two, and the old one is
-- still there pressing an empty key. That is why `name` is required and
-- validated rather than generated: a generated name changes on every edit.
--
-- WHY THE COMMAND IS REGISTERED EXPLICITLY rather than trusting the `+name`
-- convention to arrive. `RegisterKeyMapping` makes the engine fire
-- `+<commandName>`, and the command has to exist or the binding does nothing at
-- all -- silently, with the key still showing in the settings menu. Registering
-- it here is what makes the binding real, and registering it BEFORE the
-- mapping is what means there is no window where a player can press the key and
-- get nothing.

local binds = {}
-- Monotonic, never reused. `#binds + 1` after a destroy leaves a hole, and the
-- next add would reuse an id a caller still holds.
local nextId = 0

local Bind = {}
Bind.__index = Bind

local function validName(name)
    -- RegisterKeyMapping writes the name into the player's settings and builds
    -- a command from it. A space or a colon makes either of those malformed in a
    -- way the platform answers by doing nothing.
    return type(name) == 'string'
        and name ~= ''
        and name:match('^[%w_%-]+$') ~= nil
end

function CisKeybindAdd(options)
    if type(options) ~= 'table' then
        return false, ('options arrived as %s, not a table'):format(type(options))
    end
    local name = options.name
    if not validName(name) then
        return false, ("name must be a non-empty string of letters, digits, underscore or hyphen; got %s")
            :format(tostring(name))
    end
    if type(options.onPress) ~= 'function' and type(options.onRelease) ~= 'function' then
        return false, 'a binding needs onPress, onRelease, or both'
    end

    local key = options.defaultKey
    if key ~= nil and type(key) ~= 'string' then
        return false, ('defaultKey must be a key name string like "F7" or "X", got %s'):format(type(key))
    end
    local mapper = options.defaultMapper
    if mapper ~= nil and type(mapper) ~= 'string' then
        return false, ('defaultMapper must be a mapper name like "keyboard", got %s'):format(type(mapper))
    end

    local owner = GetInvokingResource() or 'cis_libs'
    nextId = nextId + 1
    local handle = setmetatable({
        id = nextId,
        name = name,
        owner = owner,
        command = ('+%s'):format(name),
        releaseCommand = ('-%s'):format(name),
        enabled = true,
        pressed = false,
        onPress = options.onPress,
        onRelease = options.onRelease,
    }, Bind)

    binds[handle.id] = handle

    -- THE COMMANDS, BEFORE THE MAPPING. The reverse order leaves a window in
    -- which a player can press the key and get nothing, and the symptom -- a
    -- key that is in the settings menu and does not work -- looks like a
    -- platform bug rather than a registration race.
    RegisterCommand(handle.command, function()
        if not handle.enabled then return end
        handle.pressed = true
        if type(handle.onPress) == 'function' then
            local ok, err = pcall(handle.onPress)
            if not ok and CisLog then
                CisLog('error', ('cis_libs: keybind %q onPress raised: %s'):format(name, tostring(err)))
            end
        end
    end, false)

    RegisterCommand(handle.releaseCommand, function()
        if not handle.enabled then return end
        handle.pressed = false
        if type(handle.onRelease) == 'function' then
            local ok, err = pcall(handle.onRelease)
            if not ok and CisLog then
                CisLog('error', ('cis_libs: keybind %q onRelease raised: %s'):format(name, tostring(err)))
            end
        end
    end, false)

    -- REGISTER_KEY_MAPPING (CFX, client): commandString, description,
    -- defaultMapper, defaultParameter. FOUR arguments. A fifth boolean is not
    -- a parameter -- it would be ignored or shift the mapper. commandString is
    -- the +name command, defaultMapper is "keyboard", defaultParameter is the
    -- key name.
    --
    -- Called directly, not through pcall: the natives scanner recognises a
    -- native by a LITERAL call, so wrapping it made it invisible to the realm
    -- check.
    RegisterKeyMapping(handle.command, options.description or name, mapper or 'keyboard', key or '')

    return handle
end

function Bind:disable(state)
    if state == nil then state = true end
    self.enabled = not state
    if not self.enabled then
        self.pressed = false
    end
    return self
end

function Bind:isPressed()
    return self.pressed == true
end

function Bind:reset()
    self.pressed = false
    return self
end

function Bind:destroy()
    binds[self.id] = nil
    return true
end

exports('KeybindAdd', CisKeybindAdd)
exports('Keybinds', function()
    local out = {}
    for _, b in pairs(binds) do
        out[#out + 1] = b
    end
    return out
end)

CisDiagnostics.Register('client', 'keybinds', function()
    local byOwner = {}
    local total = 0
    for _, b in pairs(binds) do
        total = total + 1
        byOwner[b.owner] = (byOwner[b.owner] or 0) + 1
    end
    return { total = total, byOwner = byOwner }
end)

AddEventHandler('onResourceStop', function(resource)
    for id, b in pairs(binds) do
        if b.owner == resource then
            b:reset()
            binds[id] = nil
        end
    end
end)
