// The shipped file set. Shared by live-deploy (2.8) and check-package (10.7).
// Computed from fxmanifest.lua so a new script cannot ship in one place and
// vanish from the zip.

const fs = require('fs')
const path = require('path')

function releaseFileSet(root) {
  const manifest = fs.readFileSync(path.join(root, 'fxmanifest.lua'), 'utf8')
  const files = new Set(['fxmanifest.lua', 'LICENSE.md', 'README.md'])
  for (const m of manifest.matchAll(/'([^']+\.lua)'/g)) files.add(m[1])
  const filesBlock = /files\s*\{([\s\S]*?)\}/.exec(manifest)
  if (filesBlock) {
    for (const m of filesBlock[1].matchAll(/'([^']+)'/g)) files.add(m[1])
  }
  const out = []
  const missing = []
  for (const rel of files) {
    if (!fs.existsSync(path.join(root, rel))) missing.push(rel)
    else out.push(rel.replace(/\\/g, '/'))
  }
  out.sort()
  return { files: out, missing }
}

function typesFiles(root) {
  const dir = path.join(root, 'types')
  const out = []
  if (!fs.existsSync(dir)) return out
  for (const name of fs.readdirSync(dir)) {
    if (name.endsWith('.lua')) out.push('types/' + name)
  }
  out.sort()
  return out
}

module.exports = { releaseFileSet, typesFiles }
