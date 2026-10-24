// Static properties of what ships in web/: no HTML sinks, no network, every
// file in the manifest, and a size budget.
import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const web = path.join(root, 'web')
// Raised from 60 KB for the NUI re-audit: about 7 KB of it is the icon set
// (ox_lib callers name Font Awesome icons, and an unknown name now draws
// nothing), the rest Lua-parity validation and the skill-check renderer.
// Still unminified and loaded from disk; the budget catches a library pulled in.
const BUDGET = 80 * 1024

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

// SKILL invariant 5: the page loads from https://cfx-nui-cis_libs/web/, so a
// root-absolute '/style.css' resolves against the resource root and 404s, and
// '//host/x' or 'https://x' is a remote load. Only a path relative to the page.
const RELATIVE = /^(?:\.{1,2}\/)*[\w-][\w.-]*(?:\/[\w.-]+)*$/

test('the relative-path rule rejects what it was written for', () => {
  for (const ok of ['style.css', 'js/app.js', './js/app.js', '../web/style.css']) assert.match(ok, RELATIVE)
  for (const bad of ['/style.css', '/assets/x.png', '//evil.example/x.js', 'https://evil.example/x.js', 'nui://cis_libs/x.js', 'js//app.js']) {
    assert.doesNotMatch(bad, RELATIVE, bad)
  }
})

test('no backdrop-filter: the page is composited over the game, with nothing behind it to blur', () => {
  for (const f of shipped.filter((x) => /\.(css|js|html)$/.test(x))) {
    assert.equal(/backdrop-filter|backdropFilter/i.test(code(fs.readFileSync(f, 'utf8'))), false, `${rel(f)} uses backdrop-filter`)
  }
})

// The CSP is defence in depth under the session tokens: an injected inline
// script, a remote script or an object never runs. Element styles are set
// through the CSSOM (style.setProperty), which style-src does not govern, so
// no 'unsafe-inline' is needed anywhere.
function csp() {
  const html = fs.readFileSync(path.join(web, 'index.html'), 'utf8')
  const m = /<meta\s+http-equiv="Content-Security-Policy"\s+content="([^"]+)"/i.exec(html)
  assert.ok(m, 'index.html has a Content-Security-Policy meta tag')
  const out = {}
  for (const part of m[1].split(';').map((x) => x.trim()).filter(Boolean)) {
    const [name, ...values] = part.split(/\s+/)
    out[name] = values
  }
  return { html, policy: m[1], dir: out }
}

test('CSP: nothing but the page\'s own files runs, and the callbacks still reach Lua', () => {
  const { html, policy, dir } = csp()
  assert.ok(html.indexOf('Content-Security-Policy') < html.indexOf('<script'), 'the policy comes before the first script')
  assert.deepEqual(dir['default-src'], ["'none'"])
  assert.deepEqual(dir['script-src'], ["'self'"])
  assert.deepEqual(dir['style-src'], ["'self'"])
  assert.deepEqual(dir['object-src'], ["'none'"])
  assert.deepEqual(dir['base-uri'], ["'none'"])
  assert.deepEqual(dir['form-action'], ["'none'"])
  assert.equal(/unsafe-|\*|data:|blob:/.test(policy), false, `no unsafe source, wildcard, data: or blob: in ${policy}`)
  // core.js posts to https://<resource>/<cb>; an underscore is not a CSP host
  // character, so the scheme is named rather than the host.
  assert.ok(dir['connect-src'] && dir['connect-src'].includes('https:'), 'callbacks (https://cis_libs/<cb>) are allowed')
  // Icons and context images: a consumer may name https:// or nui:// URLs, or
  // the page's own relative files (core.js imageUrl).
  for (const src of ["'self'", 'https:', 'nui:']) assert.ok(dir['img-src'] && dir['img-src'].includes(src), `img-src allows ${src}`)
})

