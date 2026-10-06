// Stage 2.8: the deploy tool.
//
// Everything in this session so far has been deployed by hand. That is the
// state of affairs this file exists to end: a hand-copied tree has no record of
// what it contains, so "which build is on the server" is answered by the
// operator's memory, and the answer is wrong within a day.
//
// WHAT IT COPIES. Exactly the file set the manifest names -- every script, every
// `files` entry, the manifest itself, LICENSE.md and README.md -- and nothing
// else. Task 10.7's release packer calls the same function, so what is tested
// on the server is what ships in the archive.
//
// WHAT IT REFUSES TO DO.
//   * deploy when resourcesDir does not exist;
//   * delete a folder it did not create, judged by a marker file it writes;
//   * proceed while TWO cis_libs folders exist anywhere under resourcesDir,
//     because FiveM would load one of them at random and the other is not ours
//     to remove -- it stops, prints the paths, and waits;
//   * edit server.cfg, ever. Which resources are ensured is the owner's
//     decision, not the deployer's.
//
// The console sequence is PRINTED, not executed. Deploying a resource and
// starting it are separate decisions, and the second one needs the first one's
// `refresh` to have happened -- restart alone does not re-read fxmanifest.

const fs = require('fs')
const path = require('path')
const { spawnSync } = require('child_process')

const root = path.join(__dirname, '..')
const MARKER = '.cis_deploy'
const ENV = path.join(root, '.live-env.json')

const HARNESS = ['cis_test', 'cis_test_providers', 'cis_test_b', 'cis_test_c', 'cis_test_badmeta', 'cis_ctl']

function fail(msg, extra) {
  console.error('DEPLOY REFUSED: ' + msg)
  if (extra) console.error(extra)
  process.exit(1)
}

// ------------------------------------------------------------ the file set
//
// Computed from the manifest rather than hard-coded, because a hard-coded list
// is the thing that goes stale: a new shared script gets added to the manifest
// and the deploy silently ships the old build.
const { releaseFileSet } = require('./release-files')
function shippedFiles() {
  return releaseFileSet(root)
}

function copyInto(fromDir, toDir, relFiles) {
  fs.mkdirSync(toDir, { recursive: true })
  let n = 0
  for (const rel of relFiles) {
    const dst = path.join(toDir, rel)
    fs.mkdirSync(path.dirname(dst), { recursive: true })
    fs.copyFileSync(path.join(fromDir, rel), dst)
    n++
  }
  return n
}

// ------------------------------------------------------------------ safety
//
// Every cis_libs folder anywhere under the FIVEM RESOURCE ROOT.
//
// THE ROOT, NOT resourcesDir. `resourcesDir` is `[standalone]` -- where this tool
// deploys -- but FiveM resolves `ensure cis_libs` against the whole resources
// tree, and when a folder named cis_libs exists at the TOP level as well as
// under `[standalone]`, the top-level one wins and FiveM says so in the log:
//
//   Warning: cis_libs exists in more than one place (...resources\cis_libs is
//   used, the duplicate is ...resources\[standalone]\cis_libs)
//
// This function used to walk `resourcesDir`, which is INSIDE `[standalone]`, so
// it could never see the duplicate it existed to find. The two-folders guard
// below therefore passed, the deploy reported success, and the harness went on
// to confirm the commit it had just written -- into a folder the server never
// loads.
//
// The consequence is not subtle and it is not a warning line in a log nobody
// reads. Every live run of this project that reported `commit NNN confirmed` was
// reading back its own copy: it proved the harness, not the library. Found by
// run-20261005-005649, which failed with "No such export ModuleInfo in resource
// cis_libs" against a commit that contains ModuleInfo -- and the third
// independent signal was the server log line it had been printing all along.
//
// A guard that inspects the wrong tree is not a guard. This walks the parent of
// resourcesDir, which is the tree FiveM actually scans.
function findLibFolders(resourcesDir) {
  const found = []
  const walk = (dir, depth) => {
    if (depth > 4) return
    let ents
    try { ents = fs.readdirSync(dir, { withFileTypes: true }) } catch { return }
    for (const e of ents) {
      if (!e.isDirectory()) continue
      const full = path.join(dir, e.name)
      if (e.name === 'cis_libs') { found.push(full); continue }
      walk(full, depth + 1)
    }
  }
  walk(path.dirname(resourcesDir), 0)
  return found
}

function hasMarker(dir) {
  try { fs.accessSync(path.join(dir, MARKER)); return true } catch { return false }
}

