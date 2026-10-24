// Run ONE suite in a fresh Lua state. Spawned as a child process by run.js.
//
// T2 wanted each suite in its own Lua state. A child process is the honest way
// to get one: a second lua_State in the same process still shares the JS heap
// that fengari allocates tables on, and "fresh state" that leaks through the
// runtime is worse than no isolation at all, because it looks isolated.
//
// It also solves output capture for free. Two suites printing to one stdout is
// why a per-suite summary needed a writer; here each suite's output is simply
// its own, and run.js can attribute every line to the suite that produced it.
//
// Usage: node test/suite-runner.js <suite.lua>
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

// arg[0] is what binding.lua uses to locate the repo root.
lua.lua_pushstring(L, toLua(path.join(__dirname, 'binding.lua')))
lua.lua_setglobal(L, toLua('arg'))

// The files the contract tests read as text. Derived from the manifest rather
// than written by hand, and that is the whole point: a hand-maintained list
// would quietly fall behind the next file somebody added, at which point the
// strongest promise in the repository would be checked against a subset of the
// code and still pass.
// api.lua joins them: it is not a manifest script -- it is the declaration
// file -- so neither injector saw it, and a suite that reads it got nil and
// reported a confident zero rather than a missing file.
const EXTRA_INJECTED = ['init.lua', 'fxmanifest.lua', 'api.lua']
function manifestScripts() {
  const manifest = fs.readFileSync(path.join(root, 'fxmanifest.lua'), 'utf8')
  const found = new Set(EXTRA_INJECTED)
  for (const m of manifest.matchAll(/'([^']+\.lua)'/g)) found.add(m[1])
  return [...found]
}
function injectFiles() {
  // Tell the suite it is being driven from here. test/run.lua is BOTH a suite
  // and the entry point for a real Lua 5.4 run, and the two modes have to be
  // distinguishable: from here it runs its own assertions and reports, and when
  // launched as `lua5.4 test/run.lua` it drives every suite instead. Without an
  // explicit flag the only difference is which interpreter happens to be
  // running, which is not a distinction worth encoding.
  lua.lua_pushboolean(L, 1)
  lua.lua_setglobal(L, toLua('CIS_SUITE_MODE'))

  lua.lua_createtable(L)
  for (const rel of manifestScripts()) {
    lua.lua_pushstring(L, toLua(fs.readFileSync(path.join(root, rel), 'utf8')))
    lua.lua_setfield(L, -2, toLua(rel))
  }
  lua.lua_pushstring(L, toLua(fs.readFileSync(path.join(root, 'README.md'), 'utf8')))
  lua.lua_setfield(L, -2, toLua('README.md'))
  lua.lua_pushstring(L, toLua(fs.readFileSync(path.join(root, 'DOCUMENTATION.md'), 'utf8')))
  lua.lua_setfield(L, -2, toLua('DOCUMENTATION.md'))
  lua.lua_pushstring(L, toLua(fs.readFileSync(path.join(root, 'LICENSE.md'), 'utf8')))
  lua.lua_setfield(L, -2, toLua('LICENSE.md'))
  lua.lua_setglobal(L, toLua('CIS_TEST_FILES'))
}
injectFiles()

// The source of a re-runnable dependency, so a suite can reload a module from
// SOURCE rather than only seeing the table it left behind. ctl-allow needs
// this: cis_ctl reloads its allow-list once per command, so "does it survive a
// reload" is a question about the chunk, not about one loaded instance.
//
// Named per dependency rather than as a single ALLOW_SOURCE, because by the
// time a suite runs, the most recent file loaded is the SUITE -- not the thing
// it wants to reload.

// Natives a preloaded file calls at load. They exist only while that file loads: a
// suite that reads the global afterwards must see what it set up itself, not ours.
const LOAD_STUBS = ['shared/statebag.lua']
const STUB_ON = `
  _preload_saved = { IsDuplicityVersion = IsDuplicityVersion, AddEventHandler = AddEventHandler, exports = exports }
  IsDuplicityVersion = function() return false end
  AddEventHandler = function() end
  exports = function() end
`
const STUB_OFF = `
  IsDuplicityVersion = _preload_saved.IsDuplicityVersion
  AddEventHandler = _preload_saved.AddEventHandler
  exports = _preload_saved.exports
  _preload_saved = nil
`
function run(rel) {
  const src = fs.readFileSync(path.join(root, rel), 'utf8')
  if (/cis_ctl[\\/]server[\\/]allow\.lua$/.test(rel)) {
    lua.lua_pushstring(L, toLua(src))
    lua.lua_setglobal(L, toLua('CIS_CTL_ALLOW_SOURCE'))
  }
  const stubbed = LOAD_STUBS.includes(rel)
  if (stubbed) lauxlib.luaL_dostring(L, toLua(STUB_ON))
  const status = lauxlib.luaL_dostring(L, toLua(src))
  const err = status !== lua.LUA_OK ? lua.lua_tojsstring(L, -1) : null
  if (stubbed) lauxlib.luaL_dostring(L, toLua(STUB_OFF))
  if (err !== null) throw new Error(`${rel}: ${err}`)
}

