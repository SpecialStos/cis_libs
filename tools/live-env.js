// Where the live harness finds the server. Shared by live-deploy, live-run,
// fx, client, console-bridge and ci-live.
//
// TWO SOURCES, ONE ANSWER.
//
//   .live-env.json   the VPS. Paths and ports, no secrets, not committed. Its
//                    location can be moved with CIS_LIVE_ENV=<file>.
//   CIS_LIVE_*       environment variables, one per field. Each one that is set
//                    and non-empty wins over the same field in the file.
//
// The file is how the Windows VPS has always worked and it keeps working
// unchanged: with no CIS_LIVE_* variable set, load() returns exactly what the
// file says. The variables are how CI (and any Linux box) describes a server
// without writing a file into the checkout: the CI job builds a throwaway server
// data folder under the runner's temp directory and points the tools at it.
//
// It never reads or returns a secret. The licence key reaches FXServer through
// its own config file, written by ci-live.js, and is not a field here.

const fs = require('fs')
const path = require('path')

const root = path.join(__dirname, '..')
const DEFAULT_FILE = path.join(root, '.live-env.json')

// field -> environment variable. Only the fields the tools actually read.
const OVERRIDES = {
  mode: 'CIS_LIVE_MODE',
  resourcesDir: 'CIS_LIVE_RESOURCES_DIR',
  libDir: 'CIS_LIVE_LIB_DIR',
  serverLogPath: 'CIS_LIVE_SERVER_LOG',
  serverCfgPath: 'CIS_LIVE_SERVER_CFG',
  artifactsDir: 'CIS_LIVE_ARTIFACTS_DIR',
  // mode "cisfivem" (tools/live-remote.js)
  host: 'CIS_LIVE_HOST',
  server: 'CIS_LIVE_SERVER',
  lockOwner: 'CIS_LIVE_LOCK_OWNER',
  playerWaitMinutes: 'CIS_LIVE_PLAYER_WAIT_MINUTES',
}

function envFile(environ) {
  const e = environ || process.env
  return e.CIS_LIVE_ENV && e.CIS_LIVE_ENV.trim() ? path.resolve(e.CIS_LIVE_ENV.trim()) : DEFAULT_FILE
}

// Returns { env, file, fromFile, overridden, error }.
//
// `env` is null only when there is neither a file nor a single override: the
// caller decides whether that is fatal. A file that exists and does not parse is
// an ERROR, never silently ignored -- a typo in the VPS file must not turn into
// "use the defaults" and deploy somewhere else.
function load(options) {
  const opts = options || {}
  const environ = opts.environ || process.env
  const file = opts.file || envFile(environ)
  let base = null
  let error = null
  if (fs.existsSync(file)) {
    try {
      base = JSON.parse(fs.readFileSync(file, 'utf8'))
    } catch (e) {
      error = `${path.basename(file)} is not valid JSON: ${e.message}`
    }
  }
  const overridden = []
  const env = Object.assign({}, base || {})
  for (const [field, name] of Object.entries(OVERRIDES)) {
    const v = environ[name]
    if (typeof v === 'string' && v.trim() !== '') {
      env[field] = v.trim()
      overridden.push(name)
    }
  }
  const any = base !== null || overridden.length > 0
  return { env: any ? env : null, file, fromFile: base !== null, overridden, error }
}

// For the tools that cannot do anything without a server description. Prints one
// line that names BOTH ways of supplying one, then exits with `code`.
function loadOrDie(tool, code) {
  const r = load()
  if (r.error) {
    console.error(`${tool}: ${r.error}`)
    process.exit(code || 2)
  }
  if (!r.env) {
    console.error(`${tool}: no server described. Either write .live-env.json (W1; it holds no ` +
      'secrets) or set CIS_LIVE_RESOURCES_DIR (and friends, see tools/live-env.js).')
    process.exit(code || 2)
  }
  return r.env
}

// How to start FXServer from an artifacts folder, per platform.
//
// Windows ships FXServer.exe. Linux ships run.sh, which execs a bundled musl
// loader with the artifact's own library path; this builds the same command
// line run.sh would, as an argv ARRAY, because run.sh passes its arguments on
// as an unquoted $* and any argument with a space in it would be split.
function fxserverCommand(artifactsDir, platform) {
  const plat = platform || process.platform
  if (plat === 'win32') {
    return { cmd: path.join(artifactsDir, 'FXServer.exe'), args: [] }
  }
  const alpine = path.join(artifactsDir, 'alpine')
  const srv = path.join(alpine, 'opt', 'cfx-server')
  const libPath = [
    path.join(alpine, 'usr', 'lib', 'v8') + '/',
    path.join(alpine, 'lib') + '/',
    path.join(alpine, 'usr', 'lib') + '/',
  ].join(':')
  return {
    cmd: path.join(srv, 'ld-musl-x86_64.so.1'),
    args: ['--library-path', libPath, '--', path.join(srv, 'FXServer'),
      '+set', 'citizen_dir', path.join(srv, 'citizen') + '/'],
  }
}

module.exports = { load, loadOrDie, envFile, fxserverCommand, OVERRIDES }
