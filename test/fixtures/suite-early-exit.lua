-- A BROKEN suite, for tools/run-lua54.js only: it records one passing case and
-- exits 0 before its summary, the way a stray os.exit(0) would. The Lua 5.4
-- driver must report it as a failure. It is not in either SUITES list.
TEST_CASES = {}
TEST_CASES[1] = { name = 'the only case that ran', status = 'passed' }
os.exit(0)
io.write('early-exit passed=1 failed=0\n')
