// Browser plumbing: the NUI bridge, an element builder, icons, locale, theme.
// User strings only ever reach the page through textContent / text nodes.
import { buildDom, parseMarkdown, parseLine, safeUrl } from './markdown.js'

const RESOURCE = typeof window.GetParentResourceName === 'function' ? window.GetParentResourceName() : 'cis_libs'

export function post(name, data = {}) {
  return fetch(`https://${RESOURCE}/${name}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
    body: JSON.stringify(data),
  }).then((r) => (r.ok ? r.json().catch(() => null) : null)).catch(() => null)
}

const handlers = new Map()
export const on = (action, fn) => handlers.set(action, fn)

window.addEventListener('message', (e) => {
  const m = e.data
  const fn = m && typeof m === 'object' && handlers.get(m.action)
  if (!fn) return
  try { fn(m.data && typeof m.data === 'object' ? m.data : {}) } catch (err) { reportError(err) }
})

export function reportError(err) {
  post('error', { message: String((err && (err.stack || err.message)) || err).slice(0, 1000) })
}
window.addEventListener('error', (e) => reportError(e.error || e.message))
window.addEventListener('unhandledrejection', (e) => reportError(e.reason))

// h(tag, { class, text, onX, style, attr }, ...kids). Keys are ours; values
// become text, properties or attributes, never markup.
export function h(tag, props, ...kids) {
  const el = document.createElement(tag)
  for (const k of Object.keys(props || {})) {
    const v = props[k]
    if (v === undefined || v === null || v === false) continue
    if (k === 'class') el.className = v
    else if (k === 'text') el.textContent = String(v)
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v)
    else if (k === 'style') for (const s of Object.keys(v)) el.style.setProperty(s, v[s])
    else el.setAttribute(k, v === true ? '' : String(v))
  }
  for (const c of kids.flat(4)) if (c !== undefined && c !== null && c !== false) el.append(c instanceof Node ? c : String(c))
  return el
}

export const markdown = (el, text) => buildDom(parseMarkdown(text), document, el)
export const inline = (el, text) => buildDom(parseLine(text), document, el)

// Links never navigate the NUI frame; the game opens them externally if it can.
document.addEventListener('click', (e) => {
  const a = e.target instanceof Element && e.target.closest('a[href]')
  if (!a) return
  e.preventDefault()
  const href = safeUrl(a.getAttribute('href'))
  if (href && /^https?:/i.test(href) && typeof window.invokeNative === 'function') window.invokeNative('openUrl', href)
})

// Built-in 24px stroke icons, else an image URL, else <= 4 chars (emoji).
const ICONS = {
  info: 'M12 16v-5M12 8h.01M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z',
  check: 'M5 12.5l4.5 4.5L19 7.5',
  warning: 'M12 9v4M12 17h.01M10.3 3.9L2 18a2 2 0 0 0 1.7 3h16.6a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z',
  error: 'M15 9l-6 6M9 9l6 6M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z',
  x: 'M6 6l12 12M18 6L6 18',
  'chevron-right': 'M9 6l6 6-6 6',
  'chevron-left': 'M15 6l-6 6 6 6',
  circle: 'M12 7a5 5 0 1 0 0 10 5 5 0 0 0 0-10z',
  user: 'M20 21a8 8 0 0 0-16 0M12 3a5 5 0 1 0 0 10 5 5 0 0 0 0-10z',
  car: 'M5 17h14M3 13l2-6h14l2 6v5H3zM7 17v2M17 17v2',
  lock: 'M6 11h12v10H6zM8 11V7a4 4 0 0 1 8 0v4',
  key: 'M14 10a4 4 0 1 0-1.2 2.8L21 21M17 17l2-2',
}
const ALIAS = { inform: 'info', success: 'check', 'circle-check': 'check', xmark: 'x', close: 'x' }
const NS = 'http://www.w3.org/2000/svg'
export const svg = (tag, attrs) => {
  const el = document.createElementNS(NS, tag)
  for (const k of Object.keys(attrs)) el.setAttribute(k, String(attrs[k]))
  return el
}
export const imageUrl = (v) => (typeof v === 'string' && /^(?:nui:\/\/|https?:\/\/|\.\.?\/)[^\s"'<>`\\]+$/i.test(v) ? v : null)

