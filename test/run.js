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

const SUITES = [
  ['test/run.lua', 'registry and core'],
  ['test/binding.lua', 'exports self-binding'],
  ['test/contracts.lua', 'exports and init boundary'],
  ['test/modules.lua', 'algo and util modules'],
  ['test/client.lua', 'client modules'],
  ['test/server.lua', 'server modules'],
  ['test/ctl-allow.lua', 'cis_ctl command allow-list'],
]

const runner = path.join(__dirname, 'suite-runner.js')
const results = []

for (const [file, what] of SUITES) {
  const r = spawnSync(process.execPath, [runner, file], { encoding: 'utf8' })
  const out = `${r.stdout || ''}${r.stderr || ''}`
  process.stdout.write(out)

  // A suite reports its own line. Three things are consulted, because trusting
  // any one of them is how a suite "passes" having never run:
  //
  //   * the exit status -- a suite that throws prints no summary at all;
  //   * the summary line -- the suite's own count;
  //   * EVERY `FAIL` line in the output, counted independently.
  //
  // The third is not redundant. A suite writes its summary with io.write and its
  // failures with io.stderr:write, so a failure that happens after the summary
  // is printed is counted in neither. That is exactly the "silent exit is
  // indistinguishable from a pass" failure this rewrite exists to remove, and it
  // was reproduced deliberately: appending `expect(false)` to the end of
  // modules.lua printed "module tests: passed=326 failed=0" and exited 0, with
  // the FAIL sitting on stderr underneath it. A runner that only reads the
  // summary would have passed that run.
  const summary = out.split(/\r?\n/).find(l => /passed=\d+/.test(l)) || ''
  const fails = (out.match(/^FAIL/gm) || []).length
  const crashed = r.status !== 0
  const reportedFail = /failed=[1-9]/.test(summary)
  const ok = !crashed && !reportedFail && fails === 0 && /passed=\d+/.test(summary)

  let count = 0
  const m = /passed=(\d+)/.exec(summary)
  if (m) count = Number(m[1])
  results.push({ file, what, ok, count, fails, crashed, status: r.status, summary: summary.trim() })
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