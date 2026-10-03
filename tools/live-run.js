// One command per live run. W4.
//
//   npm run live:run -- all
//   npm run live:run -- server
//   npm run live:run -- player
//
// Everything the agent needs to do to the live server, in the order that has to
// happen, with nothing left for a human to type. Before this, a run was twenty
// minutes of manual console entries interleaved with reading the log, and the
// handoff records what that produced: a deploy that "succeeded" while old code
// kept running, discovered a cycle later.
//
// THE COMMIT CHECK IS THE POINT OF THIS FILE. After deploying, it reads
// status.json and refuses to run a single case unless the running harness
// reports the commit that was just deployed. Everything else here is
// convenience; that one comparison is the difference between a live test that
// tests the current code and one that confidently reports on yesterday's.
//
// WHAT IT DOES, IN ORDER.
//   1. deploy                                    (tools/live-deploy.js, local mode)
//   2. stop / refresh / ensure, through fx.js   (cis_ctl; no console, no browser)
//   3. status.json must report the deployed commit
//   4. start the client, if any suite in the selection needs a player
//   5. wait up to 5 minutes for status.json to show a player -- otherwise that
//      TIER is SKIP with "client did not connect", and the reason is printed
//   6. send `cis_test run <tier>`
//   7. poll results_latest.json for a run id that is NOT the previous one
//   8. copy the results into test/live/results/
//   9. stop the client, print the summary
//
// EXIT 0 only when no case FAILed. SKIP does not fail the run and is not a
// pass: it is printed, counted and explained, because a tier that quietly did
// nothing is how a green run becomes a false claim.

const fs = require('fs')
const path = require('path')
const { spawnSync } = require('child_process')

const root = path.join(__dirname, '..')
const ENV = path.join(root, '.live-env.json')
const RESULTS_KEEP = path.join(root, 'test', 'live', 'results')

// The console sequence, in the only order that works. Stop everything first so
// nothing is mid-run when the library's files change underneath it; `refresh`
// between the stops and the starts because FiveM caches fxmanifest and a
// resource whose manifest changed is invisible to `ensure` until the cache is
// dropped -- `restart` alone does not drop it, which is how a harness ends up
// testing yesterday's build.
//
// cis_ctl is deliberately absent from both lists. It is the thing executing
// this sequence, and stopping it would stop the run halfway.
const SEQUENCE = [
  'stop cis_test',
  'stop cis_test_b',
  'stop cis_test_providers',
  'stop cis_libs',
  'refresh',
  'ensure cis_libs',
  'ensure cis_test_providers',
  'ensure cis_test_b',
  'ensure cis_test',
]

const PLAYER_WAIT_MS = 5 * 60 * 1000
const RESULTS_TIMEOUT_MS = 30 * 60 * 1000
const POLL_MS = 500

function loadEnv() {
  if (!fs.existsSync(ENV)) {
    console.error('live:run: .live-env.json is missing. W1 writes it; it holds no secrets.')
    process.exit(2)
  }
  try {
    return JSON.parse(fs.readFileSync(ENV, 'utf8'))
  } catch (e) {
    console.error('live:run: .live-env.json is not valid JSON: ' + e.message)
    process.exit(2)
  }
}

function log(msg) {
  console.log(msg)
}

function fail(msg, code) {
  console.error('live:run: ' + msg)
  process.exit(code || 1)
}

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)
}

// --------------------------------------------------------------------- steps

function deploy() {
  const r = spawnSync(process.execPath, [path.join(__dirname, 'live-deploy.js')], {
    cwd: root, encoding: 'utf8',
  })
  process.stdout.write(r.stdout || '')
  if (r.stderr) process.stderr.write(r.stderr)
  if (r.status !== 0) fail('the deploy step failed (exit ' + r.status + '). Nothing was run.')
}

function fx(cmd) {
  const r = spawnSync(process.execPath, [path.join(__dirname, 'fx.js'), cmd], {
    cwd: root, encoding: 'utf8',
  })
  const out = `${r.stdout || ''}${r.stderr || ''}`.trim()
  return { ok: r.status === 0, code: r.status, out }
}

function sendSequence() {
  for (const cmd of SEQUENCE) {
    const r = fx(cmd)
    if (!r.ok) {
      fail(`the server refused "${cmd}".\n${indent(r.out)}\n` +
        '  cis_ctl is probably not started, or its ACE lines are missing from server.cfg.\n' +
        '  Nothing was run.')
    }
    log(`  ${cmd}`)
  }
}

