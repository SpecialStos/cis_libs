// The parts of tools/ci-live.js that decide something, kept free of processes
// and files so test/ci/ci-live.test.js can pin every decision down.
//
//   buildServerCfg    the server.cfg the CI server runs
//   scanConsole       boot and run errors in the console log
//   licenceProblem    the one boot failure that has its own message
//   harnessRefusal    cis_test saying it will not run, so CI need not wait
//   judgeReport       a results file -> pass / fail, and why
//   redact            the licence key never reaches a log file or an artefact
//
// Nothing here knows about Windows, the VPS or .live-env.json.

// ------------------------------------------------------------------ console

// FXServer colours its own output with ANSI escapes, and resources colour
// theirs with FiveM's ^0-^9 codes. Both are stripped before any pattern runs, or
// a pattern that should match "SCRIPT ERROR" misses "^1SCRIPT ERROR".
function stripAnsi(text) {
  return String(text)
    // eslint-disable-next-line no-control-regex
    .replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, '')
    .replace(/\^[0-9]/g, '')
}

// What the job treats as a broken boot. Each entry is one thing an operator
// would otherwise only see by reading the whole log.
const ERROR_PATTERNS = [
  { kind: 'script-error', re: /SCRIPT ERROR/ },
  { kind: 'load-error', re: /Error loading script/i },
  { kind: 'parse-error', re: /Error parsing script/i },
  { kind: 'could-not-find', re: /could not find/i },
  { kind: 'start-failed', re: /(Couldn't|Could not|Failed to) start resource/i },
  { kind: 'svadhesive', re: /\[\s*svadhesive\s*\]\s*Error:/i },
]

// The resource a console line is about. FiveM prefixes a resource's own output
// with a padded channel, `[ script:cis_libs]` or `[resources:cis_libs]`; an
// error about a resource it could not load names it in the text instead.
function resourceOf(line) {
  const channel = line.match(/\[\s*(?:script|resources|c-scripting-core|citizen-scripting-lua):([A-Za-z0-9_\-[\]]+)\s*\]/)
  if (channel) return channel[1]
  const inResource = line.match(/in resource ['"]?([A-Za-z0-9_-]+)/i)
  if (inResource) return inResource[1]
  const start = line.match(/start resource ['"]?([A-Za-z0-9_-]+)/i)
  if (start) return start[1]
  const at = line.match(/@([A-Za-z0-9_-]+)\//)
  if (at) return at[1]
  return null
}

// Every error line in `text`, in order.
//
// `ignoreResources` names fixtures that are broken ON PURPOSE (cis_test_badmeta
// is started by a lifecycle case to be refused); an error attributed to one of
// them is returned with `ignored: true` so the summary can still show it.
// `allowPatterns` (regexes) does the same for a line, whatever its resource.
function scanConsole(text, options) {
  const opts = options || {}
  const ignore = new Set(opts.ignoreResources || [])
  const allow = opts.allowPatterns || []
  const out = []
  const lines = stripAnsi(text).split(/\r?\n/)
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    for (const p of ERROR_PATTERNS) {
      if (!p.re.test(line)) continue
      const resource = resourceOf(line)
      out.push({
        lineNo: (opts.lineOffset || 0) + i + 1,
        kind: p.kind,
        resource,
        ignored: (resource !== null && ignore.has(resource)) || allow.some(re => re.test(line)),
        line: line.trim(),
      })
      break
    }
  }
  return out
}

// The licence failure, as one sentence for the job summary, or null.
//
// It gets its own check because it is the most likely boot failure in CI (a
// missing, revoked or mistyped secret) and because after it the server does
// not exit: it sits there, deaf to its console, until it is killed. Waiting out
// the boot timeout on it would cost minutes and say nothing.
const LICENCE_PATTERNS = [
  /does not have a license key specified/i,
  /license key authentication failed/i,
  /invalid license key/i,
  /license key.*(is not valid|was rejected|has been revoked)/i,
  /sv_licenseKey.*(invalid|rejected)/i,
]

function licenceProblem(text) {
  for (const line of stripAnsi(text).split(/\r?\n/)) {
    // FXServer prints the sentence bare and then again behind its svadhesive
    // channel, on the same line. One copy is enough for a summary.
    for (const piece of line.split(/\[\s*svadhesive\s*\]\s*(?:Error:\s*)?/i)) {
      if (LICENCE_PATTERNS.some(re => re.test(piece))) return piece.trim()
    }
  }
  return null
}

// cis_test lines that mean "this run will not produce a results file". Seen,
// they end the wait at once instead of after the per-tier timeout.
const REFUSALS = [
  /\[cis_test\] PREFLIGHT REFUSED:.*/,
  /\[cis_test\] .* selected 0 suites; nothing will run/,
  /\[cis_test\] no suite or tier matches:.*/,
  /\[cis_test\] nothing to run/,
  /\[cis_test\] a run is already in progress.*/,
  /\[cis_test\] refused: that command is console-only.*/,
  /\[cis_test\] unknown command .*/,
]

function harnessRefusal(text) {
  for (const line of stripAnsi(text).split(/\r?\n/)) {
    for (const re of REFUSALS) {
      const m = line.match(re)
      if (m) return m[0].trim()
    }
  }
  return null
}

// ------------------------------------------------------------------- report

const STATUSES = ['PASS', 'FAIL', 'SKIP', 'MANUAL', 'ERROR']

// One results file (results_latest.json, written by report.lua) -> a verdict.
//
// THE RULES, strictest reading wins:
//   * not JSON, no run id, or no cases array        -> fail (not a report)
//   * zero cases                                    -> fail (a vacuous run)
//   * any case FAIL or ERROR, or a status not in
//     the five the harness defines                  -> fail
//   * tally.fail or tally.error above zero          -> fail, even if the cases
//                                                      somehow disagree
//   * SKIP and MANUAL                               -> listed, never a pass and
//                                                      never a failure
function judgeReport(input) {
  let report = input
  if (typeof input === 'string') {
    try {
      report = JSON.parse(input)
    } catch (e) {
      return { ok: false, problems: ['the results file is not JSON: ' + e.message], failing: [], skipped: [], counts: {} }
    }
  }
  const problems = []
  if (!report || typeof report !== 'object') {
    return { ok: false, problems: ['the results file is not an object'], failing: [], skipped: [], counts: {} }
  }
  if (typeof report.run !== 'string' || report.run === '') problems.push('the results file has no run id')
  const cases = Array.isArray(report.cases) ? report.cases : null
  // report.lua encodes an empty Lua table as {} rather than [], so an empty
  // object is the same "no cases" as an empty array.
  const emptyObject = report.cases && typeof report.cases === 'object' && !Array.isArray(report.cases) &&
    Object.keys(report.cases).length === 0
  if (!cases && !emptyObject) problems.push('the results file has no cases array')

  const counts = { pass: 0, fail: 0, skip: 0, manual: 0, error: 0 }
  const failing = []
  const skipped = []
  for (const c of cases || []) {
    const status = String((c && c.status) || '').toUpperCase()
    if (!STATUSES.includes(status)) {
      failing.push({ ...c, status: status || '<none>', why: 'unknown status' })
      problems.push(`case ${c && c.suite}::${c && c.case} has status "${status || '<none>'}"`)
      continue
    }
    counts[status.toLowerCase()]++
    if (status === 'FAIL' || status === 'ERROR') failing.push(c)
    if (status === 'SKIP' || status === 'MANUAL') skipped.push(c)
  }
  if ((cases && cases.length === 0) || emptyObject) {
    problems.push('the run recorded zero cases, which proves nothing')
  } else if (counts.pass === 0) {
    // Every case SKIP or MANUAL is a run that exercised nothing either.
    problems.push('no case passed: every case was skipped or manual, which proves nothing')
  }
  const t = report.tally || {}
  if ((Number(t.fail) || 0) > 0 && counts.fail === 0) problems.push(`tally says fail ${t.fail} but no case is FAIL`)
  if ((Number(t.error) || 0) > 0 && counts.error === 0) problems.push(`tally says error ${t.error} but no case is ERROR`)

  return {
    ok: problems.length === 0 && failing.length === 0,
    run: report.run,
    commit: report.commit,
    counts,
    failing,
    skipped,
    problems,
  }
}

// -------------------------------------------------------------- server.cfg

// The ACEs the harness needs, exactly the cis_test block from
// test/live/RUNBOOK.md. ACEs do not survive a restart, so they live in the cfg.
const HARNESS_ACES = [
  'command.ensure', 'command.stop', 'command.start', 'command.restart',
  'command.refresh', 'command.cis_force_unregister', 'command.cis_audit',
]

// The order matters: cis_libs first (everything depends on it), the providers
// before any consumer (they supply the config and hold every slot), cis_test
// last (its status.json lists the suites the others registered nothing for, and
// its preflight wants the fakes in place). cis_test_badmeta is deployed but NOT
// ensured: a lifecycle case starts it, and only that case.
const ENSURE_ORDER = ['cis_libs', 'cis_test_providers', 'cis_test_b', 'cis_test_c', 'cis_test']

function quote(v) {
  return '"' + String(v).replace(/["\\\r\n]/g, '') + '"'
}

function buildServerCfg(options) {
  const o = options || {}
  const port = Number(o.port) || 30120
  const host = o.host || '127.0.0.1'
  const lines = [
    '# Generated by tools/ci-live.js for one CI run. Not an operator config.',
    '# Loopback only, never listed, two slots, OneSync on.',
    `endpoint_add_tcp ${quote(host + ':' + port)}`,
    `endpoint_add_udp ${quote(host + ':' + port)}`,
    `sv_hostname ${quote(o.hostname || 'cis_libs CI')}`,
    '# Not on the public server list. A CI server is nobody\'s to join.',
    'sv_master1 ""',
    'sv_endpointprivacy true',
    `sv_maxclients ${Number(o.maxClients) || 2}`,
    'set onesync on',
  ]
  if (o.gameBuild) lines.push(`set sv_enforceGameBuild ${Number(o.gameBuild)}`)
  lines.push(
    '',
    '# The harness configuration, pinned by convar so a start-order race cannot',
    '# change it: only the fakes may supply config, and the allow-list is the one',
    '# cis_test_providers/server/config.lua supplies. cis_test_b stays OFF it on',
    '# purpose -- the security cases need something to refuse.',
    `set cis_config_supplier ${quote('cis_test_providers')}`,
    `set cis_authorized_resources ${quote((o.authorized || ['cis_test', 'cis_test_providers', 'cis_test_c']).join(','))}`,
    'set cis_check_version false',
  )
  for (const [k, v] of Object.entries(o.convars || {})) lines.push(`set ${k} ${quote(v)}`)
  lines.push('', '# test/live/RUNBOOK.md, "The ACE lines": the cis_test block.')
  for (const ace of HARNESS_ACES) lines.push(`add_ace resource.cis_test ${ace} allow`)
  if (o.secretsFile) {
    lines.push('', '# The licence key, from FIVEM_LICENSE_KEY, in a file of its own that is',
      '# never uploaded or printed.', `exec ${quote(o.secretsFile)}`)
  }
  lines.push('')
  for (const r of o.ensure || ENSURE_ORDER) lines.push(`ensure ${r}`)
  lines.push('')
  return lines.join('\n')
}

function buildSecretsCfg(key) {
  if (typeof key !== 'string' || !/^[A-Za-z0-9_-]+$/.test(key.trim())) {
    throw new Error('FIVEM_LICENSE_KEY is empty or has characters a licence key does not')
  }
  return `sv_licenseKey "${key.trim()}"\n`
}

// The key, wherever it appears. GitHub masks secrets in the job log but not in
// an uploaded artefact, and the console log is uploaded.
function redact(text, secret) {
  let out = String(text)
  if (secret && secret.trim().length >= 6) out = out.split(secret.trim()).join('***')
  // And anything shaped like a key after sv_licenseKey: long, with a digit in
  // it, so the server's own "set the sv_licenseKey console variable" survives.
  return out.replace(/(sv_licenseKey\s+"?)(?=[A-Za-z0-9_-]*\d)[A-Za-z0-9_-]{16,}/gi, '$1***')
}

module.exports = {
  stripAnsi,
  scanConsole,
  resourceOf,
  licenceProblem,
  harnessRefusal,
  judgeReport,
  buildServerCfg,
  buildSecretsCfg,
  redact,
  ENSURE_ORDER,
  HARNESS_ACES,
}
