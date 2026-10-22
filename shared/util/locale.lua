-- Per-resource translations from JSON files, client and server alike.
--
--   -- locales/en.json in YOUR resource:
--   --   { "shop": { "welcome": "Welcome, ${name}!", "price": "That costs $%s" } }
--   local locale = Cis.require('locale')
--   locale.t('shop.welcome', { name = 'Ana' })   -- 'Welcome, Ana!'
--   locale.t('shop.price', 250)                    -- 'That costs $250'
--
-- WHOSE FILES. The CALLING resource's: `locales/<lang>.json` is read with
-- LoadResourceFile(GetCurrentResourceName(), ...). Cis.require loads a module
-- into the resource that asked for it, so each resource has its own phrases
-- and its own language. List the files in your fxmanifest `files {}` so the
-- client can read them too.
--
-- WHICH LANGUAGE. `locale.load(lang)`, else the convar `cis:locale`, else 'en'.
-- Set the convar with `setr` so clients see it. English is the fallback twice
-- over: when locales/<lang>.json is missing the English file is used instead,
-- and a key missing from <lang> falls back to its English phrase.
--
-- KEYS. Nested JSON objects flatten to dotted keys: { "a": { "b": "x" } } is
-- 'a.b'. A key with no phrase answers the key itself -- visible in the UI,
-- never a crash -- and warns once per key.
--
-- ARGUMENTS. A TABLE first argument fills `${name}` placeholders by name; any
-- further arguments (or all of them, when the first is not a table) fill `%s`
-- positions through string.format. A phrase whose format does not fit its
-- arguments is returned unformatted and warns once.
--
-- The first call to t() loads the configured language if load() was never
-- called, so `locale.t` works without any setup.

local M = {}

local FALLBACK = 'en'

local state = {
    lang = nil,
    phrases = {},
    loaded = false,
    warned = {},
}

local function warnOnce(key, message)
    if state.warned[key] then
        return
    end
    state.warned[key] = true
    print(('^3[WARN] cis_libs locale: %s^7'):format(message))
end

local function configuredLanguage()
    if type(GetConvar) == 'function' then
        local ok, v = pcall(GetConvar, 'cis:locale', '')
        if ok and type(v) == 'string' and v ~= '' then
            return v
        end
    end
    return FALLBACK
end

local function flatten(src, prefix, out)
    for k, v in pairs(src) do
        local key = prefix and (prefix .. '.' .. tostring(k)) or tostring(k)
        local tv = type(v)
        if tv == 'table' then
            flatten(v, key, out)
        elseif tv == 'string' or tv == 'number' or tv == 'boolean' then
            out[key] = tostring(v)
        end
    end
    return out
end

local function readLocale(resource, lang)
    local path = ('locales/%s.json'):format(lang)
    local ok, text = pcall(LoadResourceFile, resource, path)
    if not ok or type(text) ~= 'string' then
        return nil, ('%s was not found in resource %s (is it in fxmanifest files {}?)'):format(path, tostring(resource))
    end
    local codec = json
    if type(codec) ~= 'table' or type(codec.decode) ~= 'function' then
        return nil, 'the FiveM json global is not available to decode ' .. path
    end
    local decoded, data = pcall(codec.decode, text)
    if not decoded or type(data) ~= 'table' then
        return nil, ('%s is not a JSON object (%s)'):format(path, decoded and type(data) or tostring(data))
    end
    return data
end

--- Load a language from the calling resource's locales folder.
---@param lang? string  default the convar cis:locale, else 'en'. Letters, digits, '-' and '_' only
---@return string|nil  the language actually in use (en when the requested file is missing)
---@return string|nil  why, when neither the language nor en could be read
function M.load(lang)
    if lang == nil then
        lang = configuredLanguage()
    end
    if type(lang) ~= 'string' or not lang:match('^[%w_%-]+$') then
        return nil, ('language must be a name like "en" or "pt-BR", got %s'):format(tostring(lang))
    end
    local resource = GetCurrentResourceName()
    state.loaded = true
    state.warned = {}
    local data, why = readLocale(resource, lang)
    local base
    if lang ~= FALLBACK then
        base = readLocale(resource, FALLBACK)
    end
    if data == nil and base == nil then
        state.lang, state.phrases = nil, {}
        if lang ~= FALLBACK then
            why = why .. ', and there is no locales/en.json to fall back to'
        end
        return nil, why
    end
    local phrases = {}
    if base then flatten(base, nil, phrases) end
    if data then flatten(data, nil, phrases) end
    local used = lang
    if data == nil then
        used = FALLBACK
        warnOnce('#fallback', ('%s; using en'):format(why))
    end
    state.lang, state.phrases = used, phrases
    return used
end

--- Switch language; the same as load(lang).
---@param lang string
---@return string|nil  the language actually in use
---@return string|nil  why
function M.set(lang)
    return M.load(lang)
end

--- The language in use.
---@return string|nil  nil before anything loaded
function M.getLanguage()
    return state.lang
end

--- Whether a key has a phrase.
---@param key string
---@return boolean
function M.has(key)
    if not state.loaded then M.load() end
    return state.phrases[key] ~= nil
end

local function fill(args)
    return function(name)
        local v = args[name]
        if v == nil then
            return nil
        end
        return tostring(v)
    end
end

--- Translate a key. A table argument fills ${name}; other arguments fill %s in order.
---@param key string  a dotted key such as 'shop.welcome'
---@param ... any  an optional table of named values, then positional values
---@return string  the phrase, or the key itself when there is none
function M.t(key, ...)
    if not state.loaded then M.load() end
    local phrase = state.phrases[key]
    if phrase == nil then
        warnOnce(key, ('no phrase for %q in %s'):format(tostring(key), tostring(state.lang)))
        return tostring(key)
    end
    local nargs = select('#', ...)
    if nargs == 0 then
        return phrase
    end
    local first = ...
    local from = 1
    if type(first) == 'table' then
        phrase = (phrase:gsub('%${([%w_%.%-]+)}', fill(first)))
        from = 2
    end
    if nargs >= from then
        local ok, formatted = pcall(string.format, phrase, select(from, ...))
        if ok then
            return formatted
        end
        warnOnce(key .. '#format', ('the phrase for %q does not fit its arguments: %s'):format(key, tostring(formatted)))
    end
    return phrase
end

-- A MODULE, NOT A GLOBAL.
if ... ~= 'cis_require' then
    CisLocale = M
end

return M
