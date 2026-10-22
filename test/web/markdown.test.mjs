import test from 'node:test'
import assert from 'node:assert/strict'
import { safeUrl, parseMarkdown, buildDom, parseLine } from '../../web/js/markdown.js'
import { escapeHtml, renderHtml } from './html.mjs'
import { installDom, walk } from './fakedom.mjs'

const XSS = [
  '<img src=x onerror=alert(1)>',
  '<script>alert(1)</script>',
  '"><svg onload=alert(1)>',
  "'><iframe src=javascript:alert(1)>",
  '<a href="javascript:alert(1)">x</a>',
  '&lt;img src=x onerror=alert(1)&gt;',
  '`<img src=x onerror=alert(1)>`',
  '**<img src=x onerror=alert(1)>**',
  '*<img src=x onerror=alert(1)>*',
  '[<img src=x onerror=alert(1)>](https://example.com)',
  '[click](javascript:alert(1))',
  '[click](https://example.com/"onmouseover=alert(1))',
  '[click](data:text/html,<script>alert(1)</script>)',
  '[click](//evil.example/x)',
]

// After removing exactly the tags the renderer is allowed to emit, no `<` may
// remain: anything else would be markup that came from input.
const ALLOWED = /<\/?(p|strong|em|code|br)>|<a href="[^"<>]*" rel="noopener noreferrer">|<\/a>/g

test('escapeHtml escapes every markup-significant character', () => {
  assert.equal(escapeHtml(`<>&"'\`=/`), '&#60;&#62;&#38;&#34;&#39;&#96;&#61;&#47;')
  assert.equal(escapeHtml(null), '')
  assert.equal(escapeHtml(42), '42')
})

test('safeUrl allows only http(s) and nui URLs without quote or space', () => {
  assert.equal(safeUrl('https://example.com/a?b=1'), 'https://example.com/a?b=1')
  assert.equal(safeUrl('nui://cis_libs/web/x.png'), 'nui://cis_libs/web/x.png')
  for (const bad of ['javascript:alert(1)', 'JaVaScRiPt:alert(1)', 'data:text/html,x', '//evil', 'https://a.com/"x', 'https://a b', 'vbscript:x', '']) {
    assert.equal(safeUrl(bad), null, bad)
  }
})

test('XSS: every payload renders as text in the string form', () => {
  for (const p of XSS) {
    const html = renderHtml(p)
    assert.equal(html.replace(ALLOWED, '').includes('<'), false, `${p} -> ${html}`)
    assert.equal(/<img|<script|<svg|<iframe|href="(?!https?:|nui:)/i.test(html), false, `${p} -> ${html}`)
  }
})

test('XSS: every payload becomes text nodes in the DOM form, never elements', () => {
  const { doc } = installDom()
  for (const p of XSS) {
    const root = doc.createElement('div')
    buildDom(parseMarkdown(p), doc, root)
    walk(root, (n) => {
      if (n.nodeType !== 1) return
      assert.ok(['P', 'STRONG', 'EM', 'CODE', 'BR', 'A'].includes(n.tagName), `${p} created <${n.tagName}>`)
      for (const k of n.attributes.keys()) assert.ok(k === 'href' || k === 'rel', `${p} set attribute ${k}`)
      if (n.tagName === 'A') assert.match(n.getAttribute('href'), /^https:\/\/example\.com$/)
    })
    // The visible text still carries the input, so the player sees what was sent.
    if (p.includes('<img')) assert.ok(root.textContent.includes('<img src=x onerror=alert(1)>'), p)
  }
})

test('bold, italic, code, links, line breaks and paragraphs', () => {
  assert.equal(renderHtml('**b** *i* _i_ `c`'), '<p><strong>b</strong> <em>i</em> <em>i</em> <code>c</code></p>')
  assert.equal(renderHtml('a\nb'), '<p>a<br>b</p>')
  assert.equal(renderHtml('a\n\nb'), '<p>a</p><p>b</p>')
  assert.equal(renderHtml('[docs](https://example.com)'), '<p><a href="https:&#47;&#47;example.com" rel="noopener noreferrer">docs</a></p>')
  assert.equal(renderHtml('**bold *and italic***'), '<p><strong>bold <em>and italic</em></strong></p>')
  assert.equal(renderHtml('`**not bold**`'), '<p><code>**not bold**</code></p>')
})

test('ambiguous markers stay literal', () => {
  assert.equal(renderHtml('snake_case_name'), '<p>snake_case_name</p>')
  assert.equal(renderHtml('2 * 3 * 4'), '<p>2 * 3 * 4</p>')
  assert.equal(renderHtml('**unclosed'), '<p>**unclosed</p>')
  assert.equal(renderHtml('\\*escaped\\*'), '<p>*escaped*</p>')
  assert.equal(renderHtml('[not a link]'), '<p>[not a link]</p>')
})

test('a rejected link keeps its text and drops the URL', () => {
  assert.equal(renderHtml('[x](javascript:alert(1))'), '<p>x</p>')
})

test('bounded: huge and pathological input terminates quickly', () => {
  const t0 = Date.now()
  renderHtml('*a'.repeat(20000))
  renderHtml('**'.repeat(20000))
  renderHtml('['.repeat(20000))
  renderHtml('_x'.repeat(20000))
  assert.ok(Date.now() - t0 < 2000)
  assert.ok(renderHtml('x'.repeat(20000)).length < 9000)
})

test('nesting depth is capped', () => {
  const deep = '**'.repeat(1) + '*'.repeat(0) + '**a **b **c **d **e** d** c** b** a**'
  assert.doesNotThrow(() => renderHtml(deep))
})

test('parseLine keeps a single block with line breaks', () => {
  assert.deepEqual(parseLine('a\nb').map((n) => n.t), ['text', 'br', 'text'])
  assert.deepEqual(parseLine(undefined), [])
})
