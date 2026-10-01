-- T4. The pure modules under a REAL Lua 5.4.
--
-- fengari implements Lua 5.3 semantics in JavaScript, and that is not the same
-- thing. Two differences bit this repository already:
--
--   * fengari's string.format('%d', x) REJECTS a float outright, where real
--     Lua 5.3 and 5.4 accept any float with an exact integer representation.
--     A 10-digit version component therefore parsed here and raised there.
--   * Lua 5.4 has integer division, <close>, <const> and to-be-closed variables,
--     none of which fengari has, so a change that uses them passes CI and fails
--     on a server.
--
-- Both directions are wrong: a change can pass here and break on a real server,
-- or fail here for a reason no server would care about. Running the pure
-- modules under real lua5.4 is the only check that covers both.
--
-- NO natives and NO fengari. Anything touching a FiveM native is skipped by
-- construction: this file loads shared/** only, which is exactly the set that
-- is supposed to be portable.

local PURE = {
  'shared/defaults.lua', 'shared/registry.lua', 'shared/grid.lua',
  'shared/pending.lua', 'shared/owned.lua', 'shared/config.lua',
  'shared/ready.lua', 'shared/histogram.lua', 'shared/detect.lua',
  'shared/algo/curve.lua', 'shared/algo/heap.lua', 'shared/algo/interp.lua',
  'shared/algo/lru.lua', 'shared/algo/random.lua', 'shared/algo/rate.lua',
  'shared/algo/sparse.lua', 'shared/algo/window.lua',
  'shared/util/id.lua', 'shared/util/json.lua', 'shared/util/semver.lua',
  'shared/util/string.lua', 'shared/util/table.lua', 'shared/util/time.lua',
  'shared/util/validate.lua',
}

for _, rel in ipairs(PURE) do
  local chunk, err = loadfile('./' .. rel)
  if not chunk then
    io.stderr:write('LUA54 FAIL (load): ' .. rel .. ': ' .. tostring(err) .. '\n')
    os.exit(1)
  end
  local ok, runErr = pcall(chunk)
  if not ok then
    io.stderr:write('LUA54 FAIL (run): ' .. rel .. ': ' .. tostring(runErr) .. '\n')
    os.exit(1)
  end
end

-- A smoke check, so the file cannot pass by loading nothing. `registry.lua`
-- needs `exports`, which is a FiveM global, so the bare-callable path is used:
-- the point is that the module LOADS and the number arithmetic works on a real
-- 5.4 double.
exports = setmetatable({}, { __call = function(t, n, f) t[n] = f end })

local ok, err = pcall(function()
  local g = CisRandom.newGenerator(42)
  assert(type(g) == 'table', 'newGenerator')
  local v = g:int(0, 2 ^ 40)
  assert(type(v) == 'number' and v >= 0 and v <= 2 ^ 40, 'wide range int')
  local d = CisInterp.lerp(0, 10, 0.5)
  assert(math.abs(d - 5) < 1e-9, 'lerp')
  assert(CisSemver.satisfies('1.2.5', '<=1.2') == true, 'semver partial comparator')
  assert(CisSemver.parse('1.2.123456789012345'), 'semver 15 digits')
  local set = CisSparse.new()
  for i = 1, 200 do set[i] = true end
  CisSparse.clear(set)
end)
if not ok then
  io.stderr:write('LUA54 FAIL (smoke): ' .. tostring(err) .. '\n')
  os.exit(1)
end

print(('lua54: %d pure modules loaded and the smoke check passed on %s')
  :format(#PURE, _VERSION))
