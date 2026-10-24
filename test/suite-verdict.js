'use strict'

// One suite's verdict, from its output and exit status. Split out of test/run.js
// so test/tools-selftest.js can feed it the outputs a broken suite produces.
//
// A suite reports its own line. Three things are consulted, because trusting
// any one of them is how a suite "passes" having never run:
//
//   * the exit status -- a suite that throws prints no summary at all;
//   * the summary line -- the suite's own count;
//   * EVERY `FAIL` line in the output, counted independently.
//
// The third is not redundant. A suite writes its summary with io.write and its
// failures with io.stderr:write, so a failure that happens after the summary
// is printed is counted in neither. That is exactly the "silent exit is
// indistinguishable from a pass" failure this rewrite exists to remove, and it
// was reproduced deliberately: appending `expect(false)` to the end of
// modules.lua printed "module tests: passed=326 failed=0" and exited 0, with
// the FAIL sitting on stderr underneath it. A runner that only reads the
// summary would have passed that run.
//
// A fourth: a summary of `passed=0` ran no assertion. A suite that exits early
// after printing its header, or whose cases were all skipped, reports exactly
// that, and the Lua 5.4 driver already refuses it. Counting it green here left
// the fengari driver the one place an empty suite passed.
function judge(out, status) {
  const summary = out.split(/\r?\n/).find(l => /passed=\d+/.test(l)) || ''
  const fails = (out.match(/^FAIL/gm) || []).length
  const crashed = status !== 0
  const reportedFail = /failed=[1-9]/.test(summary)
  let count = 0
  const m = /passed=(\d+)/.exec(summary)
  if (m) count = Number(m[1])
  const ok = !crashed && !reportedFail && fails === 0 && /passed=\d+/.test(summary) && count > 0
  return { ok, count, fails, crashed, status, summary: summary.trim() }
}

module.exports = { judge }
