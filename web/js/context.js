import { h, icon, imageUrl, inline, on, post, t, layer, pct, raise } from './core.js'
import { step, first, last, keyIntent } from './nav.js'

// Reports an index only; Lua decides what it does (no event names here).
let current = null

const meta = (list) => Array.isArray(list) && list.length > 0 && h('dl', { class: 'cis-meta' }, list.map((m) => [
  h('dt', { text: m.label ?? '' }),
  h('dd', { text: m.value ?? '' }, typeof m.progress === 'number' && h('span', { class: 'cis-bar', style: { '--cis-p': pct(m.progress) } })),
]))

on('context:open', (d) => {
  current?.remove()
  const opts = Array.isArray(d.options) ? d.options : []
  const send = (action, i) => post('context', i === undefined ? { token: d.token, action } : { token: d.token, action, index: i + 1 })
  const usable = (i) => !opts[i].disabled && !opts[i].readOnly
  const skip = (i) => !!opts[i].disabled
  const aside = h('aside', { class: 'cis-context-meta', hidden: true })
  let active = first(opts.length, skip)
  const items = opts.map((o, i) => h('button', {
    class: 'cis-item', type: 'button', role: 'menuitem', tabindex: -1,
    'data-scheme': o.colorScheme,
    'aria-disabled': o.disabled && 'true', 'aria-haspopup': o.hasMenu && 'menu',
    // A markdown link in the description opens externally (core.js); it is
    // not also a pick of the option it sits in.
    onclick: (e) => !(e && e.target && e.target.closest && e.target.closest('a[href]')) && usable(i) && send('select', i),
    onmouseenter: () => items[i].focus(),
    onfocus: () => {
      active = i
      const img = imageUrl(o.image)
      const m = meta(o.metadata)
      aside.replaceChildren(...[img && h('img', { src: img, alt: '' }), m].filter(Boolean))
      aside.hidden = !img && !m
    },
  }, icon(o.icon, o.iconColor), h('span', { class: 'cis-text' },
    inline(h('span', { class: 'cis-md' }), o.title),
    o.description && inline(h('span', { class: 'cis-md' }), o.description),
    typeof o.progress === 'number' && h('span', { class: 'cis-bar', style: { '--cis-p': pct(o.progress) } }),
  ), (o.arrow || o.hasMenu) && icon('chevron-right')))
  const focus = (i) => i >= 0 && items[i].focus()
  const list = h('div', {
    class: 'cis-list', role: 'menu', 'aria-labelledby': 'cis-context-title',
    onkeydown: (e) => {
      const intent = keyIntent(e.key)
      if (intent === 'next' || intent === 'prev') focus(step(items.length, active, intent === 'next' ? 1 : -1, skip))
      else if (intent === 'first' || intent === 'last') focus((intent === 'first' ? first : last)(items.length, skip))
      else if ((intent === 'back' || intent === 'left') && d.hasBack) send('back')
      else if (intent === 'right' && opts[active]?.hasMenu && usable(active)) send('select', active)
      else return
      e.preventDefault()
    },
  }, items)
  const head = h('div', { class: 'cis-head' },
    d.hasBack && h('button', { class: 'cis-iconbtn', type: 'button', 'aria-label': t('back'), onclick: () => send('back') }, icon('chevron-left')),
    h('h2', { id: 'cis-context-title', text: d.title ?? '' }),
    d.canClose !== false && h('button', { class: 'cis-iconbtn', type: 'button', 'aria-label': t('close'), onclick: () => send('close') }, icon('x')))
  current = h('div', { class: 'cis-context cis-anim' }, h('div', { class: 'cis-context-panel' }, head, list), aside)
  layer('cis-context').appendChild(current)
  raise('cis-context')
  if (active >= 0) focus(active)
  else (head.querySelector('button') || list).focus()
})

on('context:close', () => {
  current?.remove()
  current = null
})
