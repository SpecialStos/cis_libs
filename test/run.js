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
runFile('cis_libstest/shared/report.lua')
runFile('test/run.lua')
runFile('test/binding.lua')
