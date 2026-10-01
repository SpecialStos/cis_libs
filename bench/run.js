// Benchmark harness. T5.
//
// `npm run bench`. NOT run in CI -- a benchmark on shared hardware measures
// the hardware, and a gate built on one fires on a slow runner and gets
// ignored. This is a tool for whoever is changing the code.
//
// The Lua lives in bench/bench.lua because the interesting part is the workload
// definition, not the timing loop. Both halves print their conditions: a bare
// ops-per-second number is a claim without a caveat and gets quoted without one.
const fs = require('fs')
const path = require('path')
const fengari = require('fengari')
const lua = fengari.lua
const lauxlib = fengari.lauxlib
const lualib = fengari.lualib
const toLua = fengari.to_luastring

const root = path.join(__dirname, '..')
const L = lauxlib.luaL_newstate()
lualib.luaL_openlibs(L)

// Same order the manifest uses, so the benchmark measures the same
// configuration a server loads.
const PRELOAD = [
  'shared/defaults.lua', 'shared/registry.lua', 'shared/grid.lua',
  'shared/pending.lua', 'shared/owned.lua', 'shared/config.lua',
  'shared/ready.lua', 'shared/histogram.lua', 'shared/detect.lua',
  'shared/algo/curve.lua', 'shared/algo/heap.lua', 'shared/algo/interp.lua',
  'shared/algo/lru.lua', 'shared/algo/random.lua', 'shared/algo/rate.lua',
  'shared/algo/sparse.lua', 'shared/algo/window.lua',
  'shared/util/id.lua', 'shared/util/json.lua', 'shared/util/semver.lua',
  'shared/util/string.lua', 'shared/util/table.lua', 'shared/util/time.lua',
  'shared/util/validate.lua',
]

function run(rel) {
  const src = fs.readFileSync(path.join(root, rel), 'utf8')
  const status = lauxlib.luaL_dostring(L, toLua(src))
  if (status !== lua.LUA_OK) throw new Error(`${rel}: ${lua.lua_tojsstring(L, -1)}`)
}

// `exports` is a FiveM global and the registry reads it at load time, so it has
// to exist before anything is preloaded. Callable, because resources register
// exports with `exports('Name', fn)` rather than assigning them.
lauxlib.luaL_dostring(L, toLua(`
  exports = setmetatable({}, { __call = function(t, name, fn) t[name] = fn end })
`))

for (const f of PRELOAD) run(f)

// The provider the registry benchmark dispatches through. A real table export,
// so `call()` takes the cross-boundary path a server actually takes.
lauxlib.luaL_dostring(L, toLua(`
  local provider = {}
  provider.query = function(_, sql) return { rows = { { sql } } } end
  exports['cis_bench'] = provider
`))

run('bench/bench.lua')