// cis_test's own folder on the server, where status.json and the results live.
function cisTestDir(env) {
  return path.join(env.resourcesDir, 'cis_test')
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch {
    return null
  }
}

function indent(s, pad) {
  return String(s || '').split('\n').map(l => (pad || '    ') + l).join('\n')
}

// --------------------------------------------------------- the commit check

function deployedCommit(env) {
  const d = readJson(path.join(cisTestDir(env), 'deploy.json'))
  return d ? { commit: d.commit, branch: d.branch, dirty: !!d.dirty, timestamp: d.timestamp } : null
}

function readStatus(env) {
  return readJson(path.join(cisTestDir(env), 'status.json'))
}

// Waits for status.json to exist at all. cis_test writes it at start, so a
// missing file means the resource is not up -- which is a different problem from
// a stale one, and worth telling apart.
function waitForStatus(env, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const s = readStatus(env)
    if (s) return s
    sleep(POLL_MS)
  }
  return null
}

function checkCommit(env, want) {
  const status = waitForStatus(env, 60000)
  if (!status) {
    fail('status.json never appeared. cis_test did not start.\n' +
      '  Check: node tools/fx.js --log 60')
  }
  if (!want) {
    fail('deploy.json is missing from the deployed cis_test folder, so there is no\n' +
      '  commit to check against. Re-run: npm run live:deploy')
  }
  if (status.commit !== want.commit) {
    fail(`the running harness is NOT the code just deployed.\n` +
      `    deployed: ${want.commit}${want.dirty ? ' (working tree was dirty)' : ''}\n` +
      `    running:  ${status.commit}\n` +
      '  Nothing was run. A green result from a mismatched build is worse than no\n' +
      '  result, so this refuses rather than reporting.')
  }
  return status
}

// --------------------------------------------------------------- the player

// Whether the selection needs a player, read from the harness rather than from
// a list written here. If status.json predates this, the answer is unknown and
// is treated as "assume it needs one" -- starting a client that was not needed
// is cheap, SKIPping a tier that did need one is not.
function selectionNeedsPlayer(status, tierArg) {
  if (!status.suites || !status.suites.length) return { needed: true, known: false }
  const all = tierArg === 'all'
  for (const s of status.suites) {
    const inSelection = all || s.tier === tierArg || s.suite === tierArg
    if (inSelection && s.needsPlayer) return { needed: true, known: true }
  }
  return { needed: false, known: true }
}

function waitForPlayer(env, clientCfg, player) {
  if (player.mode === 'off') {
    return { connected: false, why: 'client.mode is "off" -- no client machine is configured on this VPS' }
  }
  const deadline = Date.now() + PLAYER_WAIT_MS
  let announced = false
  while (Date.now() < deadline) {
    const s = readStatus(env)
    if (s && s.playerConnected) return { connected: true }
    if (!announced) {
      announced = true
      log(`  waiting up to ${Math.round(PLAYER_WAIT_MS / 1000)}s for a client to connect to ${clientCfg.connect || '127.0.0.1:30120'}...`)
    }
    sleep(POLL_MS)
  }
  return { connected: false, why: 'client did not connect within 5 minutes' }
}

// ------------------------------------------------------------------- results

function currentRunId(env) {
  const r = readJson(path.join(cisTestDir(env), 'results_latest.json'))
  return r ? r.run : null
}

// Waits for a run id that is not the one already there. Matching on "the file
// changed" would accept the previous run's results if the new run died before
// writing -- which is precisely the failure that makes a run look successful.
function waitForRun(env, previousId, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const r = readJson(path.join(cisTestDir(env), 'results_latest.json'))
    if (r && r.run && r.run !== previousId) return r
    sleep(POLL_MS)
  }
  return null
}

function keepResults(results, runId) {
  try {
    fs.mkdirSync(RESULTS_KEEP, { recursive: true })
    fs.writeFileSync(path.join(RESULTS_KEEP, `${runId}.json`), JSON.stringify(results, null, 2) + '\n', 'utf8')
  } catch (e) {
    log(`  (could not copy results into test/live/results/: ${e.message})`)
    return false
  }
  return true
}

// ------------------------------------------------------------------ summary

