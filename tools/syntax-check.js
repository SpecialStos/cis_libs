// syntax-check.js -- parse every .lua file in the repo and report syntax errors.
//
// CI does this with luac5.4. Locally there is no Lua on PATH, and a parse error
// in the integration harness is expensive to find: FiveM reports it on resource
// start, the resource still says "Started", and every later command that
// depends on it fails with a misleading message. This catches it before deploy.
//
// fengari is already a dependency and is a real Lua parser, so it needs nothing
// installed. It cannot parse FiveM's backtick hash literals (`` `WEAPON_X` ``),
// which is the same exemption CI applies, so those are reported as skipped
// rather than failures.
//
// Usage:  node tools/syntax-check.js
// Exit 0 clean, 1 on a syntax error.
const fs = require('fs')
const path = require('path')
const fengari = require('fengari')
const lua = fengari.lua
const lauxlib = fengari.lauxlib
const lualib = fengari.lualib
const toLu = fengari.to_luastring

const root = path.join(__dirname, '..')
const SKIP_DIRS = new Set(['node_modules', '.git', '.zcode', '.claude', 'cache', 'reports'])

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (SKIP_DIRS.has(e.name)) continue
    const p = path.join(dir, e.name)
    if (e.isDirectory()) walk(p, out)
    else if (e.name.endsWith('.lua')) out.push(p)
  }
  return out
}

const files = walk(root)
let failed = 0
let skipped = 0

for (const abs of files) {
  const rel = path.relative(root, abs)
  const L = lauxlib.luaL_newstate()
  lualib.luaL_openlibs(L)
  const src = fs.readFileSync(abs, 'utf8')
  const status = lauxlib.luaL_loadbuffer(L, toLu(src), toLu(rel))

  if (status === lua.LUA_OK) {
    continue
  }
  const err = lua.lua_tojsstring(L, -1)

  // FiveM hash literals are not valid standard Lua. Same exemption CI gives,
  // and it is safe: these files are not run outside the engine. Matched on the
  // backtick itself rather than the whole message, so a real syntax error that
  // happens to say "unexpected symbol near" is still reported.
  if (err.includes("near '`'")) {
    console.log(`skip  ${rel}  (FiveM backtick hash literal)`)
    skipped++
    continue
  }
  // fengari is Lua 5.3; FiveM and CI's luac5.4 accept 5.4 variable attributes
  // (`local x <const> = ...`). Skipped only when the failing line holds one.
  const at = /:(\d+):/.exec(err)
  const line = at ? src.split('\n')[Number(at[1]) - 1] || '' : ''
  if (err.includes("near '<'") && /<\s*(const|close)\s*>/.test(line)) {
    console.log(`skip  ${rel}  (Lua 5.4 attribute, fengari is 5.3)`)
    skipped++
    continue
  }
  console.error(`FAIL  ${rel}\n      ${err}`)
  failed++
}

console.log(`\nsyntax-check: ${files.length} files, ${failed} syntax errors, ${skipped} skipped`)
process.exit(failed ? 1 : 0)
