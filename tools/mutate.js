// Stage 1.4: the mutation gate.
//
// A test suite that has only ever been seen to pass has not been tested. This
// takes each known defect from test/mutations.json, applies it to a throwaway
// copy of the repository, runs the full suite, and requires the suite to FAIL.
// A mutation that still passes is a SURVIVOR: it means the check that was
// supposed to catch that defect does not.
//
// It also catches the opposite failure. A mutation whose `find` text no longer
// matches exactly once is STALE, and STALE fails the build too -- a row that
// silently stopped matching is a row that has stopped describing the code, and
// a gate made of those rows reports success while testing nothing.
//
// COST. Each mutation copies the tree and runs the whole suite. That is
// deliberate: the point is to prove the shipped gate catches the defect, not
// that some individual assertion does.

const fs = require('fs')
const os = require('os')
const path = require('path')
const { spawnSync } = require('child_process')

const root = path.join(__dirname, '..')
const spec = JSON.parse(fs.readFileSync(path.join(root, 'test', 'mutations.json'), 'utf8'))
const only = process.argv.slice(2).filter(a => !a.startsWith('-'))
const skipNodeModules = process.argv.includes('--no-copy-modules')

// Copy the working tree, minus .git and node_modules. node_modules is restored
// as a junction-free directory copy only when fengari is not resolvable, which
// on a normal machine it is not -- so copy it.
function copyTree(from, to, skip) {
  fs.mkdirSync(to, { recursive: true })
  for (const entry of fs.readdirSync(from, { withFileTypes: true })) {
    if (skip.includes(entry.name)) continue
    const src = path.join(from, entry.name)
    const dst = path.join(to, entry.name)
    if (entry.isDirectory()) copyTree(src, dst, skip)
    else if (entry.isSymbolicLink()) { try { fs.symlinkSync(fs.readlinkSync(src), dst) } catch { /* ignore */ } }
    else fs.copyFileSync(src, dst)
  }
}

function runSuite(dir) {
  // The full gate, not one file: a mutation that only the contracts suite would
  // catch still has to fail the build, and running the whole thing proves the
  // suites are wired together rather than accidentally independent.
  const r = spawnSync(process.execPath, ['test/run.js'], {
    cwd: dir,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
  })
  return {
    code: r.status,
    out: `${r.stdout || ''}${r.stderr || ''}`,
  }
}

function main() {
  const rows = spec.mutations.filter(m => !only.length || only.includes(m.id))
  if (!rows.length) {
    console.error(`no mutations matched ${JSON.stringify(only)}`)
    process.exit(2)
  }

  const results = []
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'cis-mutate-'))
  try {
    // ONE copy for the whole run. Each mutation touches exactly one file, so
    // the tree is restored between rows by rewriting that file -- copying
    // node_modules once instead of once per mutation turns a run from minutes
    // into seconds, and a gate that is slow gets skipped.
    copyTree(root, tmpRoot, skipNodeModules
      ? ['.git', 'node_modules', '.live-env.json']
      : ['.git', '.live-env.json'])

    for (const m of rows) {
      const target = path.join(tmpRoot, m.file)
      if (!fs.existsSync(target)) {
        results.push({ ...m, state: 'STALE', detail: `${m.file} does not exist` })
        continue
      }
      const original = fs.readFileSync(target, 'utf8')

      // Line-ending agnostic. A repository with `.gitattributes` is LF in the
      // index, but a working tree checked out before that file existed still
      // holds CRLF, and a mutation row that only matches on one platform is a
      // row that reports STALE on the other and hides the fact it was never
      // checked. The row is written with \n; it is matched against whatever
      // this file actually uses.
      const crlf = original.includes('\r\n')
      const want = s => (crlf ? s.replace(/\n/g, '\r\n') : s)
      const find = want(m.find)
      const replace = want(m.replace)

      const occurrences = original.split(find).length - 1
      if (occurrences !== 1) {
        results.push({ ...m, state: 'STALE', detail: `find matched ${occurrences} times, expected 1` })
        continue
      }
      fs.writeFileSync(target, original.replace(find, replace), 'utf8')

      let r
      let extra = null
      try {
        r = runSuite(tmpRoot)
        // A row may name a SECOND gate.
        //
        // Some rules are not exercised by the Lua suites at all. E070 -- a
        // client-only `Cis.*` function whose `return false, 'client only'` stub
        // is gone -- is a rule of tools/validate-api.js reading init.lua, and
        // M71 breaks exactly that. With only the suite in the loop, the rule
        // would be written, asserted by a fixture that could not exercise it,
        // and shipped on the strength of a claim nobody had run.
        //
        // Additive, not alternative: a row is killed when EITHER gate fails,
        // because the question is "does anything catch this", not "which gate
        // was written for it".
        if (m.check) {
          const c = spawnSync(process.execPath, ['tools/validate-api.js', '--api', 'api.lua', '--resource', '.'], {
            cwd: tmpRoot,
            encoding: 'utf8',
            maxBuffer: 64 * 1024 * 1024,
          })
          extra = { code: c.status, out: `${c.stdout || ''}${c.stderr || ''}` }
        }
      } finally {
        // Always put it back, even if the run threw, or the next mutation is
        // applied on top of this one and the results are meaningless.
        fs.writeFileSync(target, original, 'utf8')
      }

      const suiteKilled = r.code !== 0
      const extraKilled = extra !== null && extra.code !== 0
      if (!suiteKilled && !extraKilled) {
        results.push({ ...m, state: 'SURVIVOR', detail: m.check ? 'both the suite and the named check still passed' : 'the suite still passed' })
      } else {
        // Name the failing gate when the output says, so the row is diagnosable
        // without re-running it by hand. The validator's own E-code is more
        // useful than its first FAIL line, so it is preferred when it is the
        // gate that fired.
        const src = extraKilled && !suiteKilled ? extra : r
        const m2 = src.out.match(/\[(E\d+)\]/) || src.out.match(/FAIL\s+([^\s:]+:[^\s]+)/) || src.out.match(/FAIL\(([^)]+)\)/)
        results.push({ ...m, state: 'killed', detail: m2 ? m2[1].trim() : 'gate failed' })
      }
    }
  } finally {
    fs.rmSync(tmpRoot, { recursive: true, force: true })
  }

  const pad = (s, n) => String(s).padEnd(n)
  console.log('')
  console.log(pad('id', 6) + pad('state', 11) + pad('where', 34) + 'why')
  console.log('-'.repeat(120))
  for (const r of results) {
    console.log(pad(r.id, 6) + pad(r.state, 11) + pad(r.file + (r.state === 'STALE' ? ' (' + r.detail + ')' : ''), 34) +
      r.why.slice(0, 70))
  }
  const killed = results.filter(r => r.state === 'killed').length
  const survivors = results.filter(r => r.state === 'SURVIVOR')
  const stale = results.filter(r => r.state === 'STALE')
  console.log('-'.repeat(120))
  console.log(`${results.length} mutations: ${killed} killed, ${survivors.length} survivors, ${stale.length} stale`)
  if (survivors.length) {
    console.log('')
    console.log('SURVIVORS -- the suite passed with the defect still in place:')
    for (const r of survivors) console.log(`  ${r.id}  ${r.file}\n      ${r.why}`)
  }
  if (stale.length) {
    console.log('')
    console.log('STALE -- the pattern no longer matches the code exactly once:')
    for (const r of stale) console.log(`  ${r.id}  ${r.file}  ${r.detail}`)
  }
  process.exit(survivors.length || stale.length ? 1 : 0)
}

main()