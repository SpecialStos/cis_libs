// Orchestrate the suites, each in its own process. T2.
//
// Before this, every suite shared one lua_State and one stdout. Two consequences,
// both of them real:
//
//   * An ordering assumption in one suite was satisfied by a side effect in
//     another. `CisReadyState` is the clearest example: test/client.lua REPLACES
//     it with a stub and saves the original, which only works if the suite that
//     reads it afterwards is looking at the one that was restored. Nothing
//     asserted that; it was an accident that had been load-bearing.
//   * A suite that threw killed every suite after it, and the exit code was the
//     same as a clean pass. A silent exit is indistinguishable from a pass, and
//     the handoff records exactly that having happened once before -- a test that
//     "passed" because it never ran.
//
// One child process per suite fixes both: the state is genuinely fresh, and a
// suite that dies is a suite that reports.
const { spawnSync } = require('child_process')
const path = require('path')
const { judge } = require('./suite-verdict')

const SUITES = [
  ['test/run.lua', 'registry and core'],
  ['test/binding.lua', 'exports self-binding'],
  ['test/contracts.lua', 'exports and init boundary'],
  ['test/modules.lua', 'algo and util modules'],
  ['test/devx.lua', 'developer-experience modules'],
  ['test/client.lua', 'client modules'],
  ['test/interface.lua', 'NUI interface layer'],
  ['test/server.lua', 'server modules'],
  ['test/ctl-allow.lua', 'cis_ctl command allow-list'],
  ['test/examples.lua', 'lua example fences'],
]

const runner = path.join(__dirname, 'suite-runner.js')
const results = []

for (const [file, what] of SUITES) {
  const r = spawnSync(process.execPath, [runner, file], { encoding: 'utf8' })
  const out = `${r.stdout || ''}${r.stderr || ''}`
  process.stdout.write(out)
  results.push({ file, what, ...judge(out, r.status) })
}

console.log('\n===== per-suite summary =====')
let total = 0
for (const r of results) {
  total += r.count
  const verdict = r.ok ? 'ok  ' : 'FAIL'
  const detail = r.crashed ? `crashed (exit ${r.status})` : `${r.count} passed`
  console.log(`  ${verdict}  ${r.file.padEnd(20)} ${detail}`)
}
const failed = results.filter(r => !r.ok)
if (!failed.length) {
  require('../tools/test-counts').save(Object.fromEntries(results.map(r => [r.file, r.count])))
}

// The consumer compatibility check runs HERE rather than only in `npm run
// test:api`, because the promise is that renaming a name a sibling uses turns
// `npm test` red. A check that lives in a script somebody has to remember to
// run is a check that gets skipped, and this one guards 103 names across 28
// sibling resources -- the largest single compatibility surface in the project.
const consumers = spawnSync(
  process.execPath,
  [path.join(__dirname, '..', 'tools', 'check-consumers.js')],
  { encoding: 'utf8' },
)
process.stdout.write(consumers.stdout || '')
if (consumers.stderr) process.stderr.write(consumers.stderr)
const consumersOk = consumers.status === 0
if (consumersOk) total += 1

console.log(`\n${results.length} suites, ${total} assertions, ${failed.length + (consumersOk ? 0 : 1)} failed`)
if (failed.length) {
  for (const r of failed) console.log(`  ${r.file}: ${r.crashed ? `crashed (exit ${r.status})` : r.fails + ' failing assertions'}`)
}
if (!consumersOk) {
  console.log('  consumers: a name a sibling resource uses no longer exists (see above)')
  process.exit(1)
}
if (failed.length) process.exit(1)