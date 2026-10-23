-- A BROKEN suite, for tools/run-lua54.js only: it reaches its summary having
-- run no assertion. The Lua 5.4 driver must report it as a failure. It is not
-- in either SUITES list.
TEST_CASES = {}
io.write('empty passed=0 failed=0\n')
