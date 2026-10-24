# Changelog entries for the shared/util + shared/algo fixes (wk-util)

Ready to paste under `## [Unreleased]` in CHANGELOG.md. Items cite the
re-audit numbers in `reaudit-modules.md`.

### Changed

- **`mathx.round` returns an integer unchanged** (A-M2). `round(7, 2)` is
  the integer 7 rather than 7.0, and an integer past 2^53, or
  `math.mininteger`, comes back exactly as given instead of going through a
  float. A `decimals` count past 308 in either direction is treated as 308.
- **`sparse.each` visits the values present when the walk started, even if
  the visitor removes them** (A-M4). It walks a copy, so removing the current
  value no longer skips later values or hands the visitor nil.
- **`sparse.add(set, NaN)` returns false** (A-M4), like a nil value.
- **A validate field spec passes `nonEmpty` to a string, and `min`, `max`,
  `nonEmpty` and `of` to a `table`** (A-M7). `nonEmpty` also reaches an
  `array` or `map` spec. `required` still means "not nil": an empty string
  needs `nonEmpty`.
- **`table.deepMerge` refuses a base or overlay nested deeper than
  `opts.maxDepth`** with `nil, why` (A-M8). It used to copy and recurse until
  the stack overflowed.
- **`validate.defaults` returns `nil, why` for a cyclic table or one nested
  deeper than 64 levels** (A-M8). It used to raise a stack overflow.

### Fixed

- `mathx.round(0.49999999999999994)` returned 1; it returns 0. The result
  of `round(1.5, 400)` was NaN and `round(1e308, 1)` was infinity; both
  return the value (A-M2).