function summarise(results) {
  const t = results.tally || {}
  const cases = results.cases || []
  const bad = cases.filter(c => String(c.status || '').toUpperCase() === 'FAIL'
    || String(c.status || '').toUpperCase() === 'ERROR')
  log('')
  log(`run ${results.run}  commit ${results.commit}  players ${results.players}`)
  log(`  pass ${t.pass || 0}  fail ${t.fail || 0}  skip ${t.skip || 0}` +
    `  manual ${t.manual || 0}  error ${t.error || 0}  (${t.ms || 0} ms)`)
  if (bad.length) {
    log('')
    log(`  ${bad.length} failing case(s):`)
    for (const c of bad) {
      log(`    [${c.status}] ${c.suite || '?'} :: ${c.case || '?'}`)
      if (c.msg) log(`        ${String(c.msg).split('\n').join('\n        ')}`)
    }
  }
  return bad
}

// --------------------------------------------------------------------- main

function main() {
  const tierArg = (process.argv[2] || 'all').trim()
  if (!tierArg) fail('usage: npm run live:run -- <tier|all>')

  const env = loadEnv()
  if ((env.mode || 'local') !== 'local') {
    fail(`.live-env.json mode is "${env.mode}"; live:run only drives a local server.`)
  }

  log(`live run: tier=${tierArg}`)

  log('')
  log('[1/7] deploy')
  deploy()

  log('')
  log('[2/7] stop / refresh / ensure through cis_ctl')
  sendSequence()

  log('')
  log('[3/7] check the running build is the one just deployed')
  const want = deployedCommit(env)
  const status = checkCommit(env, want)
  log(`  commit ${status.commit} confirmed; cis_libs ${status.cisLibsVersion}` +
    (want.dirty ? '  (working tree was dirty at deploy time)' : ''))

  const client = require('./client.js')
  const clientCfg = client.loadClientConfig()
  const player = selectionNeedsPlayer(status, tierArg)

  let startedClient = false
  if (player.needed) {
    log('')
    log('[4/7] start the client')
    const r = client.start(clientCfg)
    log(`  ${r.skipped ? 'SKIP' : r.ok ? 'OK' : 'FAIL'} ${r.detail || ''}`)
    startedClient = r.ok && !r.skipped
  } else {
    log('')
    log('[4/7] start the client -- not needed: no suite in this selection needs a player')
  }

  let skipped = null
  if (player.needed && startedClient) {
    log('')
    log('[5/7] wait for the client to connect')
    const p = waitForPlayer(env, clientCfg, player)
    if (!p.connected) {
      skipped = p.why
      log(`  SKIP: ${p.why}`)
    } else {
      log('  a client is connected')
    }
  } else if (player.needed) {
    skipped = 'the client could not be started'
    log('')
    log(`[5/7] SKIP: ${skipped}`)
  } else {
    log('')
    log('[5/7] no player needed')
  }

  let results = null
  if (skipped) {
    log('')
    log(`[6/7] SKIP: the ${tierArg} tier did not run (${skipped})`)
    log('[7/7] no results to read')
  } else {
    log('')
    log(`[6/7] cis_test run ${tierArg}`)
    const previous = currentRunId(env)
    const r = fx(`cis_test run ${tierArg}`)
    if (!r.ok) {
      fail(`the server refused "cis_test run ${tierArg}".\n${indent(r.out)}`)
    }
    log('  sent')

    log('')
    log('[7/7] wait for results')
    results = waitForRun(env, previous, RESULTS_TIMEOUT_MS)
    if (!results) {
      log(`  no new results after ${Math.round(RESULTS_TIMEOUT_MS / 60000)} minutes.`)
      log('  The run may still be going (the soak tier is 30 minutes by design), or')
      log('  it may have died. Check: node tools/fx.js --log 200')
      if (startedClient) client.stop(clientCfg)
      process.exit(1)
    }
    keepResults(results, results.run)
    log(`  run ${results.run} copied into test/live/results/`)
  }

  if (startedClient) {
    log('')
    const r = client.stop(clientCfg)
    log(`[stop] client ${r.ok ? 'stopped' : 'NOT stopped: ' + (r.detail || 'unknown')}`)
  }

  if (!results) {
    log('')
    log('no cases ran. That is a SKIP, not a pass.')
    process.exit(0)
  }

  const bad = summarise(results)
  if (bad.length) {
    log('')
    log(`FAILED: ${bad.length} failing case(s).`)
    process.exit(1)
  }
  log('')
  log('OK: no failing cases.')
  process.exit(0)
}

main()