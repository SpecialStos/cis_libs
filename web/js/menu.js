import { h, icon, on, setting, layer, pct } from './core.js'

// List menu: driven from Lua (the game keeps focus); this only draws state.
const WINDOW = 7
let m = null

function render() {
  const total = m.options.length
  const sel = Math.min(Math.max(1, m.selected), Math.max(1, total)) - 1
  const start = Math.max(0, Math.min(sel - 3, total - WINDOW))
  const rows = m.options.slice(start, start + WINDOW).map((o, k) => {
    const values = Array.isArray(o.values) && o.values.length ? o.values : null
    const right = values
      ? h('span', { class: 'cis-values', text: `‹ ${values[Math.min(values.length, Math.max(1, o.scrollIndex || 1)) - 1]?.label ?? ''} ›` })
      : typeof o.checked === 'boolean' && h('span', { class: `cis-box${o.checked ? ' cis-on' : ''}`, role: 'img', 'aria-label': o.checked ? 'on' : 'off' })
    const active = start + k === sel
    return h('li', { class: active && 'cis-active', role: 'option', 'aria-selected': String(active), 'data-scheme': o.colorScheme },
      icon(o.icon, o.iconColor),
      h('span', { class: 'cis-text' }, h('span', { text: o.label ?? '' }), typeof o.progress === 'number' && h('span', { class: 'cis-bar', style: { '--cis-p': pct(o.progress) } })),
      right)
  })
  const cur = m.options[sel]
  const desc = cur && ((Array.isArray(cur.values) && cur.values[(cur.scrollIndex || 1) - 1]?.description) || cur.description)
  m.el.replaceChildren(...[
    h('div', { class: 'cis-head' }, h('h2', { text: m.title }), h('span', { text: total ? `${sel + 1}/${total}` : '' })),
    h('ul', { role: 'listbox', 'aria-label': m.title }, rows),
    desc && h('div', { class: 'cis-desc', text: desc }),
  ].filter(Boolean))
}

on('menu:open', (d) => {
  m?.el.remove()
  m = { title: String(d.title ?? ''), options: Array.isArray(d.options) ? d.options : [], selected: Number(d.selected) || 1, el: h('div', { class: 'cis-menu cis-anim', 'data-pos': d.position || setting('menuPosition') }) }
  layer('cis-menu').appendChild(m.el)
  render()
})

on('menu:state', (d) => {
  if (!m) return
  if (Array.isArray(d.options)) m.options = d.options
  const o = m.options[(Number(d.index) || 0) - 1]
  if (o && typeof d.scrollIndex === 'number') o.scrollIndex = d.scrollIndex
  if (o && typeof d.checked === 'boolean') o.checked = d.checked
  if (typeof d.selected === 'number') m.selected = d.selected
  render()
})

on('menu:close', () => {
  m?.el.remove()
  m = null
})
