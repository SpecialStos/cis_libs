// Builds TEST_MATRIX.json -- one file carrying every test case from every
// layer, so nothing is hidden behind a pass/fail count.
//
//   node tools/test-matrix.js
//
// Layers:
//   unit       shared/ modules, fuzzed against brute-force references
//   binding    argument-slot checks for the exports boundary (the self trap)
//   contracts  the machine-readable api.lua contract
//   server     live integration, from the latest cis_libstest report
//   client     live integration, from the latest cis_libstest report
//
// A layer that has not run is recorded as `not run`, never omitted. This file
// exists to make coverage visible, and a missing layer that looks like a pass
// is the exact failure it is meant to prevent.

const fs = require('fs')
const path = require('path')
const { spawnSync } = require('child_process')

const root = path.join(__dirname, '..')
const OUT = path.join(root, 'TEST_MATRIX.json')

const NEWLINE = String.fromCharCode(10)

const PURE_LAYERS = [
  { key: 'unit', suite: 'test/run.lua', note: 'shared/ modules; the grid is fuzzed against a brute-force reference' },
  { key: 'binding', suite: 'test/binding.lua', note: 'exports-boundary argument slots; guards the self trap' },
  { key: 'contracts', suite: 'test/contracts.lua', note: 'api.lua contract vs the real registered surface' },
]

// ---------------------------------------------------------------- live report
function latestLiveReport() {
  const dir = path.join(root, 'cis_libstest')
  if (!fs.existsSync(dir)) return null
  const files = fs.readdirSync(dir).filter((f) => /^cis-test-report-.*\.json$/.test(f)).sort()
  if (!files.length) return null
  const newest = files[files.length - 1]
  try {
    return { file: newest, data: JSON.parse(fs.readFileSync(path.join(dir, newest), 'utf8')) }
  } catch (e) {
    return { file: newest, error: String(e.message) }
  }
}

// ------------------------------------------------------------- pure suites
// spawnSync is SYNCHRONOUS. An earlier version wrapped it in a Promise and
// never awaited it, so every layer read undefined and the matrix reported
// NOT RUN for all of them -- a false signal in the one file whose job is to
// report the truth.
function runPureSuites() {
  const res = spawnSync(process.execPath, [path.join(root, 'test', 'run.js')], {
    cwd: root,
    encoding: 'utf8',
  })
  return { stdout: res.stdout || '', stderr: res.stderr || '', status: res.status }
}

function parseCounters(stdout) {
  const out = {}
  for (const line of stdout.split(NEWLINE)) {
    // The first suite prints "passed=N failed=N"; the others prefix a name.
    const named = line.match(/^(\w+)\s+passed=(\d+)\s+failed=(\d+)/)
    if (named) {
      out[named[1]] = {
        passed: Number(named[2]),
        failed: Number(named[3]),
        total: Number(named[2]) + Number(named[3]),
      }
      continue
    }
    const bare = line.match(/^passed=(\d+)\s+failed=(\d+)/)
    if (bare) {
      out.unit = {
        passed: Number(bare[1]),
        failed: Number(bare[2]),
        total: Number(bare[1]) + Number(bare[2]),
      }
    }
  }
  return out
}

// ------------------------------------------------------------------- shape
function normaliseLive(rows, realm) {
  return (rows || []).map((r) => ({
    name: r.name,
    status: r.status,
    realm,
    player: r.player === undefined ? null : r.player,
    durationMs: r.durationMs === undefined ? null : r.durationMs,
    message: r.message === undefined ? null : r.message,
    detail: r.detail === undefined ? null : r.detail,
    values: r.values || {},
  }))
}

function main() {
  const pure = runPureSuites()
  const counters = parseCounters(pure.stdout)
  const live = latestLiveReport()

  const layers = {}
  const cases = []
  const totals = { total: 0, passed: 0, failed: 0, skipped: 0 }

  for (const l of PURE_LAYERS) {
    const c = counters[l.key]
    if (c) {
      layers[l.key] = {
        status: 'ran',
        passed: c.passed,
        failed: c.failed,
        total: c.total,
        suite: l.suite,
        note: l.note,
      }
      totals.total += c.total
      totals.passed += c.passed
      totals.failed += c.failed
    } else {
      layers[l.key] = { status: 'not run', suite: l.suite, note: l.note }
    }
    cases.push({
      name: l.key,
      status: c ? (c.failed > 0 ? 'failed' : 'passed') : 'not run',
      realm: 'pure',
      player: null,
      durationMs: null,
      message: c ? `${c.passed} passed, ${c.failed} failed` : 'suite did not report',
      detail: null,
      values: { suite: l.suite, note: l.note },
    })
  }

  if (live && !live.error && live.data) {
    const d = live.data
    for (const realm of ['server', 'client']) {
      const rows = normaliseLive(d[realm], realm)
      const st = { passed: 0, failed: 0, skipped: 0, total: rows.length }
      for (const r of rows) {
        st[r.status] = (st[r.status] || 0) + 1
        totals.total += 1
        totals[r.status] = (totals[r.status] || 0) + 1
        cases.push(r)
      }
      layers[realm] = { status: 'ran', ...st, report: live.file }
    }
    layers.meta = d.meta || null
    layers.liveSummary = d.summary || null
  } else {
    for (const realm of ['server', 'client']) {
      const note =
        live && live.error
          ? `report unreadable: ${live.error}`
          : 'no cis_libstest report found; run /cistest on a server'
      layers[realm] = { status: 'not run', note }
      cases.push({
        name: `${realm} integration suite`,
        status: 'not run',
        realm,
        player: null,
        durationMs: null,
        message: note,
        detail: null,
        values: {},
      })
    }
  }

  const matrix = {
    generatedAt: new Date().toISOString(),
    generator: 'tools/test-matrix.js',
    purpose:
      'Every test case across every layer in one file. A "not run" layer is recorded explicitly so this file never implies coverage that does not exist.',
    summary: totals,
    layers,
    coverage: {
      note: 'What is NOT covered. Integration coverage needs a running fxserver and a player in-game, so it is manual by construction.',
      gaps: [
        'No CI runs the live layers. cis_libstest needs a server and a connected player.',
        'The mutating tier is off by default, so doors, entity sync, inventory writes and database queries are unexercised.',
        'Multi-player behaviour -- per-player rate-limit isolation, callback key binding -- is untested; the suite runs one client.',
        'The module-restart race is untested by design. It is defect 6 in the brief and remains unsolved.',
        'Only one framework and one inventory provider have been exercised.',
        'Resource-stop and resource-restart behaviour is untested.',
      ],
    },
    caseCount: cases.length,
    cases,
  }

  fs.writeFileSync(OUT, JSON.stringify(matrix, null, 2))
  const s = matrix.summary
  console.log(`TEST_MATRIX.json written: ${cases.length} cases`)
  console.log(`  ${s.passed} passed, ${s.failed} failed, ${s.skipped} skipped, ${s.total} total`)
  for (const [k, v] of Object.entries(layers)) {
    if (v && v.status === 'ran') {
      console.log(`  ${k.padEnd(10)} ran      ${v.passed}/${v.total} passed`)
    } else if (v && v.status === 'not run') {
      console.log(`  ${k.padEnd(10)} NOT RUN`)
    }
  }
}

main()
