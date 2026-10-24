// The real components, driven by the same messages Lua sends, on the fake DOM.
import test from 'node:test'
import assert from 'node:assert/strict'
import { installDom, walk } from './fakedom.mjs'

const dom = installDom()
await import('../../web/js/app.js')

const P = '<img src=x onerror=alert(1)>'
const TAGS = new Set(['DIV', 'SECTION', 'SPAN', 'KBD', 'BUTTON', 'H2', 'FORM', 'LABEL', 'INPUT', 'TEXTAREA', 'OUTPUT',
  'DL', 'DT', 'DD', 'ASIDE', 'UL', 'LI', 'SVG', 'PATH', 'CIRCLE', 'G', 'LINE', 'IMG', 'STRONG', 'EM', 'CODE', 'BR', 'A', 'P', 'B'])

function everything() {
  const out = []
  for (const layer of Object.values(dom.doc.layers)) {
    out.push(layer)
    walk(layer, (n) => out.push(n))
  }
  return out
}

function assertInert() {
  let textHits = 0
  for (const n of everything()) {
    if (n.nodeType === 3) { if (n.data.includes(P)) textHits++; continue }
    assert.ok(TAGS.has(n.tagName), `unexpected element <${n.tagName}>`)
    for (const k of n.attributes.keys()) assert.ok(!/^on/i.test(k), `event-handler attribute ${k} on <${n.tagName}>`)
    if (n.tagName === 'IMG') assert.notEqual(n.getAttribute('src'), 'x', 'an <img> was built from user text')
    if (n.tagName === 'A') assert.match(n.getAttribute('href'), /^(https?|nui):\/\//)
    assert.equal(n.style._map.has('background-image'), false)
  }
  return textHits
}

test('ready is posted on load', () => {
  assert.ok(dom.posts.some((p) => p.name === 'ready'))
})

test('session: the page echoes the hello token on ready, and Escape carries it', () => {
  dom.sendFrom({ other: true }, 'hello', { token: 'forged' })
  assert.ok(!dom.posts.some((p) => p.body && p.body.token === 'forged'), 'a hello from another frame is ignored')
  dom.send('hello', { token: 'tok-1' })
  assert.deepEqual(dom.posts.at(-1), { name: 'ready', body: { token: 'tok-1' } })
  dom.keydown('Escape')
  assert.deepEqual(dom.posts.at(-1), { name: 'escape', body: { token: 'tok-1' } })
})

test('session: after init, a later hello is ignored, so a forged ready cannot make the live page reset', () => {
  dom.send('init', { theme: {}, locale: {} })
  const n = dom.posts.length
  dom.send('hello', { token: 'tok-2' })
  assert.equal(dom.posts.length, n, 'no second ready')
  dom.keydown('Escape')
  assert.deepEqual(dom.posts.at(-1), { name: 'escape', body: { token: 'tok-1' } })
})

test('XSS: <img onerror> in every user-supplied string of every component renders as text', () => {
  dom.send('notify', { id: P, title: P, description: P, icon: P, iconColor: P, type: P, position: P })
  dom.send('textui:show', { text: P, icon: P, iconColor: P, position: P, style: P })
  dom.send('progress:start', { kind: 'circle', label: P, duration: 1000, position: P })
  dom.send('alert:open', { id: 1, header: P, content: P, cancel: true, size: P, labels: { confirm: P, cancel: P } })
  dom.send('input:open', {
    id: 2, heading: P,
    rows: [
      { type: 'input', label: P, description: P, placeholder: P, icon: P, default: P },
      { type: 'select', label: P, options: [{ value: P, label: P }], default: P },
      { type: 'multi-select', label: P, options: [P] },
      { type: 'textarea', label: P, default: P },
      { type: 'color', label: P, default: P },
      { type: 'number', label: P, placeholder: P },
      { type: P, label: P },
    ],
    options: { labels: { confirm: P, cancel: P }, size: P },
  })
  dom.send('context:open', {
    token: 1, title: P, hasBack: true,
    options: [{ title: P, description: P, icon: P, iconColor: P, colorScheme: P, image: P, metadata: [{ label: P, value: P }] }],
  })
  const item = everything().find((n) => n.nodeType === 1 && n.getAttribute('role') === 'menuitem')
  item.dispatch('focus')
  dom.send('menu:open', { title: P, position: P, options: [{ label: P, description: P, icon: P, colorScheme: P, values: [{ label: P, description: P }] }] })
  dom.send('radial:open', { token: 3, items: [{ label: P, icon: P }] })
  dom.send('skill:round', { id: '4', start: 120, size: 40, degPerMs: 0.18, key: P })
  const hits = assertInert()
  assert.ok(hits >= 20, `the payload is visible as text (${hits} text nodes carry it)`)
  dom.send('skill:stop', {})
})

test('a javascript: link in markdown never becomes an anchor', () => {
  dom.send('alert:open', { id: 9, header: 'h', content: '[x](javascript:alert(1)) [ok](https://example.com)' })
  const anchors = everything().filter((n) => n.nodeType === 1 && n.tagName === 'A')
  assert.equal(anchors.length, 1)
  assert.equal(anchors[0].getAttribute('href'), 'https://example.com')
  dom.send('alert:close', { id: 9 })
})

test('Escape is reported to Lua, which decides what it closes', () => {
  const before = dom.posts.length
  dom.keydown('Escape')
  assert.equal(dom.posts[before].name, 'escape')
})

test('alert: confirm posts the id and closes; the dialog traps Tab', () => {
  dom.send('alert:open', { id: 21, header: 'Sure?', content: 'x', cancel: true })
  const dialog = everything().find((n) => n.nodeType === 1 && n.getAttribute('role') === 'alertdialog')
  assert.ok(dialog, 'role=alertdialog')
  assert.equal(dialog.getAttribute('aria-modal'), 'true')
  const buttons = dialog.querySelectorAll('button')
  assert.equal(buttons.length, 2)
  assert.equal(dom.doc.activeElement, buttons[1], 'confirm has initial focus')
  const e = dialog.dispatch('keydown', { key: 'Tab', shiftKey: false })
  assert.equal(e.defaultPrevented, true)
  assert.equal(dom.doc.activeElement, buttons[0], 'Tab wraps to the first button')
  buttons[1].dispatch('click')
  const last = dom.posts.at(-1)
  assert.deepEqual(last, { name: 'alert', body: { id: 21, result: 'confirm' } })
  // Still up until Lua settles it: a refused or lost answer must not leave
  // focus over a dialog that is gone. Lua's alert:close removes it.
  assert.ok(dialog.parentNode.parentNode !== null, 'kept until Lua closes it')
  dom.send('alert:close', { id: 21 })
  assert.ok(dialog.parentNode.parentNode === null, 'removed from the page')
})

test('input: client-side validation blocks submit, then posts one value per row', () => {
  dom.send('input:open', { id: 31, heading: 'Form', rows: [{ type: 'number', label: 'Age', required: true, min: 1 }, { type: 'checkbox', label: 'Ok' }] })
  const dialog = everything().find((n) => n.nodeType === 1 && n.getAttribute('role') === 'dialog')
  const [cancel, confirm] = dialog.querySelectorAll('button').filter((b) => !b.hasAttribute('hidden'))
  const before = dom.posts.length
  confirm.dispatch('click')
  assert.equal(dom.posts.length, before, 'nothing posted while invalid')
  const age = dialog.querySelectorAll('input')[0]
  assert.equal(age.getAttribute('aria-invalid'), 'true')
  const errId = age.getAttribute('aria-describedby')
  assert.ok(errId.includes('-err'))
  assert.ok(everything().some((n) => n.nodeType === 3 && n.data === 'This field is required'))
  age.dispatch('input', { target: { value: '0' } })
  confirm.dispatch('click')
  assert.ok(everything().some((n) => n.nodeType === 3 && n.data === 'Must be at least 1'))
  age.dispatch('input', { target: { value: '42' } })
  confirm.dispatch('click')
  assert.deepEqual(dom.posts.at(-1), { name: 'input', body: { id: 31, values: [42, false] } })
  void cancel
})

test('locale strings sent from Lua replace built-in labels', () => {
  dom.send('locale', { confirm: 'Bestätigen', cancel: 'Abbrechen', required: 'Pflichtfeld' })
  dom.send('alert:open', { id: 41, header: 'h', content: 'c', cancel: true })
  const texts = everything().filter((n) => n.nodeType === 3).map((n) => n.data)
  assert.ok(texts.includes('Bestätigen') && texts.includes('Abbrechen'))
  dom.send('alert:close', { id: 41 })
})

test('context: keyboard moves between enabled items and selection posts an index, not an event', () => {
  dom.send('context:open', { token: 51, title: 'M', options: [{ title: 'a' }, { title: 'b', disabled: true }, { title: 'c' }] })
  const items = everything().filter((n) => n.nodeType === 1 && n.getAttribute('role') === 'menuitem')
  const list = items[0].parentNode
  assert.equal(dom.doc.activeElement, items[0])
  list.dispatch('keydown', { key: 'ArrowDown' })
  assert.equal(dom.doc.activeElement, items[2], 'the disabled item is skipped')
  items[2].dispatch('click')
  assert.deepEqual(dom.posts.at(-1), { name: 'context', body: { token: 51, action: 'select', index: 3 } })
  const before = dom.posts.length
  items[1].dispatch('click')
  assert.equal(dom.posts.length, before, 'a disabled item posts nothing')
})

test('theme: only safe values reach CSS custom properties', () => {
  dom.send('theme', { accent: 'url(https://evil.example/x.png)', radius: 999, fontScale: 9, mode: 'light', colors: { bg: 'red;x:url(y)', fg: '#fff' } })
  const style = dom.doc.documentElement.style._map
  assert.equal(style.has('--cis-accent'), false)
  assert.equal(style.get('--cis-radius'), '32px')
  assert.equal(style.get('--cis-scale'), '1.5')
  assert.equal(style.has('--cis-bg'), false)
  assert.equal(style.get('--cis-fg'), '#fff')
  assert.equal(dom.doc.documentElement.dataset.theme, 'light')
})

test('idle: nothing on screen after everything closes', () => {
  dom.send('notify:clear', {})
  dom.send('textui:hide', {})
  dom.send('progress:stop', {})
  dom.send('context:close', {})
  dom.send('menu:close', {})
  dom.send('radial:close', {})
  dom.send('alert:close', { id: 1 })
  dom.send('input:close', { id: 2 })
  dom.send('input:close', { id: 31 })
  dom.send('skill:stop', {})
  const left = Object.entries(dom.doc.layers).filter(([id, l]) => id !== 'cis-notify' && l.childNodes.some((c) => !(c.className || '').includes('cis-leave')))
  assert.deepEqual(left.map(([id]) => id), [])
})

test('a message from another frame is dropped (only the NUI root speaks for the game)', () => {
  dom.sendFrom({ other: true }, 'alert:open', { id: 'forged', header: 'Give me your bank PIN', content: 'x' })
  assert.ok(!everything().some((n) => n.nodeType === 3 && n.data === 'Give me your bank PIN'))
})

test('a dialog gives focus back to what had it when it closes', () => {
  const before = document.createElement('button')
  dom.doc.activeElement = before
  dom.send('alert:open', { id: 'f1', header: 'h', content: 'c' })
  assert.notEqual(dom.doc.activeElement, before)
  dom.send('alert:close', { id: 'f1' })
  assert.equal(dom.doc.activeElement, before)
})

test('input: a field Lua refused is marked and focused', () => {
  dom.send('input:open', { id: 'v1', heading: 'F', rows: [{ type: 'input', label: 'A' }, { type: 'input', label: 'B' }] })
  const dialog = everything().find((n) => n.nodeType === 1 && n.getAttribute('role') === 'dialog')
  const [, b] = dialog.querySelectorAll('input')
  dom.send('input:invalid', { id: 'v1', index: 2 })
  assert.equal(b.getAttribute('aria-invalid'), 'true')
  assert.equal(dom.doc.activeElement, b)
  dom.send('input:invalid', { id: 'other', index: 1 })
  assert.notEqual(dialog.querySelectorAll('input')[0].getAttribute('aria-invalid'), 'true', 'another dialog\'s id is ignored')
  dom.send('input:close', { id: 'v1' })
})

test('a held Escape reports one press, not one per repeat', () => {
  const before = dom.posts.length
  dom.keydown('Escape', { repeat: true })
  assert.equal(dom.posts.length, before)
})

test('context: clicking a link inside an option opens the link, it does not pick the option', () => {
  dom.send('context:open', { token: 'L', title: 'M', options: [{ title: 'a', description: '[docs](https://example.com)' }] })
  const item = everything().find((n) => n.nodeType === 1 && n.getAttribute('role') === 'menuitem')
  const before = dom.posts.length
  item.dispatch('click', { target: { closest: (sel) => (sel === 'a[href]' ? {} : null) } })
  assert.equal(dom.posts.length, before)
  item.dispatch('click')
  assert.deepEqual(dom.posts.at(-1).body, { token: 'L', action: 'select', index: 1 })
  dom.send('context:close', {})
})

test('icons: Font Awesome names resolve, an unknown word draws nothing and is reported once', async () => {
  const { icon } = await import('../../web/js/core.js')
  for (const name of ['house', 'fa-solid fa-gear', 'fas fa-box', 'magnifying-glass', 'circle-check', 'hand']) {
    const el = icon(name)
    assert.ok(el && el.tagName === 'SVG', `${name} is a built-in icon`)
  }
  assert.equal(icon('OK'), null, 'a short ASCII word is not drawn as text')
  const before = dom.posts.filter((p) => p.name === 'warn').length
  assert.equal(icon('spaceship'), null)
  assert.equal(icon('fa-spaceship'), null)
  const warns = dom.posts.filter((p) => p.name === 'warn')
  assert.equal(warns.length, before + 1, 'reported once per name')
  assert.match(warns.at(-1).body.message, /spaceship/)
  const emoji = icon('🔧')
  assert.ok(emoji && emoji.tagName === 'SPAN', 'an emoji is still drawn')
})

test('theme: a colour key that is not a colour token is ignored', () => {
  dom.send('theme', { colors: { place: '#fff', p: '#000', surface: '#123456' } })
  const style = dom.doc.documentElement.style._map
  assert.equal(style.has('--cis-place'), false)
  assert.equal(style.has('--cis-p'), false)
  assert.equal(style.get('--cis-surface'), '#123456')
})

test('progress: a bar reports how far it is, not 0 until it ends', async () => {
  dom.send('progress:start', { kind: 'bar', label: 'Work', duration: 400 })
  const bar = everything().find((n) => n.nodeType === 1 && n.getAttribute('role') === 'progressbar' && !(n.className || '').includes('cis-leave'))
  await new Promise((r) => setTimeout(r, 300))
  assert.ok(Number(bar.getAttribute('aria-valuenow')) > 0, `aria-valuenow is ${bar.getAttribute('aria-valuenow')}`)
  dom.send('progress:stop', {})
})