// Exactly what each suite saw before isolation, so no suite changes behaviour.
// run.lua and binding.lua ran BEFORE the algo/util modules existed in the shared
// state; everything else ran after. Preserving that split is the whole reason
// this list is per-suite rather than "load everything, always".
const SHARED = [
  // First, like the manifest: identity before anything that could run as a
  // rename, then the counters have to exist before the first thing that
  // counts one.
  'shared/identity.lua',
  'shared/diagnostics.lua',
  'shared/timing.lua',
  // Then loopguard, in the manifest's order: a guarded loop counts into
  // diagnostics, so it needs the counter to exist first.
  'shared/loopguard.lua',
  'shared/defaults.lua', 'shared/registry.lua', 'shared/grid.lua',
  'shared/zonegeom.lua', 'shared/hooks.lua',
  'shared/pending.lua', 'shared/utf8.lua', 'shared/owned.lua', 'shared/config.lua',
  'shared/histogram.lua', 'shared/ready.lua', 'shared/detect.lua',
  // Last, like the manifest. statebag.lua calls IsDuplicityVersion, AddEventHandler
  // and exports at load, which no suite has stubbed yet, so run() gives it three
  // throwaway stubs (LOAD_STUBS) and takes them away again.
  'shared/statebag.lua',
]
// SHARED IS THE MANIFEST'S shared_scripts, in the manifest's order, minus init.lua
// (which the suites load themselves). It used to be a hand-kept copy that had
// drifted twice -- histogram and ready swapped, statebag missing -- so it is
// compared here and a drift stops the run before any suite does.
function manifestSharedScripts() {
  const manifest = fs.readFileSync(path.join(root, 'fxmanifest.lua'), 'utf8')
  const block = /shared_scripts\s*\{([^}]*)\}/.exec(manifest)
  if (!block) throw new Error('fxmanifest.lua has no shared_scripts block')
  return [...block[1].matchAll(/'([^']+\.lua)'/g)].map(m => m[1]).filter(f => f !== 'init.lua')
}
const expectedShared = manifestSharedScripts()
if (JSON.stringify(SHARED) !== JSON.stringify(expectedShared)) {
  console.error('test preload order differs from fxmanifest.lua shared_scripts')
  console.error(`  manifest: ${expectedShared.join(' ')}`)
  console.error(`  runner:   ${SHARED.join(' ')}`)
  process.exit(2)
}
const ALGO_UTIL = [
  'shared/algo/curve.lua', 'shared/algo/heap.lua', 'shared/algo/interp.lua',
  'shared/algo/lru.lua', 'shared/algo/random.lua', 'shared/algo/rate.lua',
  'shared/algo/sparse.lua', 'shared/algo/window.lua',
  'shared/util/id.lua', 'shared/util/json.lua', 'shared/util/semver.lua',
  'shared/util/string.lua', 'shared/util/table.lua', 'shared/util/time.lua',
  'shared/util/validate.lua',
]
// The integration harness is a SEPARATE repository and a separate FiveM
// resource. It used to be loaded here so the library's suite could cover the
// report encoder; the harness tests its own pure modules now.
const SUITES = {
  'test/run.lua': SHARED,
  'test/binding.lua': SHARED,
  'test/contracts.lua': [...SHARED, ...ALGO_UTIL],
  'test/modules.lua': [...SHARED, ...ALGO_UTIL],
  // The developer-experience modules load THEMSELVES, the way Cis.require
  // does (with the 'cis_require' marker), so nothing is preloaded and no
  // legacy global is in scope to be read by accident.
  'test/devx.lua': [],
  'test/client.lua': [...SHARED, ...ALGO_UTIL],
  // The NUI layer needs the shared plumbing (diagnostics, CisOwned,
  // CisCallable) and nothing else; it loads its own files per test.
  'test/interface.lua': SHARED,
  // server/logging.lua is NOT preloaded here. It was, and that is an isolation
  // finding rather than a convenience: in the shared lua_State this suite never
  // loaded it at all -- `Logging` was a global left behind by an earlier suite,
  // and server/sync.lua indexes it on its first error path. It cannot be
  // preloaded either, because logging.lua calls `exports(...)` at load time and
  // only the suite's own env provides that. test/server.lua therefore loads it
  // inside newEnv, which is the honest version of the dependency every env was
  // already relying on.
  'test/server.lua': [...SHARED, ...ALGO_UTIL],
  // The cis_ctl allow-list, and nothing else. cis_ctl is a live-harness
  // resource like the cis_test* set, and its command surface is the only thing
  // stopping the agent from typing an arbitrary console command -- so it is
  // tested the same way the library is: in a fresh state, on both interpreters.
  // It needs no preload of the library's modules because it depends on none,
  // which is the point of keeping it pure Lua.
  'test/ctl-allow.lua': ['test/live/cis_ctl/server/allow.lua'],
  'test/examples.lua': [],
}

const suite = process.argv[2]
if (!SUITES[suite]) {
  console.error(`unknown suite: ${suite}`)
  process.exit(2)
}
for (const f of SUITES[suite]) run(f)
run(suite)