// Skill check drawing model. Pure, no imports. Lua makes each round and
// judges it (client/interface/skillcheck.lua); the page only draws the needle
// sweeping clockwise from 0deg at the round's degPerMs.

export function angleAt(round, elapsedMs) {
  return Math.max(0, elapsedMs) * round.degPerMs
}
