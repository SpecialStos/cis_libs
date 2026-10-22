import { h, icon, markdown, on, post, t, focusables, layer } from './core.js'
import { normalizeRow, initialValue, coerce, validateAll, resultValues } from './validate.js'
import { trapTab, step, keyIntent } from './nav.js'

// Alert and input dialogs: modal, focus-trapped, Escape handled by Lua.
const open = new Map() // kind -> { id, el }
const label = (labels, key) => (typeof labels?.[key] === 'string' && labels[key]) || t(key)
const btn = (text, onclick, primary) => h('button', { class: primary ? 'cis-btn cis-primary' : 'cis-btn', type: 'button', onclick }, text)

function modal(kind, d, title, body, buttons) {
  close(kind)
  const tid = `cis-${kind}-title`
  const size = ['xs', 'sm', 'lg', 'xl'].includes(d.size) ? ` cis-size-${d.size}` : ''
  const dialog = h('div', {
    class: `cis-dialog cis-anim${size}${d.centered ? ' cis-centered' : ''}`,
    role: kind === 'alert' ? 'alertdialog' : 'dialog', 'aria-modal': 'true', 'aria-labelledby': tid,
    onkeydown: (e) => {
      if (e.key !== 'Tab') return
      const stops = focusables(dialog)
      const next = trapTab(stops.length, stops.indexOf(document.activeElement), e.shiftKey)
      if (next >= 0) { e.preventDefault(); stops[next].focus() }
    },
  }, h('h2', { id: tid, text: title }), body, h('div', { class: 'cis-actions' }, buttons))
  const el = h('div', { class: 'cis-backdrop' }, dialog)
  layer('cis-dialogs').appendChild(el)
  open.set(kind, { id: d.id, el })
}

function close(kind, id) {
  const cur = open.get(kind)
  if (!cur || (id !== undefined && cur.id !== id)) return
  open.delete(kind)
  cur.el.remove()
}

on('alert:open', (d) => {
  const answer = (result) => { close('alert', d.id); post('alert', { id: d.id, result }) }
  const ok = btn(label(d.labels, 'confirm'), () => answer('confirm'), true)
  modal('alert', d, String(d.header ?? ''), markdown(h('div', { class: 'cis-body cis-md' }), d.content),
    [d.cancel && btn(label(d.labels, 'cancel'), () => answer('cancel')), ok])
  ok.focus()
})
on('alert:close', (d) => close('alert', d.id))

// A listbox, not <select>: CEF off-screen rendering may not draw popups.
function listbox(r, id, value, set) {
  const multi = r.type === 'multi-select'
  const has = (v) => (multi ? value.includes(v) : value === v)
  let active = Math.max(0, r.options.findIndex((o) => has(o.value)))
  const items = r.options.map((o, i) => h('div', { class: 'cis-option', role: 'option', id: `${id}-o${i}`, onclick: () => { active = i; pick() } }, o.label))
  const box = h('div', {
    class: 'cis-listbox', role: 'listbox', id, tabindex: r.disabled ? -1 : 0,
    'aria-multiselectable': multi && 'true', 'aria-disabled': r.disabled && 'true',
    onkeydown: (e) => {
      const intent = keyIntent(e.key)
      if (intent === 'next' || intent === 'prev') active = step(items.length, active, intent === 'next' ? 1 : -1, () => false, false)
      else if (intent === 'first' || intent === 'last') active = intent === 'first' ? 0 : items.length - 1
      else if (intent === 'activate') pick()
      else return
      e.preventDefault()
      paint()
    },
  }, items)
  function paint() {
    items.forEach((el, i) => {
      el.setAttribute('aria-selected', String(has(r.options[i].value)))
      el.classList.toggle('cis-active', i === active)
    })
    if (items[active]) { box.setAttribute('aria-activedescendant', items[active].id); items[active].scrollIntoView({ block: 'nearest' }) }
  }
  function pick() {
    if (r.disabled || !items[active]) return
    const v = r.options[active].value
    if (multi) value = has(v) ? value.filter((x) => x !== v) : [...value, v]
    else value = value === v && !r.required ? null : v
    set(value)
    paint()
  }
  paint()
  return box
}

