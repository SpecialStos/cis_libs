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

// FROM THE GAME ONLY. SendNuiMessage arrives from the NUI root (this frame's
// parent) or, in a plain browser, from this window. Another resource's frame
// can postMessage into this one, and was able to draw a fake dialog or stop a
// skill check; its messages have a different source and are dropped.
export const fromGame = (e) => e.source === window.parent || e.source === window

window.addEventListener('message', (e) => {
  if (!fromGame(e)) return
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

// Built-in 24px stroke icons, else an image URL, else <= 4 non-ASCII chars
// (an emoji). Font Awesome names, as ox_lib callers write them ('house',
// 'fa-solid fa-gear', { 'fas', 'box' } -- Lua passes the last string), resolve
// through ALIAS. A word that names no icon draws nothing and is reported once:
// it used to be drawn as the word itself.
const ICONS = {
  hand: 'M8 13V5a1.5 1.5 0 0 1 3 0v6M11 10V3.5a1.5 1.5 0 0 1 3 0V10M14 10V5a1.5 1.5 0 0 1 3 0v7M17 9a1.5 1.5 0 0 1 3 0v4a8 8 0 0 1-8 8h-1a7 7 0 0 1-6-3.5L3 14a1.5 1.5 0 0 1 2.5-1.5L8 15',
  gear: 'M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9L7 7M17 17l2.1 2.1M4.9 19.1L7 17M17 7l2.1-2.1',
  bars: 'M4 6h16M4 12h16M4 18h16',
  bolt: 'M13 2L4 14h7l-1 8 9-12h-7z',
  house: 'M3 11l9-8 9 8M5 9.5V21h14V9.5M10 21v-6h4v6',
  box: 'M3 7l9-4 9 4v10l-9 4-9-4zM3 7l9 4 9-4M12 11v10',
  hashtag: 'M5 9h15M4 15h15M10 3L8 21M16 3l-2 18',
  calendar: 'M4 5h16v16H4zM4 10h16M8 3v4M16 3v4',
  clock: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 7v5l3 2',
  dollar: 'M12 2v20M17 6H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6',
  phone: 'M5 3h4l2 5-2.5 1.5a11 11 0 0 0 6 6L16 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 5a2 2 0 0 1 2-2',
  envelope: 'M3 5h18v14H3zM3 6l9 7 9-7',
  location: 'M12 21s-7-6.5-7-12a7 7 0 0 1 14 0c0 5.5-7 12-7 12zM12 6.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5z',
  map: 'M9 4L3 6v14l6-2 6 2 6-2V4l-6 2zM9 4v14M15 6v14',
  truck: 'M2 6h12v10H2zM14 9h4l3 3v4h-7M6.5 16a2 2 0 1 0 0 4 2 2 0 0 0 0-4zM17.5 16a2 2 0 1 0 0 4 2 2 0 0 0 0-4z',
  wrench: 'M15 3a6 6 0 0 0-5.6 8.2L3 17.6V21h3.4l6.4-6.4A6 6 0 0 0 21 9l-3.5 3.5-3-3L18 6a6 6 0 0 0-3-3z',
  trash: 'M4 7h16M9 7V4h6v3M6 7l1 14h10l1-14M10 11v6M14 11v6',
  pen: 'M4 20h4L19 9l-4-4L4 16zM14 6l4 4',
  plus: 'M12 5v14M5 12h14',
  minus: 'M5 12h14',
  search: 'M10.5 4a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13zM15.5 15.5L21 21',
  star: 'M12 3l2.8 5.8 6.2.9-4.5 4.4 1 6.3L12 17.5 6.5 20.4l1-6.3L3 9.7l6.2-.9z',
  heart: 'M12 20s-8-5.3-8-11a4.5 4.5 0 0 1 8-2.8A4.5 4.5 0 0 1 20 9c0 5.7-8 11-8 11z',
  shield: 'M12 3l8 3v6c0 4.5-3.4 8.2-8 9-4.6-.8-8-4.5-8-9V6z',
  eye: 'M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12zM12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z',
  bell: 'M6 16v-5a6 6 0 0 1 12 0v5l2 2H4zM10 20a2 2 0 0 0 4 0',
  list: 'M9 6h11M9 12h11M9 18h11M4 6h.01M4 12h.01M4 18h.01',
  door: 'M4 21h16M6 21V3h9v18M15 5l4 1v15M11 12h.01',
  'arrow-right': 'M5 12h14M13 6l6 6-6 6',
  'arrow-left': 'M19 12H5M11 6l-6 6 6 6',
  'arrow-up': 'M12 19V5M6 11l6-6 6 6',
  'arrow-down': 'M12 5v14M6 13l6 6 6-6',
  cart: 'M3 4h2l2.5 11h11L21 7H6.2M9 19h.01M18 19h.01',
  gun: 'M3 8h17v4h-6l-1 3h-3l-.5 2H5l1.5-5H3z',
  'id-card': 'M3 5h18v14H3zM7 10a2 2 0 1 0 4 0 2 2 0 0 0-4 0M6 16a3 3 0 0 1 6 0M14 10h4M14 14h4',
  briefcase: 'M3 7h18v13H3zM8 7V4h8v3M3 12h18',
  fuel: 'M4 21V4h9v17M3 21h11M4 10h9M13 8l4 3v7a1.5 1.5 0 0 0 3 0V9l-3-3',
  utensils: 'M6 3v8a2 2 0 0 0 2 2v8M10 3v8a2 2 0 0 1-2 2M8 3v6M17 21V3c-2 1-3 4-3 8h3',
  shirt: 'M8 4L3 7l2 4 2-1v10h10V10l2 1 2-4-5-3a4 4 0 0 1-8 0z',
  users: 'M16 20a6 6 0 0 0-12 0M10 4a4 4 0 1 0 0 8 4 4 0 0 0 0-8M22 20a5 5 0 0 0-5-5M16 4.5a3.5 3.5 0 0 1 0 7',
  question: 'M9.5 9a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .9-1 1.7v.5M12 17h.01M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z',
  ban: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM5.6 5.6l12.8 12.8',
  unlock: 'M6 11h12v10H6zM8 11V7a4 4 0 0 1 7.5-2',
  power: 'M12 3v9M6.3 6.3a8 8 0 1 0 11.4 0',
  rotate: 'M20 11a8 8 0 0 0-14.5-4.5L4 8M4 4v4h4M4 13a8 8 0 0 0 14.5 4.5L20 16M20 20v-4h-4',
  copy: 'M8 8h12v12H8zM16 8V4H4v12h4',
  send: 'M21 3L3 10l7 3 3 7zM10 13L21 3',
  building: 'M5 21V3h14v18M3 21h18M9 7h.01M15 7h.01M9 11h.01M15 11h.01M9 15h.01M15 15h.01',
  tag: 'M3 3h8l10 10-8 8L3 11zM7.5 7.5h.01',
  fire: 'M12 21a6 6 0 0 0 6-6c0-4-3-6-4-10-2 2-3 4-3 6-1-1-2-2-2-4-2 2-3 5-3 8a6 6 0 0 0 6 6z',
  ellipsis: 'M5 12h.01M12 12h.01M19 12h.01',
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
const ALIAS = {
  inform: 'info', 'circle-info': 'info', 'info-circle': 'info',
  success: 'check', 'circle-check': 'check', 'check-circle': 'check', 'square-check': 'check',
  xmark: 'x', close: 'x', times: 'x', 'circle-xmark': 'error', 'times-circle': 'error',
  'triangle-exclamation': 'warning', 'exclamation-triangle': 'warning', 'circle-exclamation': 'warning',
  home: 'house', 'house-chimney': 'house', 'house-user': 'house',
  cog: 'gear', gears: 'gear', sliders: 'gear',
  'magnifying-glass': 'search',
  'location-dot': 'location', 'map-marker': 'location', 'map-pin': 'location', 'location-pin': 'location',
  'dollar-sign': 'dollar', money: 'dollar', 'money-bill': 'dollar', 'money-bill-wave': 'dollar', wallet: 'dollar', 'sack-dollar': 'dollar',
  'cart-shopping': 'cart', 'shopping-cart': 'cart', 'basket-shopping': 'cart', bag: 'cart',
  pencil: 'pen', edit: 'pen', 'pen-to-square': 'pen',
  'trash-can': 'trash',
  'user-group': 'users', 'people-group': 'users',
  'id-badge': 'id-card', 'address-card': 'id-card',
  burger: 'utensils', hamburger: 'utensils', 'pizza-slice': 'utensils', 'mug-hot': 'utensils',
  tshirt: 'shirt',
  'person-rifle': 'gun',
  'circle-question': 'question',
  'phone-flip': 'phone', mobile: 'phone', 'mobile-screen': 'phone',
  message: 'envelope', comment: 'envelope', comments: 'envelope',
  'screwdriver-wrench': 'wrench', toolbox: 'wrench', hammer: 'wrench',
  'arrows-rotate': 'rotate', 'rotate-right': 'rotate', refresh: 'rotate', sync: 'rotate',
  'door-open': 'door', 'door-closed': 'door', 'right-from-bracket': 'door', 'sign-out': 'door',
  'car-side': 'car', taxi: 'car', 'truck-fast': 'truck', 'van-shuttle': 'truck',
  'lock-open': 'unlock',
  'heart-pulse': 'heart', 'kit-medical': 'heart', 'briefcase-medical': 'heart', 'suitcase-medical': 'heart',
  'shield-halved': 'shield', 'shield-alt': 'shield',
  'gas-pump': 'fuel',
  hands: 'hand', 'hand-holding': 'hand', handshake: 'hand',
  city: 'building', store: 'building', shop: 'building',
  tags: 'tag', 'fire-flame-curved': 'fire', 'bolt-lightning': 'bolt', zap: 'bolt',
  'box-open': 'box', boxes: 'box', 'box-archive': 'box', cube: 'box', cubes: 'box',
  'calendar-days': 'calendar', 'calendar-day': 'calendar', hourglass: 'clock', stopwatch: 'clock',
  'paper-plane': 'send', 'power-off': 'power', 'list-ul': 'list', 'ellipsis-vertical': 'ellipsis',
  'user-tie': 'user', 'circle-user': 'user', 'user-shield': 'shield',
}
const warned = new Set()
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
  else if ([...name].length <= 4 && !/[\u0000-\u007f]/.test(name)) el = h('span', { class: 'cis-icon', text: name })
  else {
    if (!warned.has(key) && warned.size < 64) { warned.add(key); post('warn', { message: `unknown icon ${key.slice(0, 64)}` }) }
    return null
  }
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
// The colour tokens style.css reads (client/interface/theme.lua checks the same
// list); any other name could overwrite a layout variable such as --cis-place.
const COLOR_KEYS = new Set(['accent', 'accent-fg', 'bg', 'surface', 'hover', 'border', 'fg', 'muted', 'backdrop', 'inform', 'success', 'warning', 'error'])
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
    if (COLOR_KEYS.has(k) && typeof v === 'string' && COLOR.test(v)) css(k, v)
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