function gitInfo() {
  const sha = spawnSync('git', ['rev-parse', '--short', 'HEAD'], { cwd: root, encoding: 'utf8' })
  const branch = spawnSync('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: root, encoding: 'utf8' })
  const status = spawnSync('git', ['status', '--porcelain'], { cwd: root, encoding: 'utf8' })
  return {
    commit: (sha.stdout || '').trim() || 'unknown',
    branch: (branch.stdout || '').trim() || 'unknown',
    dirty: (status.stdout || '').trim().length > 0,
  }
}

function main() {
  if (!fs.existsSync(ENV)) {
    fail('.live-env.json is missing. Stage 0.5 creates it and it holds no secrets.')
  }
  const env = JSON.parse(fs.readFileSync(ENV, 'utf8'))
  const resourcesDir = env.resourcesDir
  if (!resourcesDir) fail('.live-env.json has no resourcesDir')
  if (!fs.existsSync(resourcesDir)) {
    fail(`resourcesDir does not exist: ${resourcesDir}`)
  }

  const { files, missing } = shippedFiles()
  if (missing.length) {
    // The manifest names a file that is not on disk. Deploying the rest would
    // ship a build whose manifest is a lie.
    fail('the manifest names files that are not on disk: ' + missing.join(', '))
  }
  console.log(`release file set: ${files.length} files from fxmanifest.lua`)

  // THE TWO-FOLDERS RULE, and which folder is canonical.
  const libFolders = findLibFolders(resourcesDir)
  const target = env.libDir || ours[0] || path.join(resourcesDir, 'cis_libs')
  const others = libFolders.filter(d => path.resolve(d) !== path.resolve(target))
  const foreign = others.filter(d => !hasMarker(d))

  if (foreign.length) {
    console.error('')
    console.error('Found a cis_libs folder this tool did not create:')
    for (const f of foreign) console.error('  ' + f)
    console.error('')
    console.error('FiveM resolves `ensure cis_libs` against the whole resources')
    console.error('tree, so it would load ONE of these. The other is not this')
    console.error('tool is not to delete it, so it stops here. Two ways forward, both')
    console.error('the owner call:')
    console.error('  * move that folder out of the resources tree, or')
    console.error('  * confirm it is the canonical location and point libDir at it.')
    process.exit(1)
  }

  // A duplicate THIS TOOL created, which is what [standalone]/cis_libs was until
  // libDir named the real one. It is NOT deleted here -- deleting is the owner's
  // call -- but it is named, because FiveM prints a duplicate-resource warning
  // on every start and the next person will not know which copy is in use.
  if (others.length) {
    console.warn('WARNING: another cis_libs folder exists in the resources tree:')
    for (const d of others) console.warn('  ' + d + '  (not used by this deploy)')
    console.warn('The server is loading: ' + target)
    console.warn('FiveM logs a duplicate-resource warning while both exist. Removing')
    console.warn('the other is an owner decision, so it has not been touched.')
  }

  const info = gitInfo()
  const stamp = new Date().toISOString()

  const copied = copyInto(root, target, files)
  fs.writeFileSync(path.join(target, MARKER), 'cis_libs live harness deploy\n')
  fs.writeFileSync(path.join(target, 'deploy.json'),
    JSON.stringify({ ...info, timestamp: stamp, files: copied }, null, 2) + '\n')
  console.log(`deployed ${copied} files to ${target}`)
  console.log(`  commit ${info.commit} on ${info.branch}${info.dirty ? ' (DIRTY WORKING TREE)' : ''}`)

  // The harness, each into its OWN folder under resourcesDir.
  //
  // `dst` used to be `path.join(harnessDir, res)` with harnessDir already
  // pointing at resources/cis_test, so every harness deploy landed in a nested
  // cis_test/cis_test/ and the LIVE harness kept running whatever it was
  // started with. Nothing failed: the folder did not exist, so the marker check
  // passed, and "deployed 22 harness file(s)" printed. It also dropped a second
  // manifest named 'cis_test' INSIDE the resources tree, which is exactly the
  // recursive double-load the check above exists to prevent -- and the ad-hoc
  // probe I deployed to diagnose a client-export bug kept answering long after
  // the fix meant to replace it had been committed.
  let harnessCopied = 0
  for (const res of HARNESS) {
    const src = path.join(root, 'test', 'live', res)
    if (!fs.existsSync(src)) { console.log(`  ${res}: not written yet, skipped`); continue }
    const dst = path.join(resourcesDir, res)
    if (fs.existsSync(dst) && !hasMarker(dst)) {
      console.error(`  REFUSED ${res}: ${dst} exists and carries no ${MARKER}`)
      process.exit(1)
    }
    // A run's results file is the only record that the run happened and what it
    // found. Replacing the folder wholesale deletes every one of them, so they
    // are carried across rather than destroyed.
    const kept = fs.existsSync(dst)
      ? fs.readdirSync(dst)
        .filter(f => /^results_.*\.json$/.test(f))
        .map(f => ({ name: f, body: fs.readFileSync(path.join(dst, f)) }))
      : []
    fs.rmSync(dst, { recursive: true, force: true })
    harnessCopied += copyInto(src, dst, walkLua(src).map(r => path.relative(src, r)))
    for (const r of kept) fs.writeFileSync(path.join(dst, r.name), r.body)
    fs.writeFileSync(path.join(dst, MARKER), 'cis_libs live harness deploy\n')
    fs.writeFileSync(path.join(dst, 'deploy.json'),
      JSON.stringify({ ...info, timestamp: stamp }, null, 2) + '\n')
    if (kept.length) console.log(`  ${res}: carried ${kept.length} results file(s) across`)
  }
  console.log(`deployed ${harnessCopied} harness file(s) under ${resourcesDir}`)

  console.log('')
  console.log('The agent no longer runs a console sequence. Since W2 the command path is')
  console.log('cis_ctl: a command file the server reads, driven by tools/fx.js. Use')
  console.log('  npm run live:run -- <tier|all>')
  console.log('which deploys, sends the stop / refresh / ensure sequence through fx.js,')
  console.log('and verifies from status.json that the commit it deployed is the one running.')
  console.log('')
  console.log('The OWNER still starts cis_ctl once, from the txAdmin console or server.cfg:')
  console.log('  ensure cis_ctl')
  console.log('  (its ACE lines live in server.cfg -- see cis_libs_vps_setup.md 3.5)')
}

function walkLua(dir, acc = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, e.name)
    if (e.isDirectory()) walkLua(full, acc)
    else acc.push(full)
  }
  return acc
}

main()