function control(r, id, value, set) {
  const base = { id, disabled: r.disabled, 'aria-required': r.required && 'true' }
  const input = (props) => h('input', { ...base, oninput: (e) => set(e.target.value), ...props })
  switch (r.type) {
    case 'checkbox': return input({ type: 'checkbox', checked: value, oninput: null, onchange: (e) => set(e.target.checked) })
    case 'number': return input({ type: 'number', inputmode: 'decimal', value: value ?? '', placeholder: r.placeholder, min: r.min, max: r.max, step: r.step ?? 'any' })
    case 'slider': {
      const out = h('output', { for: id, text: value })
      return h('div', { class: 'cis-slider' }, input({ type: 'range', min: r.min, max: r.max, step: r.step ?? 1, value, oninput: (e) => { out.textContent = e.target.value; set(e.target.value) } }), out)
    }
    case 'select': case 'multi-select': return listbox(r, id, value, set)
    case 'color': {
      const swatch = h('span', { class: 'cis-swatch', 'aria-hidden': 'true' })
      const paint = (v) => { swatch.style.background = /^#[0-9a-f]{3,6}$/i.test(v) ? v : 'transparent' }
      paint(value)
      return h('div', { class: 'cis-color' }, swatch, input({ type: 'text', value, placeholder: '#rrggbb', maxlength: 7, spellcheck: 'false', oninput: (e) => { paint(e.target.value); set(e.target.value) } }))
    }
    case 'date': return input({ type: 'date', value, min: r.min, max: r.max })
    case 'time': return input({ type: 'time', value })
    case 'date-range': {
      const v = [...value]
      const part = (i) => h('label', null, t(i ? 'to' : 'from'), input({ type: 'date', id: i ? `${id}-to` : id, value: v[i], min: r.min, max: r.max, oninput: (e) => { v[i] = e.target.value; set([...v]) } }))
      return h('div', { class: 'cis-range' }, part(0), part(1))
    }
    case 'textarea': {
      const rows = Math.max(1, Math.min(20, Number(r.min) || 3))
      return h('textarea', {
        ...base, rows, placeholder: r.placeholder, maxlength: !r.autosize && typeof r.max === 'number' && r.max,
        oninput: (e) => { if (r.autosize) e.target.rows = Math.max(rows, Math.min(20, e.target.value.split('\n').length)); set(e.target.value) },
      }, value)
    }
    default: return input({ type: r.password ? 'password' : 'text', value, placeholder: r.placeholder, maxlength: typeof r.max === 'number' && r.max })
  }
}

on('input:open', (d) => {
  const rows = (Array.isArray(d.rows) ? d.rows : []).map(normalizeRow)
  const values = rows.map(initialValue)
  const fields = []
  const form = h('form', { class: 'cis-body cis-form', novalidate: true })
  rows.forEach((r, i) => {
    const id = `cis-f${d.id}-${i}`
    const err = h('div', { class: 'cis-err', id: `${id}-err`, role: 'alert' })
    const desc = r.description && h('div', { class: 'cis-desc', id: `${id}-desc`, text: r.description })
    const ctl = control(r, id, values[i], (v) => { values[i] = v; err.textContent = '' })
    const target = ctl.matches('input,textarea,[role=listbox]') ? ctl : ctl.querySelector('input,textarea,[role=listbox]')
    target?.setAttribute('aria-describedby', desc ? `${id}-desc ${id}-err` : `${id}-err`)
    fields.push({ err, target })
    const lab = h('label', { for: id }, icon(r.icon), r.label, r.required && h('span', { class: 'cis-req', 'aria-hidden': 'true', text: ' *' }))
    form.appendChild(h('div', { class: 'cis-field' }, r.type === 'checkbox' ? h('div', { class: 'cis-check' }, ctl, lab) : [lab, ctl], desc, err))
  })
  const submit = (e) => {
    e?.preventDefault()
    const coerced = rows.map((r, i) => coerce(r, values[i]))
    const res = validateAll(rows, coerced)
    for (const f of fields) { f.err.textContent = ''; f.target?.removeAttribute('aria-invalid') }
    if (!res.ok) {
      for (const er of res.errors) {
        fields[er.index].err.textContent = t(er.key, er.params)
        fields[er.index].target?.setAttribute('aria-invalid', 'true')
      }
      fields[res.errors[0].index].target?.focus()
      return
    }
    close('input', d.id)
    post('input', { id: d.id, values: resultValues(rows, coerced) })
  }
  form.addEventListener('submit', submit)
  form.appendChild(h('button', { type: 'submit', hidden: true, tabindex: -1 }))
  const opts = d.options && typeof d.options === 'object' ? d.options : {}
  const ok = btn(label(opts.labels, 'confirm'), submit, true)
  modal('input', { id: d.id, size: opts.size }, String(d.heading ?? ''), form, [
    opts.allowCancel !== false && btn(label(opts.labels, 'cancel'), () => { close('input', d.id); post('input', { id: d.id, cancelled: true }) }),
    ok,
  ])
  ;(focusables(form)[0] || ok).focus()
})
on('input:close', (d) => close('input', d.id))
