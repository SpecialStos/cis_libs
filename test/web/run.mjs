// `npm run test:web`: every test/web/*.test.mjs under node's built-in runner.
// Listed here rather than globbed in package.json, because neither a
// directory argument nor a quoted glob works for `node --test` on every Node
// version the engines field allows, and a shell glob does not expand on Windows.
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const dir = path.dirname(fileURLToPath(import.meta.url))
const tests = fs.readdirSync(dir).filter((f) => f.endsWith('.test.mjs')).sort().map((f) => path.join(dir, f))
if (tests.length === 0) {
  console.error('test:web: no test files found')
  process.exit(1)
}
const r = spawnSync(process.execPath, ['--test', ...tests], { stdio: 'inherit' })
process.exit(r.status === null ? 2 : r.status)
