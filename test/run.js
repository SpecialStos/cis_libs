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

// Files the contract tests need to read as text. fengari's io library in the
// node build has no `open`, so the contents are injected from here.
//
// This list is DERIVED FROM THE MANIFEST rather than written out by hand, and
// that is the whole point. The contract suite asserts properties over "every
// file this resource loads" -- most importantly that none of them creates a
// table or calls a third-party resource -- and a hand-maintained list would
// quietly fall behind the next file somebody added, at which point the
// strongest promise in the repository would be checked against a subset of the
// code and still pass.
//
// `init.lua` is added explicitly because consumers `shared_script` it, so it is
// not in any of the manifest's three script blocks. `fxmanifest.lua` is added
// because several contracts read the manifest itself rather than a script.
const EXTRA_INJECTED = ['init.lua', 'fxmanifest.lua']

function manifestScripts() {
  const manifest = fs.readFileSync(path.join(root, 'fxmanifest.lua'), 'utf8')
  const found = new Set(EXTRA_INJECTED)
  // Every quoted string ending in .lua inside the three script blocks. A quoted
  // path is the only form the manifest uses for them, so this is exact rather
  // than approximate.
  for (const m of manifest.matchAll(/'([^']+\.lua)'/g)) {
    found.add(m[1])
  }
  return [...found]
}

function injectFiles(L) {
  lua.lua_createtable(L)
  for (const rel of manifestScripts()) {
    const body = fs.readFileSync(path.join(root, rel), 'utf8')
    lua.lua_pushstring(L, toLua(body))
    lua.lua_setfield(L, -2, toLua(rel))
  }
  lua.lua_setglobal(L, toLua('CIS_TEST_FILES'))
}

function runFile(rel) {
  const src = fs.readFileSync(path.join(root, rel), 'utf8')
  const status = lauxlib.luaL_dostring(L, toLua(src))
  if (status !== lua.LUA_OK) {
    const err = lua.lua_tojsstring(L, -1)
    throw new Error(`${rel}: ${err}`)
  }
}

runFile('shared/defaults.lua')
runFile('shared/registry.lua')
runFile('shared/grid.lua')
runFile('shared/pending.lua')
runFile('shared/config.lua')
runFile('shared/histogram.lua')
runFile('shared/detect.lua')
// The integration harness is a SEPARATE repository and a separate FiveM
// resource (https://github.com/SpecialStos/cis_libstest). It used to be loaded
// here so the library's suite could cover the report encoder and the probe
// helpers -- which was the wrong home for them. The harness tests its own pure
// modules now; this suite covers the library.
injectFiles(L)
runFile('test/run.lua')
runFile('test/binding.lua')
runFile('shared/algo/curve.lua')
runFile('shared/algo/heap.lua')
runFile('shared/algo/interp.lua')
runFile('shared/algo/lru.lua')
runFile('shared/algo/random.lua')
runFile('shared/algo/rate.lua')
runFile('shared/algo/sparse.lua')
runFile('shared/algo/window.lua')
runFile('shared/util/id.lua')
runFile('shared/util/json.lua')
runFile('shared/util/semver.lua')
runFile('shared/util/string.lua')
runFile('shared/util/table.lua')
runFile('shared/util/time.lua')
runFile('shared/util/validate.lua')
runFile('test/contracts.lua')
runFile('test/modules.lua')