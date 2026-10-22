// A deliberately small DOM: enough for web/js to build its elements under
// `node --test`, with no dependency. It has NO HTML parser, so the only way
// markup can appear in it is an element the code created on purpose -- which
// is exactly what the XSS tests inspect. (innerHTML and friends are banned by
// a separate static scan, because a fake without a parser cannot catch them.)

export class FakeNode {
  constructor(doc) { this.ownerDocument = doc; this.parentNode = null; this.childNodes = [] }
  get firstChild() { return this.childNodes[0] || null }
  get textContent() { return this.childNodes.map((c) => c.textContent).join('') }
  set textContent(v) { this.replaceChildren(); if (v !== '') this.appendChild(this.ownerDocument.createTextNode(String(v))) }
  appendChild(c) { if (c.parentNode) c.remove(); c.parentNode = this; this.childNodes.push(c); return c }
  append(...cs) { for (const c of cs) this.appendChild(c instanceof FakeNode ? c : this.ownerDocument.createTextNode(String(c))) }
  prepend(...cs) {
    for (const c of cs.reverse()) {
      const n = c instanceof FakeNode ? c : this.ownerDocument.createTextNode(String(c))
      if (n.parentNode) n.remove()
      n.parentNode = this
      this.childNodes.unshift(n)
    }
  }
  replaceChildren(...cs) { for (const c of [...this.childNodes]) c.remove(); this.append(...cs) }
  remove() { if (!this.parentNode) return; const p = this.parentNode; p.childNodes = p.childNodes.filter((c) => c !== this); this.parentNode = null }
  replaceWith(n) { const p = this.parentNode; if (!p) return; const i = p.childNodes.indexOf(this); this.remove(); n.parentNode = p; p.childNodes.splice(i, 0, n) }
}

export class FakeText extends FakeNode {
  constructor(doc, text) { super(doc); this.nodeType = 3; this.data = text }
  get textContent() { return this.data }
  set textContent(v) { this.data = String(v) }
}

export class FakeElement extends FakeNode {
  constructor(doc, tag, ns) {
    super(doc)
    this.nodeType = 1
    this.tagName = tag.toUpperCase()
    this.namespaceURI = ns || 'http://www.w3.org/1999/xhtml'
    this.attributes = new Map()
    this.listeners = {}
    this.dataset = {}
    const styles = new Map()
    this.style = { setProperty: (k, v) => styles.set(k, v), getPropertyValue: (k) => styles.get(k) ?? '', _map: styles }
    const self = this
    this.classList = {
      add: (...c) => { const s = new Set(self.className.split(' ').filter(Boolean)); c.forEach((x) => s.add(x)); self.className = [...s].join(' ') },
      remove: (...c) => { self.className = self.className.split(' ').filter((x) => x && !c.includes(x)).join(' ') },
      toggle: (c, on) => { const has = self.classList.contains(c); const want = on === undefined ? !has : on; if (want) self.classList.add(c); else self.classList.remove(c); return want },
      contains: (c) => self.className.split(' ').includes(c),
    }
    this.className = ''
  }
  // Reflected boolean attributes, as in a real DOM.
  get hidden() { return this.attributes.has('hidden') }
  set hidden(v) { if (v) this.attributes.set('hidden', ''); else this.attributes.delete('hidden') }
  get disabled() { return this.attributes.has('disabled') }
  set disabled(v) { if (v) this.attributes.set('disabled', ''); else this.attributes.delete('disabled') }
  setAttribute(k, v) { this.attributes.set(String(k), String(v)); if (k === 'class') this.className = String(v) }
  getAttribute(k) { return k === 'class' ? this.className : (this.attributes.has(k) ? this.attributes.get(k) : null) }
  removeAttribute(k) { this.attributes.delete(k) }
  hasAttribute(k) { return this.attributes.has(k) }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn) }
  dispatch(type, event = {}) {
    const e = { type, target: this, currentTarget: this, preventDefault() { this.defaultPrevented = true }, ...event }
    for (const fn of this.listeners[type] || []) fn(e)
    return e
  }
  focus() { this.ownerDocument.activeElement = this }
  scrollIntoView() {}
  getBoundingClientRect() { return { left: 0, top: 0, width: 300, height: 300 } }
  get offsetParent() { return this.parentNode }
  matches(sel) { return sel.split(',').some((s) => s.trim().toUpperCase() === this.tagName || (s.includes('role=listbox') && this.getAttribute('role') === 'listbox')) }
  closest() { return null }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null }
  querySelectorAll(sel) {
    const out = []
    const walk = (n) => { for (const c of n.childNodes) { if (c instanceof FakeElement) { if (c.matches(sel)) out.push(c); walk(c) } } }
    walk(this)
    return out
  }
  get id() { return this.getAttribute('id') }
}

export function installDom() {
  const listeners = {}
  const posts = []
  const doc = {
    activeElement: null,
    listeners: {},
    createElement: (t) => new FakeElement(doc, t),
    createElementNS: (ns, t) => new FakeElement(doc, t, ns),
    createTextNode: (s) => new FakeText(doc, s),
    addEventListener: (type, fn) => { (doc.listeners[type] ||= []).push(fn) },
    querySelector: () => null,
    getElementById: (id) => {
      doc.layers[id] ||= new FakeElement(doc, 'div')
      return doc.layers[id]
    },
    layers: {},
  }
  doc.documentElement = new FakeElement(doc, 'html')
  globalThis.document = doc
  globalThis.Node = FakeNode
  globalThis.Element = FakeElement
  globalThis.window = {
    addEventListener: (type, fn) => { (listeners[type] ||= []).push(fn) },
    matchMedia: () => ({ matches: false }),
    GetParentResourceName: () => 'cis_libs',
  }
  // The NUI root posts into this frame: `parent` is where game messages come from.
  globalThis.window.parent = { root: true }
  globalThis.requestAnimationFrame = () => 0
  globalThis.cancelAnimationFrame = () => {}
  globalThis.fetch = (url, init) => {
    posts.push({ name: String(url).split('/').pop(), body: JSON.parse(init.body) })
    return Promise.resolve({ ok: true, json: () => Promise.resolve({ ok: true }) })
  }
  return {
    doc,
    posts,
    send(action, data) { for (const fn of listeners.message || []) fn({ data: { action, data }, source: globalThis.window.parent }) },
    // A message from somewhere that is not the game: another resource's frame.
    sendFrom(source, action, data) { for (const fn of listeners.message || []) fn({ data: { action, data }, source }) },
    keydown(key, extra = {}) {
      const e = { key, preventDefault() {}, ...extra }
      for (const fn of doc.listeners.keydown || []) fn(e)
    },
  }
}

// Every element and text node under `root`.
export function walk(root, visit) {
  for (const c of root.childNodes) {
    visit(c)
    walk(c, visit)
  }
}
