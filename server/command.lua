-- Server commands with argument validation, source injection and a usage line.
--
-- RESTRICTED COMMANDS AND THE ACE. A command's `restricted` flag is enforced
-- twice: RegisterCommand is told, and the handler checks
-- IsPrincipalAceAllowed itself. Granting the ACE is the operator's job, with
-- one exception that mirrors ox_lib: when `restricted` names a GROUP and the
-- operator has given cis_libs the right to run `add_ace`
-- (`add_ace resource.cis_libs command.add_ace allow`), cis_libs provisions
-- `add_ace <group> command.<name> allow` itself, and takes it back with
-- `remove_ace` when the command goes. Without that grant nothing is executed:
-- the exact `add_ace` line is printed once at registration and again on every
-- refusal, because a command that silently never runs is the worst outcome
-- available and an operator has no way to guess why.
--
-- THE INJECTED SOURCE IS NOT OPTIONAL and not a parameter. `source` inside a
-- command handler is the platform's, and a command that exposes it as an
-- argument lets a caller name anyone. The handler signature is
-- `(source, args, raw)`, which is the order RegisterCommand already uses, so
-- nothing about the platform is hidden.

local commands = {}
local usageWarned = {}
-- Names RegisterCommand has been called for. The platform cannot unregister a
-- command, so each name is registered ONCE and its closure dispatches to the
-- LIVE entry: a removed command finds no entry and does nothing, and a re-added
-- one is reached through the same closure rather than a second one beside it.
local registered = {}
-- The `restricted` flag each name was registered with. RegisterCommand takes it
-- once and cannot change it, so a re-add that asks for the other one is refused.
local registeredRestricted = {}

local PARAM_TYPES = { string = true, number = true, playerId = true, longString = true }