test('CSP: the page needs no inline script, inline style or handler attribute', () => {
  const { html } = csp()
  assert.equal(/<style|\sstyle=|\son\w+=/i.test(html), false, 'no <style>, style= or on*= in index.html')
  for (const m of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
    assert.match(m[1], /\ssrc="/, 'every script is a file')
    assert.equal(m[2].trim(), '', 'no inline script body')
  }
  for (const f of shipped.filter((x) => x.endsWith('.js'))) {
    const src = code(fs.readFileSync(f, 'utf8'))
    assert.equal(/setAttribute\(\s*['"]style['"]|\.cssText\b|svg\([^)]*\bstyle\b/.test(src), false, `${rel(f)} sets a style attribute`)
  }
})

test('NUI callback strict mode: only this resource\'s page may post to https://cis_libs/<cb>', () => {
  const manifest = fs.readFileSync(path.join(root, 'fxmanifest.lua'), 'utf8')
  // ResourceUI.cpp opts in only when the value is exactly 'true' and the
  // resource has exactly one ui_page.
  assert.match(manifest, /^nui_callback_strict_mode 'true'\r?$/m)
  assert.equal([...manifest.matchAll(/^ui_page\b/gm)].length, 1, 'exactly one ui_page')
})

// A page handler for an action Lua never sends is dead code that looks like
// a feature (notify:clear was: nothing ever sent it, so no toast could be
// cleared). An action Lua sends with no handler draws nothing.
test('every page handler is for an action Lua sends, and every action Lua sends has a handler', () => {
  const dir = path.join(root, 'client', 'interface')
  const lua = fs.readdirSync(dir).filter((f) => f.endsWith('.lua')).map((f) => fs.readFileSync(path.join(dir, f), 'utf8')).join('\n')
  const sent = new Set([...lua.matchAll(/I\.send\('([^']+)'/g), ...lua.matchAll(/encode\(\{\s*action = '([^']+)'/g)].map((m) => m[1]))
  const handled = new Set()
  for (const f of shipped.filter((x) => x.endsWith('.js'))) {
    for (const m of code(fs.readFileSync(f, 'utf8')).matchAll(/\bon\('([^']+)'/g)) handled.add(m[1])
  }
  assert.ok(sent.size > 10 && handled.size > 10, 'the scan found both sides')
  for (const a of handled) assert.ok(sent.has(a), `the page handles '${a}', which Lua never sends`)
  for (const a of sent) assert.ok(handled.has(a), `Lua sends '${a}', which the page does not handle`)
})

// WCAG AA: text on the accent (primary button, menu header, key cap) needs
// 4.5:1. The default was #fff on #4c8dff, about 3.2:1.
function luminance(hex) {
  const h = hex.replace('#', '')
  const full = h.length === 3 ? [...h].map((c) => c + c).join('') : h
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(full.slice(i, i + 2), 16) / 255)
    .map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4))
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}
const contrast = (a, b) => { const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05) }

test('contrast: the default text on the accent is readable (4.5:1)', () => {
  const css = fs.readFileSync(path.join(web, 'style.css'), 'utf8')
  const rootBlock = /:root\s*\{([^}]*)\}/.exec(css)[1]
  const token = (k) => new RegExp(`--cis-${k}:\\s*(#[0-9a-f]{3,6})\\b`, 'i').exec(rootBlock)?.[1]
  const accent = token('accent')
  const fg = token('accent-fg')
  assert.ok(accent && fg, 'both tokens are hex colours')
  assert.ok(contrast(accent, fg) >= 4.5, `accent-fg on accent is ${contrast(accent, fg).toFixed(2)}:1`)
  assert.ok(contrast('#4c8dff', '#ffffff') < 4.5, 'the check fails the old pair')
})

test('zero network: no remote scripts, styles, fonts or imports', () => {
  for (const f of shipped) {
    const src = code(fs.readFileSync(f, 'utf8'))
    if (f.endsWith('.css')) {
      assert.equal(/url\(|@import|@font-face/.test(src), false, `${rel(f)} loads something`)
    }
    if (f.endsWith('.html')) {
      for (const m of src.matchAll(/(?:src|href)="([^"]+)"/g)) assert.match(m[1], RELATIVE, `${rel(f)} references ${m[1]}`)
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
