// Input dialog rows: normalise, initial value, coerce, validate. Pure; errors
// are { key, params } so the page localises them.
export const FIELD_TYPES = ['input', 'number', 'checkbox', 'select', 'multi-select', 'slider', 'color', 'date', 'date-range', 'time', 'textarea']

const DATE = /^\d{4}-\d{2}-\d{2}$/
const TIME = /^([01]\d|2[0-3]):[0-5]\d$/
const HEX = /^#(?:[0-9a-f]{3}|[0-9a-f]{6})$/i
const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : undefined)
const str = (v) => (typeof v === 'string' ? v : undefined)
const prim = (v) => typeof v === 'string' || typeof v === 'number'

export const normalizeOptions = (list) => (Array.isArray(list) ? list : [])
  .map((o) => (prim(o) ? { value: o, label: String(o) } : o && prim(o.value) ? { value: o.value, label: str(o.label) ?? String(o.value) } : null))
  .filter(Boolean)

export function normalizeRow(row) {
  if (typeof row === 'string') row = { label: row }
  if (!row || typeof row !== 'object') row = {}
  const type = FIELD_TYPES.includes(row.type) ? row.type : 'input'
  const slider = type === 'slider'
  return {
    type,
    label: str(row.label) ?? '',
    description: str(row.description),
    placeholder: str(row.placeholder),
    icon: str(row.icon),
    required: row.required === true,
    disabled: row.disabled === true,
    default: row.default,
    min: num(row.min) ?? str(row.min) ?? (slider ? 0 : undefined),
    max: num(row.max) ?? str(row.max) ?? (slider ? 100 : undefined),
    step: num(row.step),
    precision: num(row.precision),
    password: row.password === true,
    checked: row.checked === true,
    options: normalizeOptions(row.options),
    maxSelectedValues: num(row.maxSelectedValues),
    autosize: row.autosize === true,
  }
}

export function roundTo(value, precision) {
  if (typeof precision !== 'number' || precision < 0) return value
  const f = 10 ** Math.min(10, Math.floor(precision))
  return Math.round(value * f) / f
}

const offered = (r, v) => r.options.some((o) => o.value === v)

export function initialValue(r) {
  const d = r.default
  switch (r.type) {
    case 'checkbox': return typeof d === 'boolean' ? d : r.checked
    case 'number': return num(d) ?? null
    case 'slider': return num(d) ?? r.min
    case 'multi-select': return Array.isArray(d) ? d.filter((v) => offered(r, v)) : []
    case 'select': return offered(r, d) ? d : null
    case 'date-range': return Array.isArray(d) ? [str(d[0]) ?? '', str(d[1]) ?? ''] : ['', '']
    case 'color': return typeof d === 'string' && HEX.test(d) ? d : ''
    default: return prim(d) ? String(d) : ''
  }
}

// What a control holds -> what the caller gets back.
export function coerce(r, raw) {
  switch (r.type) {
    case 'number': {
      if (raw === '' || raw === null || raw === undefined) return null
      const n = typeof raw === 'number' ? raw : Number(String(raw).trim())
      return Number.isFinite(n) ? roundTo(n, r.precision) : NaN
    }
    case 'slider': { const n = Number(raw); return Number.isFinite(n) ? n : r.min }
    case 'checkbox': return raw === true
    case 'multi-select': return Array.isArray(raw) ? raw : []
    case 'select': return raw === '' || raw === undefined ? null : raw
    case 'date-range': return Array.isArray(raw) ? [String(raw[0] ?? ''), String(raw[1] ?? '')] : ['', '']
    default: return raw === null || raw === undefined ? '' : String(raw)
  }
}

const isEmpty = (r, v) => v === null || v === undefined || v === ''
  || (r.type === 'multi-select' && v.length === 0)
  || (r.type === 'date-range' && (!v[0] || !v[1]))
  || (r.type === 'checkbox' && v !== true)

const range = (v, r, lo, hi, n = v) => (typeof r.min === 'number' && n < r.min ? { key: lo, params: { n: r.min } }
  : typeof r.max === 'number' && n > r.max ? { key: hi, params: { n: r.max } } : null)

function checkDate(r, v) {
  if (!DATE.test(v) || Number.isNaN(Date.parse(v))) return { key: 'invalidDate' }
  if (DATE.test(r.min ?? '') && v < r.min) return { key: 'minDate', params: { n: r.min } }
  if (DATE.test(r.max ?? '') && v > r.max) return { key: 'maxDate', params: { n: r.max } }
  return null
}

export function validateField(r, v) {
  if (r.disabled) return null
  if (isEmpty(r, v)) {
    if (r.type === 'date-range' && (v[0] || v[1])) return { key: 'invalidRange' }
    return r.required ? { key: 'required' } : null
  }
  switch (r.type) {
    case 'number': case 'slider':
      return typeof v !== 'number' || Number.isNaN(v) ? { key: 'invalidNumber' } : range(v, r, 'min', 'max')
    case 'input': case 'textarea': return range(v, r, 'minLength', 'maxLength', v.length)
    case 'select': return offered(r, v) ? null : { key: 'invalid' }
    case 'multi-select':
      if (!v.every((x) => offered(r, x))) return { key: 'invalid' }
      return typeof r.maxSelectedValues === 'number' && v.length > r.maxSelectedValues ? { key: 'maxSelected', params: { n: r.maxSelectedValues } } : null
    case 'color': return HEX.test(v) ? null : { key: 'invalidColor' }
    case 'time': return TIME.test(v) ? null : { key: 'invalid' }
    case 'date': return checkDate(r, v)
    case 'date-range': return checkDate(r, v[0]) || checkDate(r, v[1]) || (v[0] > v[1] ? { key: 'invalidRange' } : null)
    default: return null
  }
}

export function validateAll(rows, values) {
  const errors = []
  rows.forEach((r, i) => {
    const e = validateField(r, values[i])
    if (e) errors.push({ index: i, ...e })
  })
  return { ok: errors.length === 0, errors }
}

// What crosses back to Lua: one entry per row, empty optional fields null.
export const resultValues = (rows, values) => rows.map((r, i) => (r.type === 'checkbox' ? values[i] === true
  : r.type === 'multi-select' ? values[i] : isEmpty(r, values[i]) ? null : values[i]))

