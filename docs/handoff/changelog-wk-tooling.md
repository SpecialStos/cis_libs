# CHANGELOG bullets from the tooling worker (wk-tooling)

Ready to paste into `CHANGELOG.md` under `[Unreleased]`. The worker did not edit
CHANGELOG.md. Items T-H1, T-M1 and T-M2 were already fixed by commit 985135a and
are not repeated here.

### Fixed

- **The test suites no longer contain assertions that cannot fail.**
  `check(env.EXPORTS and true or true, ...)` in the client suite and
  `check(true, ...)` in the contracts suite are replaced by real checks: the
  client suite asserts that a networked record is not tracked as a local
  spawn, and the contracts suite binds `SecureNetOn` with
  `{ maxHits = 1, windowMs = 1000 }`, fires the event twice and requires that
  exactly one call got through.
- **A failing server-suite check is reported once.** The server suite printed
  its `FAIL` lines in the middle of the run and again at the end, so one
  failure counted as two. Only the final report prints them now.
- **The test preload order is the manifest's order.** `histogram` and `ready`
  were swapped and `shared/statebag.lua` was never preloaded. Both runners now
  end with the statebag file, load it with the natives it needs stubbed and
  restored, and stop with a diff if their list ever differs from
  `shared_scripts` in `fxmanifest.lua`.
- **`tools/lint.js` removes its temp copy of the tree.** It called
  `process.exit` inside `try`, so the cleanup never ran and every run left a
  `cis-luacheck-*` folder in the temp directory, on success and on failure.
- **`tools/syntax-check.js` parses the files it used to skip.** It gave up on a
  whole file at its first FiveM backtick hash literal or Lua 5.4 attribute, so
  `client/cache.lua` was never parsed and a real error after a hash literal went
  unseen. It now blanks only those constructs, with text of the same length,
  and parses the rest on its real line numbers. Its header no longer claims
  that CI runs `luac`; CI does not.
- **`tools/docs-check.js` reads every document and every export spelling.** It
  read five files and missed `exports.cis_libs:Name`, the form
  `DOCUMENTATION.md` uses 33 times. It now checks the live-test runbook and the
  unrun list in full, checks every other markdown file (`docs/archive`,
  `docs/handoff`) for broken links and anchors, recognises both export
  spellings for `cis_libs` only, and uses GitHub's anchor rule (each space a
  hyphen, underscore kept). The two links in `docs/archive/DOCUMENTATION-1.x.md`
  that pointed at a `LICENSE.md` that is not there now point at the real file.
- **The mutation gate no longer counts a crash as a kill.** `tools/mutate.js`
  treated any non-zero exit as "killed", including a runner that could not
  start, a signal, a timeout, or a crash before any test ran. A mutation now
  counts as killed only when the output shows a test failure; anything else is
  an `ERROR` row and fails the build. Two rows with the same id in
  `test/mutations.json` are refused.
- **The README examples are run.** Every `lua` fence in `README.md` and
  `DOCUMENTATION.md` is tagged `lua example` and executed by `test/examples.lua`
  against the real `init.lua`. The manifest snippet is compared with the real
  manifest, the `SetConfig` snippet must pass `CisDefaults.validate`, a
  `-- true` or `-- false` comment on a `local` line is asserted, and a new
  untagged fence fails the suite.
- **`README.md` and `test/live/RUNBOOK.md` say what CI runs.** The stubbed tier
  runs on every pull request, every push to main and nightly. The live server
  job is started on those events but skips, because the `FIVEM_LICENSE_KEY`
  secret is not set, so CI does not exercise that tier yet.

### Changed

- **`npm run test:all` also runs `npm run test:tools`**, the self-test for
  `lint.js`, `syntax-check.js`, `docs-check.js` and `mutate.js`
  (`test/tools-selftest.js`).
- **The release workflow is two jobs.** `build` has a read-only token, checks
  that the tag matches `package.json` and that the tag's commit is on main,
  runs the full gate and the mutation gate, and writes `SHA256SUMS` next to the
  zip. `publish` holds `contents: write`, has no checkout, verifies the
  checksum again and creates the draft release with the zip and `SHA256SUMS`
  attached.
- **Every CI job has a timeout**, and the nightly run has a concurrency group
  of its own, so a push to main no longer cancels it.
- **`engines.node` is now `>=24`**, the only Node version CI runs. `>=18` was
  never exercised.

### Security

- **Every GitHub Action is pinned by full commit SHA**, with the tag it came
  from in a trailing comment, in `tests.yml` and `release.yml`. A moved or
  compromised tag can no longer change what runs.
- **Checkouts keep no credentials** (`persist-credentials: false`), so no token
  sits in `.git/config` while `npm ci` and the tests run, and the only job
  with write permission runs no repository code.
- **Releases carry a `SHA256SUMS` asset** and cannot be built from a tag that
  is not on main.
