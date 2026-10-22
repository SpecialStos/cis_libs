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
-- name -> id of the LIVE binding holding it. A name is one RegisterCommand pair
-- and one mapping, so two resources cannot both own it.
local byName = {}
-- id -> { onPress, onRelease }. Kept OFF the handle on purpose: the handle is
-- what `KeybindAdd` and `Keybinds` hand across the exports boundary, and a
-- handle carrying the callbacks handed one resource's functions to every other
-- resource that asked for the list.
local callbacks = {}
local owned = CisOwned.new()
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

-- THE COMMANDS OUTLIVE THE BINDING. FiveM has no UnregisterCommand, so a
-- destroyed or released binding is made inert here instead: disabled, its
-- callbacks dropped (a stopped resource's funcrefs are dead and raise when
-- called), and its slots freed. The command closures look the binding up by id
-- and find nothing.
local function retire(b)
    b.enabled = false
    b.pressed = false
    callbacks[b.id] = nil
    binds[b.id] = nil
    if byName[b.name] == b.id then
        byName[b.name] = nil
    end
    CisOwned.forget(owned, 'keybind', b.id)
end

local function fire(id, which)
    local b = binds[id]
    if not b or not b.enabled then return end
    b.pressed = which == 'onPress'
    local cbs = callbacks[id]
    local fn = cbs and cbs[which]
    if CisCallable(fn) then
        local ok, err = pcall(fn)
        if not ok and CisLog then
            CisLog('error', ('cis_libs: keybind %q %s raised: %s'):format(b.name, which, tostring(err)))
        end
    end
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
    -- CisCallable, not `type == 'function'`: a consumer's handler crosses the
    -- exports boundary as a funcref table, and the type check refused every one.
    local onPress = CisCallable(options.onPress) and options.onPress or nil
    local onRelease = CisCallable(options.onRelease) and options.onRelease or nil
    if not onPress and not onRelease then
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
    -- A NAME HELD BY ANOTHER RESOURCE IS REFUSED, NOT TAKEN. Re-registering the
    -- command would silently route the other resource's key to this one.
    local heldId = byName[name]
    local held = heldId and binds[heldId]
    if held then
        if held.owner ~= owner then
            return false, ('keybind %q is already registered by %s; pick a different name')
                :format(name, tostring(held.owner))
        end
        -- The same owner adding the same name again replaces its own binding.
        retire(held)
    end

    nextId = nextId + 1
    local id = nextId
    local handle = setmetatable({
        id = id,
        name = name,
        owner = owner,
        command = ('+%s'):format(name),
        releaseCommand = ('-%s'):format(name),
        enabled = true,
        pressed = false,
    }, Bind)

    binds[id] = handle
    byName[name] = id
    callbacks[id] = { onPress = onPress, onRelease = onRelease }
    CisOwned.track(owned, owner, 'keybind', id)

    -- THE COMMANDS, BEFORE THE MAPPING. The reverse order leaves a window in
    -- which a player can press the key and get nothing, and the symptom -- a
    -- key that is in the settings menu and does not work -- looks like a
    -- platform bug rather than a registration race.
    RegisterCommand(handle.command, function()
        fire(id, 'onPress')
    end, false)

    RegisterCommand(handle.releaseCommand, function()
        fire(id, 'onRelease')
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

    -- The handle's METHODS work in this realm only: a table returned across the
    -- exports boundary loses its metatable. A consumer keeps `handle.id` and uses
    -- KeybindDisable / KeybindEnable / KeybindIsPressed / KeybindRemove.
    return handle
end

function Bind:disable(state)
    if state == nil then state = true end
    if binds[self.id] ~= self then
        -- A retired binding stays retired; re-enabling it would revive nothing.
        return self
    end
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
    if binds[self.id] ~= self then
        return false
    end
    retire(self)
    return true
end

-- The id-based surface, for a consumer whose handle arrived without methods.
-- Changing a binding is the owner's (or cis_libs's) business; asking whether
-- it is pressed is anyone's.
local function controlled(id)
    local b = type(id) == 'number' and binds[id] or nil
    if not b then
        return nil, ('no keybind with id %s'):format(tostring(id))
    end
    local caller = GetInvokingResource() or 'cis_libs'
    if caller ~= 'cis_libs' and caller ~= b.owner then
        return nil, ('keybind %s belongs to %s, not %s'):format(tostring(id), tostring(b.owner), caller)
    end
    return b
end

function CisKeybindDisable(id, state)
    local b, why = controlled(id)
    if not b then return false, why end
    b:disable(state)
    return true
end

function CisKeybindEnable(id)
    return CisKeybindDisable(id, false)
end

function CisKeybindRemove(id)
    local b, why = controlled(id)
    if not b then return false, why end
    return b:destroy()
end

function CisKeybindIsPressed(id)
    local b = type(id) == 'number' and binds[id] or nil
    return b ~= nil and b.pressed == true
end

exports('KeybindAdd', CisKeybindAdd)
exports('KeybindDisable', CisKeybindDisable)
exports('KeybindEnable', CisKeybindEnable)
exports('KeybindRemove', CisKeybindRemove)
exports('KeybindIsPressed', CisKeybindIsPressed)
-- SNAPSHOTS, never the live records and never the callbacks.
exports('Keybinds', function()
    local out = {}
    for _, b in pairs(binds) do
        out[#out + 1] = {
            id = b.id,
            name = b.name,
            owner = b.owner,
            command = b.command,
            enabled = b.enabled,
            pressed = b.pressed,
        }
    end
    table.sort(out, function(x, y) return x.id < y.id end)
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

-- A stopped resource's bindings go inert: its funcrefs are dead, and a command
-- still holding one raised on every key press for the rest of the session.
AddEventHandler('onResourceStop', function(resource)
    local freed = CisOwned.release(owned, resource)
    for i = 1, #freed do
        local b = freed[i].kind == 'keybind' and binds[freed[i].id] or nil
        if b then
            retire(b)
        else
            CisOwned.forget(owned, freed[i].kind, freed[i].id)
        end
    end
end)
