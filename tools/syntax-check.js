// syntax-check.js -- parse every .lua file in the repo and report syntax errors.
//
// Locally there is no Lua on PATH, and a parse error in the integration harness
// is expensive to find: FiveM reports it on resource start, the resource still
// says "Started", and every later command that depends on it fails with a
// misleading message. This catches it before deploy. (CI does not run luac. It
// runs luacheck, which parses every file too, and the suites under fengari and
// under a real Lua 5.4; this tool is the quick local check.)
//
// fengari is already a dependency and is a real Lua parser, so it needs nothing
// installed. It is Lua 5.3 and cannot parse two things FiveM accepts:
//   * backtick hash literals (`WEAPON_X`), and
//   * 5.4 variable attributes (`local x <const> = ...`).
// A file with either is NOT skipped. Only those constructs are blanked out, with
// text of exactly the same length (the same trick tools/lint.js plays for
// luacheck), and the rest of the file is parsed, so a real syntax error in
// client/cache.lua or client/weapon.lua is still found, on its real line.
//
// Usage:  node tools/syntax-check.js
// Exit 0 clean, 1 on a syntax error.
const fs = require('fs')
const path = require('path')
const fengari = require('fengari')
const { neutraliseBackticks } = require('./lint.js')
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

function parse(src, name) {
  const L = lauxlib.luaL_newstate()
  lualib.luaL_openlibs(L)
  const buf = toLu(src)
  const status = lauxlib.luaL_loadbuffer(L, buf, buf.length, toLu('@' + name))
  return status === lua.LUA_OK ? null : lua.lua_tojsstring(L, -1)
}

// Blank the constructs fengari cannot parse, keeping every byte offset.
function neutralise(src) {
  const withoutHashes = neutraliseBackticks(src)
  const hashes = withoutHashes === src ? 0 : 1
  let attributes = 0
  const out = withoutHashes.split('\n').map(line => {
    if (!/^\s*local\b/.test(line)) return line
    return line.replace(/<[ \t]*(const|close)[ \t]*>/g, m => { attributes++; return ' '.repeat(m.length) })
  }).join('\n')
  return { src: out, hashes, attributes }
}

// Returns { error, neutralised } where error is null for a clean parse.
function checkSource(src, name) {
  const err = parse(src, name)
  if (!err) return { error: null, neutralised: false }
  const n = neutralise(src)
  if (n.src === src) return { error: err, neutralised: false }
  const err2 = parse(n.src, name)
  return { error: err2, neutralised: !err2 }
}

function main() {
  const files = walk(root)
  let failed = 0
  let neutralised = 0

  for (const abs of files) {
    const rel = path.relative(root, abs)
    const res = checkSource(fs.readFileSync(abs, 'utf8'), rel)
    if (res.error) {
      console.error(`FAIL  ${rel}\n      ${res.error}`)
      failed++
    } else if (res.neutralised) {
      console.log(`ok    ${rel}  (parsed with FiveM hash literals / 5.4 attributes blanked)`)
      neutralised++
    }
  }

  console.log(`\nsyntax-check: ${files.length} files, ${failed} syntax errors, ${neutralised} parsed with FiveM-only syntax blanked`)
  return failed ? 1 : 0
}

if (require.main === module) process.exit(main())

module.exports = { checkSource }
