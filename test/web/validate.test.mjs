import test from 'node:test'
import assert from 'node:assert/strict'
import { normalizeRow, initialValue, coerce, validateField, validateAll, resultValues, roundTo, realDate, MAX_TEXT } from '../../web/js/validate.js'

const v = (row, raw) => {
  const r = normalizeRow(row)
  return validateField(r, coerce(r, raw))
}

test('normalizeRow: strings become text inputs, unknown types fall back to input', () => {
  assert.equal(normalizeRow('Name').type, 'input')
  assert.equal(normalizeRow('Name').label, 'Name')
  assert.equal(normalizeRow({ type: 'bogus' }).type, 'input')
  assert.equal(normalizeRow(null).type, 'input')
  const s = normalizeRow({ type: 'slider' })
  assert.equal(s.min, 0)
  assert.equal(s.max, 100)
})

test('select options accept {value,label} and bare values, drop junk', () => {
  const r = normalizeRow({ type: 'select', options: [{ value: 'a', label: 'A' }, 'b', 3, {}, null, { value: {} }] })
  assert.deepEqual(r.options, [{ value: 'a', label: 'A' }, { value: 'b', label: 'b' }, { value: 3, label: '3' }])
})

test('required', () => {
  assert.equal(v({ type: 'input', required: true }, '').key, 'required')
  assert.equal(v({ type: 'input' }, ''), null)
  assert.equal(v({ type: 'checkbox', required: true }, false).key, 'required')
  assert.equal(v({ type: 'checkbox', required: true }, true), null)
  assert.equal(v({ type: 'multi-select', required: true, options: ['a'] }, []).key, 'required')
  assert.equal(v({ type: 'input', required: true, disabled: true }, ''), null, 'disabled fields are not validated')
})

test('number: parse, min/max, precision', () => {
  assert.equal(v({ type: 'number' }, 'abc').key, 'invalidNumber')
  assert.deepEqual(v({ type: 'number', min: 5 }, '4'), { key: 'min', params: { n: 5 } })
  assert.deepEqual(v({ type: 'number', max: 5 }, '6'), { key: 'max', params: { n: 5 } })
  assert.equal(v({ type: 'number', min: 1, max: 10 }, ' 7 '), null)
  const r = normalizeRow({ type: 'number', precision: 2 })
  assert.equal(coerce(r, '3.14159'), 3.14)
  assert.equal(coerce(r, ''), null)
  assert.equal(roundTo(1.005, 0), 1)
})

test('text length limits', () => {
  assert.deepEqual(v({ type: 'input', min: 3 }, 'ab'), { key: 'minLength', params: { n: 3 } })
  assert.deepEqual(v({ type: 'textarea', maxLength: 3 }, 'abcd'), { key: 'maxLength', params: { n: 3 } })
  // A textarea's min/max are ROW counts, as in ox_lib: they used to reject
  // "ab" with "At least 3 characters" and cap the text at ten.
  assert.equal(v({ type: 'textarea', min: 3, max: 10, autosize: true }, 'ab'), null)
  assert.equal(v({ type: 'textarea', min: 3, max: 10 }, 'x'.repeat(50)), null)
  // With no maxLength, text is capped at MAX_TEXT, the number Lua checks too.
  assert.equal(normalizeRow({ type: 'textarea' }).maxLength, MAX_TEXT)
  assert.equal(v({ type: 'input' }, 'x'.repeat(MAX_TEXT + 1)).key, 'maxLength')
})

test('a date is a real calendar day', () => {
  assert.equal(realDate('2024-02-29'), true)
  assert.equal(realDate('2023-02-29'), false)
  assert.equal(realDate('2024-02-30'), false, 'Date.parse alone takes this as March 1')
  assert.equal(realDate('2024-04-31'), false)
  assert.equal(v({ type: 'date' }, '2024-02-30').key, 'invalidDate')
})

test('select and multi-select only accept offered values', () => {
  assert.equal(v({ type: 'select', options: ['a', 'b'] }, 'c').key, 'invalid')
  assert.equal(v({ type: 'select', options: ['a', 'b'] }, 'a'), null)
  assert.equal(v({ type: 'multi-select', options: ['a', 'b'] }, ['a', 'z']).key, 'invalid')
  assert.deepEqual(v({ type: 'multi-select', options: ['a', 'b', 'c'], maxSelectedValues: 1 }, ['a', 'b']), { key: 'maxSelected', params: { n: 1 } })
})

test('color, time, date, date-range', () => {
  assert.equal(v({ type: 'color' }, '#12345g').key, 'invalidColor')
  assert.equal(v({ type: 'color' }, 'red;background:url(x)').key, 'invalidColor')
  assert.equal(v({ type: 'color' }, '#ff8800'), null)
  assert.equal(v({ type: 'time' }, '25:00').key, 'invalid')
  assert.equal(v({ type: 'time' }, '23:59'), null)
  assert.equal(v({ type: 'date' }, '2026-13-45').key, 'invalidDate')
  assert.deepEqual(v({ type: 'date', min: '2026-01-01' }, '2025-12-31'), { key: 'minDate', params: { n: '2026-01-01' } })
  assert.equal(v({ type: 'date-range' }, ['2026-02-01', '2026-01-01']).key, 'invalidRange')
  assert.equal(v({ type: 'date-range' }, ['2026-01-01', '']).key, 'invalidRange', 'half a range is not a range')
  assert.equal(v({ type: 'date-range' }, ['2026-01-01', '2026-01-02']), null)
})

test('initial values honour defaults only when they fit the row', () => {
  assert.equal(initialValue(normalizeRow({ type: 'checkbox', checked: true })), true)
  assert.equal(initialValue(normalizeRow({ type: 'select', options: ['a'], default: 'zzz' })), null)
  assert.deepEqual(initialValue(normalizeRow({ type: 'multi-select', options: ['a', 'b'], default: ['b', 'q'] })), ['b'])
  assert.equal(initialValue(normalizeRow({ type: 'slider', min: 10 })), 10)
  assert.equal(initialValue(normalizeRow({ type: 'color', default: 'nope' })), '')
})

test('validateAll and resultValues: one entry per row, empty optional is null', () => {
  const rows = [{ type: 'input' }, { type: 'number', required: true }, { type: 'checkbox' }].map(normalizeRow)
  const raw = ['', '', false]
  const res = validateAll(rows, rows.map((r, i) => coerce(r, raw[i])))
  assert.equal(res.ok, false)
  assert.deepEqual(res.errors, [{ index: 1, key: 'required' }])
  assert.deepEqual(resultValues(rows, ['', 4, false]), [null, 4, false])
})