export function icon(name, color) {
  if (typeof name !== 'string' || !name) return null
  const key = name.split(' ').pop().replace(/^fa-/, '')
  const d = ICONS[ALIAS[key] || key]
  let el
  if (d) {
    el = svg('svg', { viewBox: '0 0 24 24', class: 'cis-icon' })
    el.appendChild(svg('path', { d }))
  } else if (imageUrl(name)) el = h('img', { class: 'cis-icon', src: name, alt: '' })
  else if ([...name].length <= 4) el = h('span', { class: 'cis-icon', text: name })
  else return null
  el.setAttribute('aria-hidden', 'true')
  if (typeof color === 'string') el.style.color = color
  return el
}

const LOCALE = {
  confirm: 'Confirm', cancel: 'Cancel', close: 'Close', back: 'Back', more: 'More',
  notifications: 'Notifications', progressCancel: 'Press X to cancel',
  required: 'This field is required', invalid: 'Invalid value', invalidNumber: 'Enter a number',
  min: 'Must be at least {n}', max: 'Must be at most {n}', minLength: 'At least {n} characters',
  maxLength: 'At most {n} characters', maxSelected: 'Select at most {n}', invalidColor: 'Use a colour like #ff8800',
  invalidDate: 'Enter a valid date', minDate: 'On or after {n}', maxDate: 'On or before {n}',
  invalidRange: 'The start must not be after the end', from: 'From', to: 'To', pressKey: 'Press {key}',
}
const strings = { ...LOCALE }

export function t(key, params) {
  const s = strings[key] ?? key
  return params ? s.replace(/\{(\w+)\}/g, (m, k) => (k in params ? String(params[k]) : m)) : s
}

export function setLocale(table) {
  for (const k of Object.keys(LOCALE)) {
    const v = table && table[k]
    if (typeof v === 'string' && v.length <= 200) strings[k] = v
  }
}

const settings = { notifyPosition: 'top-right', textUIPosition: 'right-center', progressPosition: 'bottom', menuPosition: 'top-left', notifyMax: 5 }
export const setting = (key) => settings[key]
const COLOR = /^(#[0-9a-f]{3,8}|(rgb|hsl)a?\([\d\s.,%deg/]+\)|[a-z]{3,20})$/i
const root = document.documentElement
const dark = window.matchMedia('(prefers-color-scheme: dark)')
const paintMode = () => root.classList.toggle('cis-light', root.dataset.theme === 'light' || (root.dataset.theme === 'auto' && !dark.matches))
dark.addEventListener?.('change', paintMode)

export function setTheme(th) {
  if (!th || typeof th !== 'object') return
  const css = (k, v) => root.style.setProperty(`--cis-${k}`, v)
  if (typeof th.accent === 'string' && COLOR.test(th.accent)) css('accent', th.accent)
  if (typeof th.radius === 'number') css('radius', `${Math.min(32, Math.max(0, th.radius))}px`)
  if (typeof th.fontScale === 'number') css('scale', String(Math.min(1.5, Math.max(0.75, th.fontScale))))
  if (['light', 'dark', 'auto'].includes(th.mode)) root.dataset.theme = th.mode
  if (typeof th.reducedMotion === 'boolean') root.classList.toggle('cis-reduced-motion', th.reducedMotion)
  for (const [k, v] of Object.entries(th.colors && typeof th.colors === 'object' ? th.colors : {})) {
    if (/^[a-z][a-z0-9-]{0,30}$/.test(k) && typeof v === 'string' && COLOR.test(v)) css(k, v)
  }
  for (const k of Object.keys(settings)) if (typeof th[k] === typeof settings[k]) settings[k] = th[k]
  paintMode()
}

export const layer = (id) => document.getElementById(id)

export const focusables = (el) => [...el.querySelectorAll('button,[href],input,select,textarea,[tabindex]:not([tabindex="-1"])')]
  .filter((x) => !x.disabled && !x.hidden && x.offsetParent !== null)

export const reducedMotion = () => root.classList.contains('cis-reduced-motion')
  || window.matchMedia('(prefers-reduced-motion: reduce)').matches

export function leave(el) {
  if (!el) return
  if (reducedMotion()) return el.remove()
  el.classList.add('cis-leave')
  setTimeout(() => el.remove(), 180)
}

export const pct = (v) => `${Math.max(0, Math.min(100, Number(v) || 0))}%`
