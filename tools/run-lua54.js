// Run every suite under a real Lua 5.4, not under fengari.
//
// WHY A SEPARATE ENTRY POINT. fengari is Lua 5.3 semantics compiled to
// JavaScript. That is close enough to be dangerous in both directions: a change
// can use a 5.4 construct, pass CI and fail on a server, or fail CI for a reason
// no server would care about. Task 1.7 found a real seeded-RNG defect that only
// exists on a real interpreter, which is the whole argument for keeping this.
//
// The interpreter is looked up rather than assumed: LUAC_LUA54 overrides it,
// then the pinned local dev tools, then whatever is on PATH.
//
// NOT FOUND is two different answers. On a developer machine it SKIPS, loudly:
// a machine with no Lua installed is not a machine whose Lua is broken. Under
// CI (the `CI` environment variable, which GitHub Actions and every other CI
// sets) it FAILS: the workflow installs lua5.4 for exactly this step, so a
// missing interpreter there means the step that was supposed to run did not,
// and an exit 0 would report the second interpreter as passing when it never
// ran. A gate that silently stops running is a gate that stopped running a
// long time ago.

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

function ciIsSet() {
  const v = process.env.CI
  return v !== undefined && v !== '' && v !== '0' && v.toLowerCase() !== 'false'
}

const lua = findLua()
if (!lua) {
  const why = 'no Lua 5.4 interpreter found (set LUAC_LUA54, or install lua5.4)'
  if (ciIsSet()) {
    console.error(`FAIL ${why}. CI is set, so the Lua 5.4 suites are required, not optional.`)
    process.exit(1)
  }
  const bar = '!'.repeat(72)
  console.error([
    bar,
    `WARNING  SKIP ${why}.`,
    'WARNING  The suites ran under fengari (Lua 5.3 semantics, 32-bit integers) ONLY.',
    'WARNING  Integer division, %d formatting and math.floor differ on a real 5.4.',
    'WARNING  Under CI this is a failure, not a skip.',
    bar,
  ].join('\n'))
  process.exit(0)
}
const v = spawnSync(lua, ['-v'], { encoding: 'utf8' })
console.log(`lua54 runner: ${String(v.stderr || v.stdout).trim()}`)

const r = spawnSync(lua, ['test/run.lua'], { cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
process.stdout.write(r.stdout || '')
process.stderr.write(r.stderr || '')
if (r.status !== 0) process.exit(r.status === null ? 2 : r.status)

// THE DRIVER FAILS A BROKEN SUITE. Each fixture is wrong in a way the case list
// alone does not show; a driver that passes one would pass a real suite broken
// the same way.
const BROKEN = {
  'test/fixtures/suite-early-exit.lua': 'stopped before its end',
  'test/fixtures/suite-empty.lua': 'ran no assertion',
}
for (const [fixture, why] of Object.entries(BROKEN)) {
  const b = spawnSync(lua, ['test/run.lua'], {
    cwd: root, encoding: 'utf8', env: { ...process.env, CIS_LUA54_ONLY: fixture },
  })
  if (b.status === 0 || !String(b.stderr).includes(why)) {
    console.error(`FAIL the Lua 5.4 driver passed ${fixture} (expected "${why}"); exit ${b.status}`)
    console.error(String(b.stderr || '').trim())
    process.exit(1)
  }
}
console.log(`lua54 driver: fails ${Object.keys(BROKEN).length} broken fixture suites`)

// THE SAME COUNT AS FENGARI, suite by suite, apart from deliberate differences.
const counts = require('./test-counts')
if (counts.compare({ 'a.lua': 2 }, { 'a.lua': 1 }).length !== 1 || counts.compare({ 'a.lua': 2 }, { 'a.lua': 2 }).length !== 0) {
  console.error('FAIL tools/test-counts.js compare() does not report a one-assertion difference')
  process.exit(1)
}
const lua54 = {}
for (const m of String(r.stdout).matchAll(/^lua54-suite (\S+) passed=(\d+)/gm)) lua54[m[1]] = Number(m[2])
const fengari = counts.load()
if (!fengari) {
  const why = 'no fengari counts for this tree (run `npm test` first)'
  if (ciIsSet()) {
    console.error(`FAIL ${why}. CI is set, so the counts must be compared.`)
    process.exit(1)
  }
  console.error(`WARNING  count comparison skipped: ${why}`)
  process.exit(0)
}
const bad = counts.compare(fengari, lua54)
if (bad.length) {
  console.error('FAIL assertion counts differ between Lua 5.4 and fengari:')
  for (const line of bad) console.error(`  ${line}`)
  console.error('  An assertion that runs under one interpreter only is switched off on the other.')
  console.error('  If the difference is deliberate, add it to KNOWN_DELTA in tools/test-counts.js.')
  process.exit(1)
}
console.log(`lua54 counts: ${Object.keys(lua54).length} suites match the fengari run`)
