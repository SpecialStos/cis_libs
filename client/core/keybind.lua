-- The key binding ENGINE, on RegisterKeyMapping and the +name / -name pair.
--
-- ONE SOURCE, TWO VMS. No state at file scope: a binding set is an instance from
-- `M.new(cfg)`. client/keybind.lua wraps cis_libs' instance behind the KeybindAdd
-- export; a consumer's `Cis.keybind.add` gets its own instance, loaded from this
-- text by init.lua, so its handlers are plain local functions and its commands
-- and mapping belong to the consumer resource.
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
--
-- cfg: callable(v), log(level, message), onRegister(handle), onRetire(handle)

local M = {}

local Keybinds = {}
Keybinds.__index = Keybinds

local function defaultCallable(v)
    if type(v) == 'function' then
        return true
    end
    return type(v) == 'table' and rawget(v, '__cfx_functionReference') ~= nil
end

local function noop() end

local function validName(name)
    -- RegisterKeyMapping writes the name into the player's settings and builds
    -- a command from it. A space or a colon makes either of those malformed in a
    -- way the platform answers by doing nothing.
    return type(name) == 'string'
        and name ~= ''
        and name:match('^[%w_%-]+$') ~= nil
end

function M.new(cfg)
    cfg = cfg or {}
    local instance = setmetatable({
        callable = cfg.callable or defaultCallable,
        log = cfg.log or noop,
        onRegister = cfg.onRegister or noop,
        onRetire = cfg.onRetire or noop,
        binds = {},
        -- name -> id of the LIVE binding holding it. A name is one RegisterCommand pair
        -- and one mapping, so two resources cannot both own it.
        byName = {},
        -- id -> { onPress, onRelease }. Kept OFF the handle on purpose: the handle is
        -- what `KeybindAdd` and `Keybinds` hand across the exports boundary, and a
        -- handle carrying the callbacks handed one resource's functions to every other
        -- resource that asked for the list.
        callbacks = {},
        -- Monotonic, never reused. `#binds + 1` after a destroy leaves a hole, and the
        -- next add would reuse an id a caller still holds.
        nextId = 0,
    }, Keybinds)

    -- The handle's methods. Per instance, because the handle must not carry a
    -- reference to the instance: it crosses the exports boundary as data, and
    -- a field pointing here would serialise every binding's callbacks with it.
    local Bind = {}
    Bind.__index = Bind
    instance.Bind = Bind

    function Bind:disable(state)
        if state == nil then state = true end
        if instance.binds[self.id] ~= self then
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
        if instance.binds[self.id] ~= self then
            return false
        end
        instance:retire(self)
        return true
    end

    return instance
end

-- THE COMMANDS OUTLIVE THE BINDING. FiveM has no UnregisterCommand, so a
-- destroyed or released binding is made inert here instead: disabled, its
-- callbacks dropped (a stopped resource's funcrefs are dead and raise when
-- called), and its slots freed. The command closures look the binding up by id
-- and find nothing.
function Keybinds:retire(b)
    b.enabled = false
    b.pressed = false
    self.callbacks[b.id] = nil
    self.binds[b.id] = nil
    if self.byName[b.name] == b.id then
        self.byName[b.name] = nil
    end
    self.onRetire(b)
end

function Keybinds:fire(id, which)
    local b = self.binds[id]
    if not b or not b.enabled then return end
    b.pressed = which == 'onPress'
    local cbs = self.callbacks[id]
    local fn = cbs and cbs[which]
    if self.callable(fn) then
        local ok, err = pcall(fn)
        if not ok then
            self.log('error', ('cis_libs: keybind %q %s raised: %s'):format(b.name, which, tostring(err)))
        end
    end
end

function Keybinds:get(id)
    return type(id) == 'number' and self.binds[id] or nil
end

function Keybinds:add(options, owner)
    if type(options) ~= 'table' then
        return false, ('options arrived as %s, not a table'):format(type(options))
    end
    local name = options.name
    if not validName(name) then
        return false, ("name must be a non-empty string of letters, digits, underscore or hyphen; got %s")
            :format(tostring(name))
    end
    -- callable, not `type == 'function'`: a consumer's handler crosses the
    -- exports boundary as a funcref table, and the type check refused every one.
    -- `onPressed` / `onReleased` are ox_lib's spellings, accepted as aliases.
    local pressFn = options.onPress
    if pressFn == nil then pressFn = options.onPressed end
    local releaseFn = options.onRelease
    if releaseFn == nil then releaseFn = options.onReleased end
    local onPress = self.callable(pressFn) and pressFn or nil
    local onRelease = self.callable(releaseFn) and releaseFn or nil
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

    -- A NAME HELD BY ANOTHER RESOURCE IS REFUSED, NOT TAKEN. Re-registering the
    -- command would silently route the other resource's key to this one.
    local heldId = self.byName[name]
    local held = heldId and self.binds[heldId]
    if held then
        if held.owner ~= owner then
            return false, ('keybind %q is already registered by %s; pick a different name')
                :format(name, tostring(held.owner))
        end
        -- The same owner adding the same name again replaces its own binding.
        self:retire(held)
    end

    self.nextId = self.nextId + 1
    local id = self.nextId
    local handle = setmetatable({
        id = id,
        name = name,
        owner = owner,
        command = ('+%s'):format(name),
        releaseCommand = ('-%s'):format(name),
        enabled = true,
        pressed = false,
    }, self.Bind)

    self.binds[id] = handle
    self.byName[name] = id
    self.callbacks[id] = { onPress = onPress, onRelease = onRelease }
    self.onRegister(handle)

    -- THE COMMANDS, BEFORE THE MAPPING. The reverse order leaves a window in
    -- which a player can press the key and get nothing, and the symptom -- a
    -- key that is in the settings menu and does not work -- looks like a
    -- platform bug rather than a registration race.
    RegisterCommand(handle.command, function()
        self:fire(id, 'onPress')
    end, false)

    RegisterCommand(handle.releaseCommand, function()
        self:fire(id, 'onRelease')
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
    -- exports boundary loses its metatable. A consumer of the export keeps
    -- `handle.id` and uses KeybindDisable / KeybindEnable / KeybindIsPressed /
    -- KeybindRemove; a consumer of `Cis.keybind.add` holds the real handle.
    return handle
end

-- A MODULE. Published under CisCore when cis_libs runs it as a client_script.
if ... ~= 'cis_require' then
    CisCore = CisCore or {}
    CisCore.keybind = M
end

return M
