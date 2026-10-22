import test from 'node:test'
import assert from 'node:assert/strict'
import { step, first, last, keyIntent, trapTab, angleToIndex, pointToAngle, paginate } from '../../web/js/nav.js'
import { resolveDifficulty, makeRound, angleAt, judge, expired, PRESETS } from '../../web/js/skill.js'

test('step wraps and skips disabled items', () => {
  const disabled = new Set([1, 2])
  const skip = (i) => disabled.has(i)
  assert.equal(step(5, 0, 1, skip), 3)
  assert.equal(step(5, 4, 1, skip), 0)
  assert.equal(step(5, 0, -1, skip), 4)
  assert.equal(step(5, 3, -1, skip), 0)
  assert.equal(step(3, 0, 1, () => true), -1, 'nothing selectable')
  assert.equal(step(3, 2, 1, () => false, false), 2, 'no wrap stays at the end')
  assert.equal(step(0, 0, 1), -1)
})

test('first and last skip disabled items', () => {
  const skip = (i) => i === 0 || i === 4
  assert.equal(first(5, skip), 1)
  assert.equal(last(5, skip), 3)
  assert.equal(first(2, () => true), -1)
})

test('keyIntent maps keys for vertical and horizontal widgets', () => {
  assert.equal(keyIntent('ArrowDown'), 'next')
  assert.equal(keyIntent('ArrowUp'), 'prev')
  assert.equal(keyIntent('ArrowRight'), 'right')
  assert.equal(keyIntent('ArrowRight', 'horizontal'), 'next')
  assert.equal(keyIntent('ArrowDown', 'horizontal'), null)
  assert.equal(keyIntent('Enter'), 'activate')
  assert.equal(keyIntent(' '), 'activate')
  assert.equal(keyIntent('Escape'), 'cancel')
  assert.equal(keyIntent('Backspace'), 'back')
  assert.equal(keyIntent('Home'), 'first')
  assert.equal(keyIntent('End'), 'last')
  assert.equal(keyIntent('q'), null)
})

test('trapTab cycles inside the dialog in both directions', () => {
  assert.equal(trapTab(3, 2, false), 0)
  assert.equal(trapTab(3, 0, true), 2)
  assert.equal(trapTab(3, 1, false), 2)
  assert.equal(trapTab(3, -1, false), 0, 'focus outside goes to the first stop')
  assert.equal(trapTab(3, -1, true), 2, 'shift+tab from outside goes to the last stop')
  assert.equal(trapTab(0, 0, false), -1)
})

test('radial geometry: angle to slice, clockwise from 12 o\'clock', () => {
  assert.equal(angleToIndex(0, 4), 0)
  assert.equal(angleToIndex(44, 4), 0)
  assert.equal(angleToIndex(46, 4), 1)
  assert.equal(angleToIndex(359, 4), 0)
  assert.equal(angleToIndex(-90, 4), 3)
  assert.equal(angleToIndex(10, 0), -1)
  assert.equal(Math.round(pointToAngle(0, -1)), 0, 'up')
  assert.equal(Math.round(pointToAngle(1, 0)), 90, 'right')
  assert.equal(Math.round(pointToAngle(0, 1)), 180, 'down')
  assert.equal(Math.round(pointToAngle(-1, 0)), 270, 'left')
})

test('paginate: a full page reserves its last slot for "more" and wraps', () => {
  assert.deepEqual(paginate(5, 8, 0), { start: 0, end: 5, more: false, pages: 1 })
  const p0 = paginate(20, 8, 0)
  assert.equal(p0.end - p0.start, 7)
  assert.equal(p0.more, true)
  assert.equal(p0.pages, 3)
  assert.deepEqual([paginate(20, 8, 2).start, paginate(20, 8, 2).end], [14, 20])
  assert.equal(paginate(20, 8, 3).start, 0, 'wraps to the first page')
})

test('skill: difficulty resolution clamps custom values and rejects junk', () => {
  assert.deepEqual(resolveDifficulty('easy'), PRESETS.easy)
  assert.equal(resolveDifficulty('impossible'), null)
  assert.deepEqual(resolveDifficulty({ areaSize: 1000, speedMultiplier: 0 }), { areaSize: 180, speedMultiplier: 0.25 })
  assert.equal(resolveDifficulty({ areaSize: 'x', speedMultiplier: 1 }), null)
})

test('skill: rounds place the zone after the first quarter and judge hits, misses, wrong keys', () => {
  const lo = makeRound(PRESETS.hard, ['w', 'a'], () => 0)
  const hi = makeRound(PRESETS.hard, ['w', 'a'], () => 0.999)
  assert.equal(lo.start, 90)
  assert.ok(hi.start + hi.size <= 350)
  assert.equal(lo.key, 'w')
  assert.equal(hi.key, 'a')
  const r = makeRound({ areaSize: 40, speedMultiplier: 1 }, ['e'], () => 0.5)
  assert.equal(judge(r, r.start + 1, 'e'), 'hit')
  assert.equal(judge(r, r.start - 1, 'e'), 'fail')
  assert.equal(judge(r, r.start + 1, 'q'), 'fail')
  assert.equal(expired(r, r.start + r.size + 0.1), true)
  assert.equal(expired(r, r.start), false)
  assert.equal(angleAt(r, 2000), 360, 'one turn in 2s at speed 1')
  assert.equal(angleAt(r, -5), 0)
})
