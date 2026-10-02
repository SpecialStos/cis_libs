// Run every suite under a real Lua 5.4, not under fengari.
//
// WHY A SEPARATE ENTRY POINT. fengari is Lua 5.3 semantics compiled to
// JavaScript. That is close enough to be dangerous in both directions: a change
// can use a 5.4 construct, pass CI and fail on a server, or fail CI for a reason
// no server would care about. Task 1.7 found a real seeded-RNG defect that only
// exists on a real interpreter, which is the whole argument for keeping this.
//
// The interpreter is looked up rather than assumed: LUAC_LUA54 overrides it,
// then the pinned local dev tools, then whatever is on PATH. If none is found
// this SKIPS rather than fails, because a machine with no Lua installed is not
// a machine whose Lua is broken -- but it says so loudly, because a gate that
// silently stops running is a gate that stopped running a long time ago.

const fs = require('fs')
const os = require('os')
const path = require('path')
const { spawnSync } = require('child_process')

const root = path.join(__dirname, '..')

function findLua() {
  const exe = process.platform === 'win32' ? 'lua54.exe' : 'lua5.4'
  const candidates = [
    process.env.LUAC_LUA54,
    path.join(os.homedir(), '.cis-devtools', exe),
    'lua5.4',
    'lua',
  ].filter(Boolean)
  for (const c of candidates) {
    const r = spawnSync(c, ['-v'], { encoding: 'utf8' })
    if (!r.error && r.status === 0) return c
  }
  return null
}

const lua = findLua()
if (!lua) {
  console.log('SKIP no Lua 5.4 interpreter found (set LUAC_LUA54, or install lua5.4)')
  process.exit(0)
}
const v = spawnSync(lua, ['-v'], { encoding: 'utf8' })
console.log(`lua54 runner: ${String(v.stderr || v.stdout).trim()}`)

const r = spawnSync(lua, ['test/run.lua'], { cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
process.stdout.write(r.stdout || '')
process.stderr.write(r.stderr || '')
process.exit(r.status === null ? 2 : r.status)