-- Split a command line the way a shell does not, and the way a player expects:
-- double quotes group, single quotes do not expand anything, and there is no
-- backslash escape because the platform has none and inventing one would make
-- a path with a backslash in it depend on this parser rather than on the OS.
--
-- Characters go into a BUFFER and are joined once per argument: appending to a
-- string copied the whole argument per character, quadratic in its length.
--
-- A SINGLE QUOTE GROUPS ONLY AT THE START OF A WORD. Inside one it is an
-- apostrophe: `me I'm sure it's fine` used to come out as `Im sure its|fine`.
-- One left open to the end of the line is read as a plain character too.
local function parseLine(raw, singleQuotes)
    local args = {}
    local buf, n = {}, 0
    local open = false
    local quote = nil
    local byte = string.byte
    for i = 1, #raw do
        local c = byte(raw, i)
        if quote then
            if c == quote then
                quote = nil
            else
                n = n + 1
                buf[n] = raw:sub(i, i)
            end
        elseif c == 34 or (c == 39 and singleQuotes and not open) then -- " or a leading '
            quote = c
            open = true
        elseif c == 32 or (c >= 9 and c <= 13) then
            if open then
                args[#args + 1] = table.concat(buf, '', 1, n)
                n = 0
                open = false
            end
        else
            n = n + 1
            buf[n] = raw:sub(i, i)
            open = true
        end
    end
    if open then
        args[#args + 1] = table.concat(buf, '', 1, n)
    end
    return args, quote
end

function CisCommandParse(raw)
    if type(raw) ~= 'string' then
        return {}
    end
    local args, unclosed = parseLine(raw, true)
    if unclosed == 39 then
        args = parseLine(raw, false)
    end
    return args
end

local function paramName(p)
    if type(p) == 'table' then
        return p.name or p.help or '?'
    end
    return tostring(p)
end

local function isOptional(p)
    return type(p) == 'table' and p.optional == true
end

function CisCommandNames()
    local out = {}
    for name in pairs(commands) do out[#out + 1] = name end
    table.sort(out)
    return out
end

local function aceGroup(entry)
    return type(entry.restricted) == 'string' and entry.restricted or 'group.admin'
end

local function buildUsage(entry)
    local parts = { entry.name }
    for _, p in ipairs(entry.params) do
        local label = paramName(p)
        if type(p) == 'table' and p.type and p.type ~= 'string' then
            label = label .. ':' .. p.type
        end
        parts[#parts + 1] = (isOptional(p) and '[%s]' or '<%s>'):format(label)
    end
    local line = table.concat(parts, ' ')
    if entry.restricted then
        line = line .. ('   [restricted -- add_ace %s command.%s allow]'):format(aceGroup(entry), entry.name)
    end
    return line
end

local function suggestionParams(params)
    local out = {}
    for _, p in ipairs(params) do
        if type(p) == 'table' then
            local help = tostring(p.help or p.name or '')
            if p.type and p.type ~= 'string' then
                help = ('%s (%s)'):format(help, p.type)
            end
            if p.optional then
                help = help .. ' (optional)'
            end
            out[#out + 1] = { name = tostring(p.name or p.help or 'arg'), help = help }
        else
            out[#out + 1] = { name = tostring(p), help = '' }
        end
    end
    return out
end

local function chatStarted()
    return GetResourceState and GetResourceState('chat') == 'started'
end

-- chat suggestions while `chat` is started. The seam is
-- TriggerClientEvent('chat:addSuggestion', ...), allow-listed in the contract
-- test. cis_libs does not ship chat.
local function suggest(target, entry)
    TriggerClientEvent('chat:addSuggestion', target, '/' .. entry.name, entry.help or '',
        suggestionParams(entry.params))
end

local function warnUsage(entry, why)
    local key = entry.name .. ':' .. (why or 'usage')
    if usageWarned[key] then
        return
    end
    usageWarned[key] = true
    if CisLog then
        CisLog('info', ('cis_libs: usage: %s%s'):format(buildUsage(entry),
            why and ('  (' .. why .. ')') or ''))
    end
end

-- Convert the parsed words to what each declared param says it is. Returns the
-- args, or nil plus the reason the line was refused.
local function typedArgs(entry, src, parsed)
    local params = entry.params
    for i, p in ipairs(params) do
        local kind = type(p) == 'table' and p.type or 'string'
        local word = parsed[i]
        if word == nil then
            if not isOptional(p) then
                return nil, nil
            end
        elseif kind == 'number' then
            local v = tonumber(word)
            if not v or v ~= v or v == math.huge or v == -math.huge then
                return nil, ('%s must be a number'):format(paramName(p))
            end
            parsed[i] = v
        elseif kind == 'playerId' then
            local v = (word == 'me' and src ~= 0) and src or tonumber(word)
            if not v or v <= 0 or v % 1 ~= 0 or not GetPlayerName(v) then
                return nil, ('%s must be the id of a connected player'):format(paramName(p))
            end
            parsed[i] = v
        elseif kind == 'longString' then
            -- Everything from here to the end, as one argument.
            local rest = table.concat(parsed, ' ', i)
            for j = #parsed, i + 1, -1 do
                parsed[j] = nil
            end
            parsed[i] = rest
        end
        if type(p) == 'table' and type(p.name) == 'string' then
            parsed[p.name] = parsed[i]
        end
    end
    return parsed
end

-- ONLY A GROUP. cis_libs' own `add_ace` right is lent to whichever resource
-- calls CommandAdd, so the principal it writes is held to `group.<name>`:
-- `builtin.everyone` or a `player.` / `identifier.` principal would open the
-- command to everyone or hand one player a right the operator never gave.
local function provisionableGroup(restricted)
    return type(restricted) == 'string' and restricted:match('^group%.[%w_%-]+$') ~= nil
end

local function provisionAce(entry)
    if not provisionableGroup(entry.restricted) or type(ExecuteCommand) ~= 'function' then
        return false
    end
    local self = 'resource.' .. GetCurrentResourceName()
    if not IsPrincipalAceAllowed(self, 'command.add_ace') then
        return false
    end
    ExecuteCommand(('add_ace %s command.%s allow'):format(entry.restricted, entry.name))
    return true
end

local function release(entry)
    if commands[entry.name] ~= entry then
        return
    end
    commands[entry.name] = nil
    if entry.provisioned and type(ExecuteCommand) == 'function' then
        ExecuteCommand(('remove_ace %s command.%s allow'):format(entry.restricted, entry.name))
    end
    if chatStarted() then
        TriggerClientEvent('chat:removeSuggestion', -1, '/' .. entry.name)
    end
end

local function dispatch(name, src, args, rawCommand)
    -- The LIVE entry. A removed command has none, and a stale closure must not
    -- run a handler that belongs to a resource that has since stopped.
    local entry = commands[name]
    if not entry then
        return
    end
    if entry.restricted and src ~= 0 then
        -- IS_PRINCIPAL_ACE_ALLOWED (CFX, shared): (principal: char*, object: char*).
        -- BOTH are strings. Passing the numeric source is a type error the
        -- native answers by refusing, which looks like "the ACE is missing"
        -- and prints the add_ace line forever.
        local principal = ('player.%s'):format(src)
        local object = ('command.%s'):format(name)
        if not IsPrincipalAceAllowed(principal, object) then
            if CisLog then
                CisLog('warn', ('cis_libs: %q was refused for src %s. Grant it with: add_ace %s command.%s allow')
                    :format(name, tostring(src), aceGroup(entry), name))
            end
            return
        end
    end

    local parsed
    if type(rawCommand) == 'string' and rawCommand ~= '' then
        parsed = CisCommandParse(rawCommand)
        -- Without regard to case, as the platform matched it: `/GIVE 5 bread`
        -- passed GIVE as the first argument.
        if type(parsed[1]) == 'string' and parsed[1]:lower() == name:lower() then
            table.remove(parsed, 1)
        end
    else
        parsed = type(args) == 'table' and args or {}
    end

    if #parsed < entry.required then
        warnUsage(entry)
        return
    end
    local typed, why = typedArgs(entry, src, parsed)
    if not typed then
        warnUsage(entry, why)
        return
    end

    local ok, err = xpcall(entry.handler, Logging and Logging.Trap or debug.traceback, src, typed, rawCommand)
    if not ok then
        if Logging and Logging.AutoLogError then
            Logging.AutoLogError(err, 'command ' .. name)
        elseif CisLog then
            CisLog('error', ('cis_libs: command %q raised: %s'):format(name, tostring(err)))
        end
    end
end

-- Checked before anything is stored or registered: a param list is a contract
-- with every player who types the command, so a malformed one is refused rather
-- than half-honoured.
local function readParams(params)
    if params == nil then
        return {}, 0
    end
    if type(params) ~= 'table' then
        return nil, 'params must be an array of names or { name, help, type, optional } tables'
    end
    local required, sawOptional = 0, false
    for i, p in ipairs(params) do
        if type(p) == 'table' then
            if p.type ~= nil and not PARAM_TYPES[p.type] then
                return nil, ("params[%d].type must be 'string', 'number', 'playerId' or 'longString'; got %s")
                    :format(i, tostring(p.type))
            end
            if p.type == 'longString' and i ~= #params then
                return nil, ('params[%d] is a longString, which takes the rest of the line, so it must be last'):format(i)
            end
        elseif type(p) ~= 'string' then
            return nil, ('params[%d] must be a name or a table; got %s'):format(i, type(p))
        end
        if isOptional(p) then
            sawOptional = true
        elseif sawOptional then
            return nil, ('params[%d] is required but follows an optional one; optional params must come last'):format(i)
        else
            required = required + 1
        end
    end
    return params, required
end

-- Who already holds a command of this name, or nil. GET_REGISTERED_COMMANDS
-- (CFX, shared) lists { name, resource, arity }; a builtin has no resource.
local function existingHolder(name)
    local list = GetRegisteredCommands()
    if type(list) ~= 'table' then
        return nil
    end
    local want = name:lower()
    for _, c in ipairs(list) do
        if type(c) == 'table' and type(c.name) == 'string' and c.name:lower() == want then
            local res = c.resource
            if type(res) ~= 'string' or res == '' then
                return 'a server builtin'
            end
            return ('registered by %s'):format(res)
        end
    end
    return nil
end

function CisCommandAdd(name, options, handler)
    if type(name) ~= 'string' or not name:match('^[%w_%-]+$') then
        return false, ('command name must be letters, digits, underscore or hyphen; got %s'):format(tostring(name))
    end
    if type(options) ~= 'table' then
        return false, ('options must be a table; got %s'):format(type(options))
    end
    -- CisCallable: a function from ANOTHER resource arrives as a callable
    -- reference table. It is owned by that resource and released when it stops.
    if not CisCallable(handler) then
        return false, ('the handler must be a function (a function passed from another resource is fine); got %s')
            :format(type(handler))
    end
    if commands[name] then
        return false, ('a command named %q is already registered; remove it first'):format(name)
    end

    local restricted = options.restricted
    if restricted ~= nil and restricted ~= false and restricted ~= true and type(restricted) ~= 'string' then
        return false, ("restricted must be true, false, or an ACE group string like 'group.admin'; got %s")
            :format(type(restricted))
    end
    -- The group is written into an `add_ace` line, so it is held to the shape of
    -- a principal and nothing else: no space, no `;`, no quote.
    if type(restricted) == 'string' and not restricted:match('^[%w_%-%.:]+$') then
        return false, ("restricted must be an ACE principal like 'group.admin'; got %q"):format(restricted)
    end

    local params, required = readParams(options.params)
    if not params then
        return false, required
    end

    -- A NAME THE SERVER ALREADY KNOWS IS NOT TAKEN. Registering over another
    -- resource's command, or a builtin like `add_principal`, would route it here
    -- and, with a restriction, have cis_libs grant its ACE. Command names match
    -- without regard to case.
    if registered[name] then
        if registeredRestricted[name] ~= (restricted and true or false) then
            return false, ('command %q was first registered %s, and FiveM cannot change that until a restart')
                :format(name, registeredRestricted[name] and 'restricted' or 'unrestricted')
        end
    else
        local holder = existingHolder(name)
        if holder then
            return false, ('a command named %q already exists (%s); pick a different name'):format(name, holder)
        end
    end

    local entry = {
        name = name,
        params = params,
        required = required,
        help = options.help,
        restricted = restricted,
        handler = handler,
        owner = GetInvokingResource() or 'cis_libs',
    }
    commands[name] = entry

    -- RegisterCommand (CFX, shared): (commandName, handler, restricted).
    -- The handler is (source, args, rawCommand). args is already a table of
    -- strings WITHOUT the command name. rawCommand is the full line, including
    -- it. Parsing raw is what makes quoted arguments work; using args as-is
    -- splits on every space and cannot group.
    if not registered[name] then
        registered[name] = true
        registeredRestricted[name] = restricted and true or false
        RegisterCommand(name, function(src, args, rawCommand)
            dispatch(name, src, args, rawCommand)
        end, restricted and true or false)
    end

    if restricted then
        entry.provisioned = provisionAce(entry)
        if not entry.provisioned and CisLog and type(restricted) == 'string' and not provisionableGroup(restricted) then
            CisLog('warn', ('cis_libs: %q names %s, which is not a group; cis_libs grants only group.* principals')
                :format(name, restricted))
        end
        if not entry.provisioned and CisLog then
            CisLog('info', ('cis_libs: %q is restricted. Grant it with: add_ace %s command.%s allow')
                :format(name, aceGroup(entry), name))
        end
    end

    if chatStarted() then
        suggest(-1, entry)
    end

    return true
end

function CisCommandList()
    local out = {}
    for _, name in ipairs(CisCommandNames()) do
        out[#out + 1] = { name = name, usage = buildUsage(commands[name]), help = commands[name].help }
    end
    return out
end

-- A player who joins after a command was added never saw its suggestion, and
-- neither did anyone if chat started after cis_libs. Both are sent here.
AddEventHandler('playerJoining', function()
    local src = source
    if type(src) ~= 'number' or src <= 0 or not chatStarted() then
        return
    end
    for _, entry in pairs(commands) do
        suggest(src, entry)
    end
end)

-- A resource that stops takes its commands with it: the platform keeps the
-- closure, but it finds no entry and runs nothing.
-- Through CisOnResourceStop (shared/owned.lua), so a forged stop is ignored.
CisOnResourceStop(function(resource)
    if resource == GetCurrentResourceName() then
        return
    end
    local doomed = {}
    for _, entry in pairs(commands) do
        if entry.owner == resource then
            doomed[#doomed + 1] = entry
        end
    end
    for i = 1, #doomed do
        release(doomed[i])
    end
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= 'chat' then
        return
    end
    for _, entry in pairs(commands) do
        suggest(-1, entry)
    end
end)

exports('CommandAdd', CisCommandAdd)
exports('CommandList', CisCommandList)
exports('CommandRemove', function(name)
    local entry = commands[name]
    if not entry then return false, ('no command named %q'):format(tostring(name)) end
    -- Only the resource that added it, or cis_libs.
    local caller = GetInvokingResource() or 'cis_libs'
    if caller ~= entry.owner and caller ~= GetCurrentResourceName() then
        return false, ('command %q belongs to %s; only it can remove it'):format(name, tostring(entry.owner))
    end
    release(entry)
    return true
end)
exports('CommandParse', CisCommandParse)

CisDiagnostics.Register('server', 'commands', function()
    local byOwner = {}
    local restricted = 0
    local total = 0
    for _, c in pairs(commands) do
        total = total + 1
        if c.restricted then restricted = restricted + 1 end
        byOwner[c.owner] = (byOwner[c.owner] or 0) + 1
    end
    return { total = total, restricted = restricted, byOwner = byOwner }
end)
