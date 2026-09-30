// report.js -- read a cis_libstest JSON report and say what actually happened.
//
// The console prints a one-line summary, which is not enough to work from:
// a skip carries a reason, a failure carries detail and measured values, and
// a run that is "green" with 40 skips has verified almost nothing. This prints
// all of it, grouped by status, so the reason for every non-pass is visible.
//
// Usage:  node tools/report.js [path-to-report.json]
//         node tools/report.js --latest [dir]
//
const fs = require('fs')
const path = require('path')

function findReport(arg) {
  const dir = arg || path.join(__dirname, '..', 'reports')
  const files = fs.existsSync(dir)
    ? fs.readdirSync(dir).filter((f) => f.endsWith('.json'))
    : []
  if (!files.length) {
    console.error(`no report found in ${dir}`)
    process.exit(1)
  }
  files.sort()
  return path.join(dir, files[files.length - 1])
}

const file = findReport(process.argv[2] && !process.argv[2].startsWith('--')
  ? process.argv[2]
  : path.join(process.env.CIS_STEST_DIR || path.join(__dirname, '..', 'reports')))
const r = JSON.parse(fs.readFileSync(file, 'utf8'))

// The report keeps server tests in `server` and client tests in `client`.
// The client array is FLAT -- one entry per test, each carrying its own
// `player` -- so it is not a list of per-player wrappers. A server-only run
// leaves `client` as an empty object rather than an array.
const asArray = (v) => (Array.isArray(v) ? v : [])
const all = []
for (const t of asArray(r.server)) all.push({ ...t, realm: 'server', player: null })
for (const t of asArray(r.client)) {
  all.push({ ...t, realm: 'client', player: t.player ?? null })
}

const by = (s) => all.filter((t) => t.status === s)
const line = (t) => {
  const who = t.realm === 'client' ? `[player ${t.player}] ` : ''
  return `${who}${t.name}`
}

console.log('='.repeat(78))
console.log(`report: ${path.basename(file)}`)
if (r.meta) {
  const m = r.meta
  console.log(`framework=${m.framework || '?'}  mutating=${m.mutating}  teleport=${m.teleport}  ` +
    `probes=${m.probes}  clients=${m.clientsReporting ?? '?'}`)
}
console.log('='.repeat(78))
console.log(`TOTAL ${all.length}  |  passed ${by('passed').length}  |  failed ${by('failed').length}  |  skipped ${by('skipped').length}`)
console.log('')

if (by('failed').length) {
  console.log('--- FAILURES (must be zero) ' + '-'.repeat(50))
  for (const t of by('failed')) {
    console.log(`\n  ${line(t)}`)
    console.log(`    message : ${t.message}`)
    if (t.detail) console.log(`    detail  : ${t.detail}`)
    if (t.values && Object.keys(t.values).length) {
      console.log(`    values  : ${JSON.stringify(t.values)}`)
    }
  }
  console.log('')
}

if (by('skipped').length) {
  console.log('--- SKIPPED (a skip is NOT a pass) ' + '-'.repeat(40))
  const groups = {}
  for (const t of by('skipped')) {
    const key = (t.message || '').split(':')[0].trim()
    ;(groups[key] = groups[key] || []).push(t)
  }
  for (const [reason, ts] of Object.entries(groups)) {
    console.log(`\n  ${ts.length}x  ${reason}`)
    for (const t of ts) {
      console.log(`      - ${t.name}`)
      const m = (t.message || '').replace(/^[^:]*:\s*/, '')
      if (m) console.log(`        ${m}`)
    }
  }
  console.log('')
}

const vals = all.filter((t) => t.values && Object.keys(t.values).length)
if (vals.length) {
  console.log('--- MEASURED VALUES ' + '-'.repeat(55))
  for (const t of vals) {
    console.log(`  ${line(t)}`)
    console.log(`    ${JSON.stringify(t.values)}`)
  }
  console.log('')
}

console.log('='.repeat(78))
process.exit(by('failed').length ? 1 : 0)
