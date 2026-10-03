// The agent's console. W2.
//
//   node tools/fx.js "restart cis_test_b"
//   node tools/fx.js "cis_test run all"
//   node tools/fx.js --log 200
//
// Writes a command file into the deployed cis_ctl folder and waits for the
// answer. This replaces typing into txAdmin's web console, which the PC session
// established is not a thing worth automating: Playwright's click() on the
// prompt input times out, fill() alone does not submit, and only a coordinate
// click on the visible prompt line followed by Enter works at all. A step that
// only works at one window size is not a step.
//
// WHY A FILE AND NOT A PIPE OR A SOCKET. A resource cannot open a listening
// socket from inside its sandbox, and a named pipe or a local TCP listener would
// be a second network-shaped surface on a box that is on the internet. A file in
// the resource's own folder needs nothing listening, is created by a resource
// that depends on nothing, and is inspectable after the fact.
//
// WHY AN ID. inbox.json holds one command, and the agent may be replaced by
// another session at any time. Without an id, "the inbox changed" is ambiguous:
// a command that is merely still there looks like a new one, and would run
// twice. Every command therefore carries a unique id, cis_ctl runs each id
// exactly once, and fx.js waits for an outbox entry carrying ITS id rather than
// any change at all. A stale answer from a previous run can never be mistaken
// for this one's.
//
// EXIT CODES. 0 the command was accepted and its expected state was reached;
// 1 the command was REFUSED by the allow-list, or ran but did not reach the
// state it was supposed to; 2 the command was never answered -- the timeout,
// and the case where cis_ctl is not deployed or not started. The split between
// 1 and 2 is the difference between "this is not a command you may run" and
// "the bridge is not up", which are different problems with different fixes.

const fs = require('fs')
const path = require('path')

const root = path.join(__dirname, '..')
const ENV = path.join(root, '.live-env.json')

// cis_ctl waits up to 15 s for a resource to reach its expected state, so a
// command cannot be answered sooner than that. The default here is comfortably
// longer, because a timeout that fires while the server is merely slow produces
// a report nobody can act on.
const DEFAULT_TIMEOUT_MS = 40000
const POLL_MS = 250
// A Windows rename fails while another process holds the destination open.
// cis_ctl opens inbox.json for microseconds at a time, so this is a rare race,
// but it is a real one and retrying costs nothing.
const RENAME_ATTEMPTS = 40

function die(code, msg) {
  console.error('fx: ' + msg)
  process.exit(code)
}

function loadEnv() {
  if (!fs.existsSync(ENV)) {
    die(2, '.live-env.json is missing. W1 writes it; it holds no secrets.')
  }
  try {
    return JSON.parse(fs.readFileSync(ENV, 'utf8'))
  } catch (e) {
    die(2, '.live-env.json is not valid JSON: ' + e.message)
  }
}

function ctlDir(env) {
  if (!env.resourcesDir) die(2, '.live-env.json has no resourcesDir')
  return path.join(env.resourcesDir, 'cis_ctl')
}

// A unique id, sortable by creation and unguessable enough that two sessions
// cannot collide on the same one.
function makeId() {
  return 'c' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8)
}

// ------------------------------------------------------------- atomic write
//
// Write to a sibling temp name and rename over the target. A reader on the other
// side then sees either the old file or the new one, never half of each -- and
// "half of each" is not a cosmetic problem here, because half an inbox parses as
// an inbox with a truncated cmd and would be REFUSED, which looks like a
// permissions problem rather than a race.
function writeInboxAtomic(dir, id, cmd) {
  const target = path.join(dir, 'inbox.json')
  const tmp = path.join(dir, `inbox.json.tmp-${id}`)
  fs.writeFileSync(tmp, JSON.stringify({ id, cmd }) + '\n', 'utf8')
  for (let attempt = 1; ; attempt++) {
    try {
      fs.renameSync(tmp, target)
      return
    } catch (e) {
      if (attempt >= RENAME_ATTEMPTS) {
        try { fs.unlinkSync(tmp) } catch { /* already gone */ }
        die(2, `could not publish inbox.json after ${attempt} attempts: ${e.message}`)
      }
      sleepSync(25)
    }
  }
}

