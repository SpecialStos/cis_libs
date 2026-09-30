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
const INJECTED_FILES = [
  'init.lua',
  'configs/master_config.lua',
  'configs/security_config.lua',
  'server/version.lua',
  'server/security.lua',
  'server/database.lua',
  'server/initialize.lua',
  'server/security.lua',
  'fxmanifest.lua',
]

function injectFiles(L) {
  lua.lua_createtable(L)
  for (const rel of INJECTED_FILES) {
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
runFile('test/contracts.lua')