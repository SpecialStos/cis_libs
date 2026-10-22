// The page runs in FiveM's CEF, reported as Chromium 103. A feature that
// arrived later is not an error there: it is silently ignored (CSS) or throws
// on first use (JS). The standalone translate/rotate properties (104) shipped
// once and left every centred panel off by half its width. Each entry is a
// pattern for a feature newer than 103 and the version that brought it.
import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const web = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../web')
const files = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
  e.isDirectory() ? files(path.join(dir, e.name)) : [path.join(dir, e.name)])
const source = files(web).filter((f) => /\.(css|js|html)$/.test(f))

const CSS = [
  [/(^|[;{\s])(translate|rotate|scale)\s*:/m, 'standalone translate/rotate/scale (104)'],
  [/:has\(/, ':has() (105)'],
  [/@container\b|container-type\s*:/, 'container queries (105)'],
  [/\b\d*\.?\d+(dvh|svh|lvh|dvw|svw|lvw)\b/, 'dynamic viewport units (108)'],
  [/color-mix\(/, 'color-mix() (111)'],
  [/\btext-wrap\s*:/, 'text-wrap (114)'],
  [/@scope\b/, '@scope (118)'],
  [/@starting-style\b/, '@starting-style (117)'],
  [/\b(oklch|oklab|lab|lch)\(/, 'oklch/lab colours (111)'],
]
const JS = [
  [/\.(toSorted|toReversed|toSpliced)\(/, 'change-array-by-copy (110)'],
  [/Object\.groupBy|Map\.groupBy/, 'groupBy (117)'],
  [/Promise\.withResolvers/, 'Promise.withResolvers (119)'],
  [/Array\.fromAsync/, 'Array.fromAsync (121)'],
  [/\.isWellFormed\(|\.toWellFormed\(/, 'well-formed strings (111)'],
  [/\.(union|intersection|symmetricDifference|isSubsetOf)\(/, 'Set methods (122)'],
  [/\/[^/\n]+\/[a-z]*v[a-z]*\.test\(/, 'RegExp v flag (112)'],
]

// CSS nesting (112): a rule whose block holds another selector block.
const nested = (css) => /\{[^{}]*&[^{}]*\{/.test(css)

test('nothing in web/ needs a Chromium newer than CEF 103', () => {
  const found = []
  for (const f of source) {
    const text = fs.readFileSync(f, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')
    const rel = path.relative(web, f)
    const rules = f.endsWith('.js') ? JS : CSS
    for (const [re, what] of rules) if (re.test(text)) found.push(`${rel}: ${what}`)
    if (f.endsWith('.css') && nested(text)) found.push(`${rel}: CSS nesting (112)`)
    if (f.endsWith('.html')) for (const m of text.matchAll(/<style>([\s\S]*?)<\/style>/g)) {
      for (const [re, what] of CSS) if (re.test(m[1])) found.push(`${rel}: ${what}`)
    }
  }
  assert.deepEqual(found, [])
})

test('the scan sees the bug it was written for', () => {
  assert.ok(CSS[0][0].test('.x {left:50%;translate:-50% 0}'))
  assert.ok(CSS[0][0].test('.x {inset:0;rotate:-90deg}'))
  assert.ok(!CSS[0][0].test('.x {transform:translate(-50%,0)}'))
  assert.ok(!CSS[0][0].test('.x {--cis-place:translate(0)}'))
})
