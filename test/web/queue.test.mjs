import test from 'node:test'
import assert from 'node:assert/strict'
import { createQueue } from '../../web/js/queue.js'

const n = (extra) => ({ position: 'top-right', description: 'x', ...extra })

test('shows up to max per position, queues the rest', () => {
  const q = createQueue({ max: 2 })
  assert.equal(q.add(n()).action, 'show')
  assert.equal(q.add(n()).action, 'show')
  assert.equal(q.add(n()).action, 'queued')
  assert.equal(q.add(n({ position: 'bottom' })).action, 'show', 'positions are independent lanes')
  assert.equal(q.visible('top-right').length, 2)
  assert.equal(q.waiting('top-right').length, 1)
})

test('removing a visible one promotes the oldest waiting one', () => {
  const q = createQueue({ max: 1 })
  const a = q.add(n({ description: 'a' })).item
  q.add(n({ description: 'b' }))
  q.add(n({ description: 'c' }))
  const r = q.remove(a.key)
  assert.equal(r.removed, true)
  assert.equal(r.promoted.description, 'b')
  assert.deepEqual(q.visible('top-right').map((x) => x.description), ['b'])
  assert.equal(q.remove(9999).removed, false)
})

test('dedupe by id: visible is updated in place, keeping its key and position', () => {
  const q = createQueue({ max: 3 })
  const first = q.add(n({ id: 'fuel', description: '50%' })).item
  const r = q.add(n({ id: 'fuel', description: '40%', position: 'bottom' }))
  assert.equal(r.action, 'update')
  assert.equal(r.item.key, first.key)
  assert.equal(r.item.position, 'top-right')
  assert.equal(r.item.description, '40%')
  assert.equal(q.visible('top-right').length, 1)
})

test('dedupe by id: a waiting one is replaced in place, not duplicated', () => {
  const q = createQueue({ max: 1 })
  q.add(n())
  q.add(n({ id: 'w', description: 'old' }))
  const r = q.add(n({ id: 'w', description: 'new' }))
  assert.equal(r.action, 'queued')
  assert.deepEqual(q.waiting('top-right').map((x) => x.description), ['new'])
})

test('no id never dedupes', () => {
  const q = createQueue({ max: 5 })
  q.add(n())
  q.add(n())
  assert.equal(q.visible('top-right').length, 2)
})

test('setMax clamps 1..10 and promotes when raised', () => {
  const q = createQueue({ max: 1 })
  q.add(n())
  q.add(n())
  q.add(n())
  const promoted = q.setMax(3)
  assert.equal(promoted.length, 2)
  assert.equal(q.max, 3)
  q.setMax(500)
  assert.equal(q.max, 10)
  q.setMax('junk')
  assert.equal(q.max, 5)
})
