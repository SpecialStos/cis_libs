// Static properties of what ships in web/: no HTML sinks, no network, every
// file in the manifest, and a size budget.
import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const web = path.join(root, 'web')
const BUDGET = 60 * 1024

function files(dir) {
  const out = []
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name)
    if (e.isDirectory()) out.push(...files(p))
    else out.push(p)
  }
  return out
}

const shipped = files(web).filter((f) => !f.endsWith('package.json'))
const rel = (f) => path.relative(root, f).split(path.sep).join('/')
const code = (src) => src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`])\/\/.*$/gm, '$1')

test('no HTML sinks or dynamic code anywhere in web/', () => {
  for (const f of shipped.filter((x) => x.endsWith('.js'))) {
    const src = code(fs.readFileSync(f, 'utf8'))
    for (const sink of ['innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'srcdoc', 'eval(', 'new Function', 'setTimeout(\'', 'createContextualFragment', 'DOMParser']) {
      assert.equal(src.includes(sink), false, `${rel(f)} uses ${sink}`)
    }
  }
})

test('zero network: no remote scripts, styles, fonts or imports', () => {
  for (const f of shipped) {
    const src = code(fs.readFileSync(f, 'utf8'))
    if (f.endsWith('.css')) {
      assert.equal(/url\(|@import|@font-face/.test(src), false, `${rel(f)} loads something`)
    }
    if (f.endsWith('.html')) {
      for (const m of src.matchAll(/(?:src|href)="([^"]+)"/g)) assert.match(m[1], /^[\w./-]+$/, `${rel(f)} references ${m[1]}`)
    }
    if (f.endsWith('.js')) {
      for (const m of src.matchAll(/^\s*import\b[^'"]*['"]([^'"]+)['"]/gm)) assert.match(m[1], /^\.\/[\w-]+\.js$/, `${rel(f)} imports ${m[1]}`)
    }
  }
})

test('every web file is declared in fxmanifest.lua files {} (so it ships)', () => {
  const manifest = fs.readFileSync(path.join(root, 'fxmanifest.lua'), 'utf8')
  const block = /files\s*\{([\s\S]*?)\}/.exec(manifest)[1]
  const declared = new Set([...block.matchAll(/'([^']+)'/g)].map((m) => m[1]))
  for (const f of shipped) assert.ok(declared.has(rel(f)), `${rel(f)} is not in the manifest`)
  assert.match(manifest, /ui_page 'web\/index\.html'/)
})

test(`JS + CSS stays under the ${BUDGET / 1024} KB budget (unminified)`, () => {
  const bytes = shipped.filter((f) => /\.(js|css)$/.test(f)).reduce((n, f) => n + fs.statSync(f).size, 0)
  assert.ok(bytes < BUDGET, `${bytes} bytes`)
})
