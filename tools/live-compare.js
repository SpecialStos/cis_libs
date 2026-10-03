// Does the VPS behave like the PC did? W7.
//
//   node tools/live-compare.js            compare the two most recent VPS runs
//   node tools/live-compare.js --baseline path/to/results_pc.json
//
// The move to a new machine is only proven when the new machine produces the
// SAME failures as the old one. Not fewer, not more: a fixed failure means the
// test no longer covers something, and a new one means the move changed
// behaviour. Either is a finding, and both are invisible unless the sets are
// compared directly.
//
// TWO COMPARISONS, AND THEY ANSWER DIFFERENT QUESTIONS.
//
//   run vs baseline   is the VPS behaving like the PC? This is W7's question,
//                     and it is the one that decides whether the PC can be shut
//                     down.
//   run vs run        is the VPS deterministic? Two runs that disagree mean the
//                     harness is reporting noise, and every comparison built on
//                     it is worthless -- including this one.
//
// COUNTS ARE NOT COMPARED, ONLY THE FAILING CASE NAMES. A count moves whenever
// a suite is added, a tier gains a case, or a client is or is not connected --
// all of which are expected between two machines. A failing CASE is the thing
// that has to match, and it is identified by suite plus case name, which is
// stable across machines and across runs.
//
// SKIP IS COUNTED SEPARATELY AND NEVER TREATED AS PASS. A run on a machine with
// no client SKIPs the player tier; the PC ran with one connected. That is a
// real difference in the two runs and it is reported as such, not smoothed over.

const fs = require('fs')
const path = require('path')

const root = path.join(__dirname, '..')
const ENV = path.join(root, '.live-env.json')
const RESULTS_DIR = path.join(root, 'test', 'live', 'results')

function loadEnv() {
  if (!fs.existsSync(ENV)) {
    console.error('live-compare: .live-env.json is missing.')
    process.exit(2)
  }
  try {
    return JSON.parse(fs.readFileSync(ENV, 'utf8'))
  } catch (e) {
    console.error('live-compare: .live-env.json is not valid JSON: ' + e.message)
    process.exit(2)
  }
}

function readJson(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')) } catch { return null }
}

// The identity of a failing case. Deliberately not the message: a message that
// embeds a timing or a coordinate would make every run look like a difference.
function failingSet(results) {
  const set = new Set()
  for (const c of (results && results.cases) || []) {
    const status = String(c.status || '').toUpperCase()
    if (status === 'FAIL' || status === 'ERROR') {
      set.add(`${c.suite} :: ${c.case}`)
    }
  }
  return set
}

function skippedSet(results) {
  const set = new Set()
  for (const c of (results && results.cases) || []) {
    if (String(c.status || '').toUpperCase() === 'SKIP') set.add(`${c.suite} :: ${c.case}`)
  }
  return set
}

function tally(results) {
  return (results && results.tally) || {}
}

function describe(label, r) {
  const t = tally(r)
  return `${label.padEnd(26)} run ${String(r.run).padEnd(24)} ` +
    `pass ${t.pass || 0} fail ${t.fail || 0} skip ${t.skip || 0} error ${t.error || 0}`
}

function diff(label, a, b, noun) {
  const onlyA = [...a].filter(x => !b.has(x)).sort()
  const onlyB = [...b].filter(x => !a.has(x)).sort()
  if (!onlyA.length && !onlyB.length) {
    console.log(`  ${label}: IDENTICAL (${a.size} ${noun})`)
    return 0
  }
  console.log(`  ${label}: ${a.size} vs ${b.size} -- DIFFERENT`)
  for (const x of onlyA) console.log(`      only in the first:  ${x}`)
  for (const x of onlyB) console.log(`      only in the second: ${x}`)
  return onlyA.length + onlyB.length
}

function recentRuns(n) {
  if (!fs.existsSync(RESULTS_DIR)) return []
  return fs.readdirSync(RESULTS_DIR)
    .filter(f => /^run-.*\.json$/.test(f))
    .sort()
    .slice(-n)
    .map(f => ({ file: f, results: readJson(path.join(RESULTS_DIR, f)) }))
    .filter(r => r.results)
}

function main() {
  const argv = process.argv.slice(2)
  const bi = argv.indexOf('--baseline')
  const env = loadEnv()
  const baselinePath = bi !== -1 ? argv[bi + 1] : env.baselineResults

  const runs = recentRuns(2)
  if (!runs.length) {
    console.error('live-compare: no runs in test/live/results/. Run: npm run live:run -- all')
    process.exit(2)
  }

  console.log('VPS runs (newest last)')
  for (const r of runs) console.log('  ' + describe(r.results.run, r.results))
  const a = runs[0].results
  const b = runs[runs.length - 1].results

  console.log('')
  console.log('DETERMINISM: the two most recent VPS runs')
  let differences = 0
  if (runs.length === 1) {
    console.log('  only one run kept; run npm run live:run twice to compare')
  } else {
    differences += diff('failing cases', failingSet(a), failingSet(b), 'failing case(s)')
    const sDiff = diff('skipped cases', skippedSet(a), skippedSet(b), 'skipped case(s)')
    if (sDiff) {
      console.log('    a SKIP difference is expected when a client connects or does not,')
      console.log('    and is not a defect. A FAIL difference is.')
    }
  }

  console.log('')
  console.log('W7: the VPS against the PC baseline')
  if (!baselinePath) {
    console.log('  no baselineResults in .live-env.json and no --baseline given')
    console.log('  FAILED: the move is not proven until this comparison runs')
    process.exit(1)
  }
  if (!fs.existsSync(baselinePath)) {
    console.log(`  baseline not found: ${baselinePath}`)
    console.log('  FAILED: copy the PC\'s results_latest.json there (setup 3.6 step 4)')
    process.exit(1)
  }
  const base = readJson(baselinePath)
  if (!base) {
    console.log(`  baseline is not readable JSON: ${baselinePath}`)
    process.exit(1)
  }
  console.log('  ' + describe('PC baseline', base))
  console.log('  ' + describe('VPS newest', b))
  console.log('')
  const bd = diff('failing cases', failingSet(base), failingSet(b), 'failing case(s)')
  const bs = diff('skipped cases', skippedSet(base), skippedSet(b), 'skipped case(s)')
  differences += bd

  console.log('')
  if (base.commit !== b.commit) {
    console.log(`  NOTE: the baseline is commit ${base.commit} and this run is ${b.commit}.`)
    console.log('  Different builds make an identical FAIL set meaningful, and a')
    console.log('  different one not diagnostic of anything.')
  } else {
    console.log(`  both runs are commit ${base.commit}: the comparison is like for like.`)
  }

  console.log('')
  if (bd === 0 && bs === 0 && differences === 0) {
    console.log('PASS: the VPS reproduces the PC exactly. The PC server can be shut down.')
    process.exit(0)
  }
  if (bd === 0) {
    console.log('PASS on FAIL sets (identical). Differences above are SKIPs only, which is')
    console.log('expected when one machine has a client connected and the other does not.')
    console.log('Review the SKIP list above, then the PC server can be shut down.')
    process.exit(0)
  }
  console.log('FAILED: the FAIL sets differ. That is a finding, not a pass.')
  console.log('Record it with all three run ids before drawing any conclusion.')
  process.exit(1)
}

main()