// Atomics without a dependency. Blocking on purpose: this is the publisher's
// own retry loop and there is nothing else in the process to run meanwhile.
function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)
}

// --------------------------------------------------------------- the reply
//
// Reading outbox.json can catch cis_ctl mid-write if the rename fallback fired,
// so a parse failure is a "not yet", never an error: it is retried until the
// deadline. Treating it as an error would report a refusal the allow-list never
// made.
function readOutbox(dir) {
  const p = path.join(dir, 'outbox.json')
  let text
  try {
    text = fs.readFileSync(p, 'utf8')
  } catch {
    return null
  }
  try {
    return JSON.parse(text)
  } catch {
    return null
  }
}

function runCommand(dir, cmd, timeoutMs) {
  if (!fs.existsSync(dir)) {
    die(2, `cis_ctl is not deployed at ${dir}. Run: npm run live:deploy`)
  }
  const id = makeId()
  writeInboxAtomic(dir, id, cmd)

  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const out = readOutbox(dir)
    if (out && out.id === id) return out
    sleepSync(POLL_MS)
  }
  return null
}

// ------------------------------------------------------------------- --log
//
// The server log is the only record of what the server actually said, and it is
// the one place player names, identifiers and the server's public IP appear.
//
// Two redactions, both non-negotiable under the project's own rule that none of
// those may reach a file, a commit or a report -- and a log tail is exactly the
// kind of thing that gets pasted into one. Everything else prints untouched:
// redacting the diagnostics would defeat the purpose of reading the log at all.
function redact(line) {
  return line
    .replace(/\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/g, '<ip>')
    .replace(/fivem:\d+/gi, '<identifier>')
    .replace(/\b\d{16,20}\b/g, '<license-or-id>')
}

function printLog(env, n) {
  if (!env.serverLogPath) die(2, '.live-env.json has no serverLogPath')
  if (!fs.existsSync(env.serverLogPath)) {
    die(2, `server log not found: ${env.serverLogPath}`)
  }
  const lines = fs.readFileSync(env.serverLogPath, 'utf8').split(/\r?\n/)
  // A trailing newline produces one empty element; drop it so `tail` does not
  // print a blank line that looks like a truncated final entry.
  if (lines.length && lines[lines.length - 1] === '') lines.pop()
  for (const line of lines.slice(-n)) console.log(redact(line))
}

// -------------------------------------------------------------------- main

function main(argv) {
  const args = argv.slice(2)

  if (args.includes('--log')) {
    const i = args.indexOf('--log')
    const n = Number(args[i + 1])
    const env = loadEnv()
    printLog(env, Number.isFinite(n) && n > 0 ? n : 200)
    return
  }

  let timeoutMs = DEFAULT_TIMEOUT_MS
  const t = args.indexOf('--timeout')
  if (t !== -1) {
    const v = Number(args[t + 1])
    if (Number.isFinite(v) && v > 0) timeoutMs = v
    args.splice(t, 2)
  }

  const cmd = args.join(' ').trim()
  if (!cmd) {
    die(2, 'usage: node tools/fx.js "<command>"   |   node tools/fx.js --log <lines>')
  }

  const env = loadEnv()
  const dir = ctlDir(env)
  const out = runCommand(dir, cmd, timeoutMs)

  if (!out) {
    die(2,
      `no answer for ${JSON.stringify(cmd)} in ${timeoutMs} ms.\n` +
      '  cis_ctl is not deployed, not started, or its ACE lines are missing from\n' +
      '  server.cfg. Check: node tools/fx.js --log 60   (look for [cis_ctl])')
  }

  if (out.ok === true) {
    console.log(`OK   ${cmd}`)
    if (out.state) console.log(`     state: ${out.state}`)
    return
  }

  // ok:false with an error is a REFUSAL -- the allow-list said no, or the
  // command ran and the resource never reached the state it was asked for.
  // Both are the command's fault to fix; neither is the bridge being down.
  const why = out.error || 'refused, with no reason given'
  die(1, `${cmd}\n  ${why}` +
    (out.state ? `\n  (resource state when it gave up: ${out.state})` : ''))
}

main(process.argv)