// Pull fenced ```lua example blocks out of markdown.

function extractExamples(md, source) {
  const out = []
  const re = /```lua example\r?\n([\s\S]*?)```/g
  let m
  let i = 0
  while ((m = re.exec(md))) {
    i += 1
    out.push({ source, index: i, code: m[1].replace(/\s+$/, '') + '\n' })
  }
  return out
}

module.exports = { extractExamples }
