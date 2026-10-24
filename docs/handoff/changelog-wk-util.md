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
- **`locale.t` fills named values after formatting, not before** (A-M9). A
  `%` inside a `${name}` value now prints as it is and no longer shifts the
  positional arguments or raises. `%%` is now one `%` whenever any argument
  is given, including a table alone; with no argument the phrase is returned
  verbatim, as before. When the phrase does not fit its arguments the name-filled
  phrase is returned, with the values unescaped, and the warning is logged once.
- **`rate.prune` keeps a sliding limiter for its window plus one slice by
  default** (A-M5), so a key the ring still blocks is no longer freed early.
- **`window.record` accepts a sample older than the newest one** (A-M6). It
  is added to its own bucket and returns false only when it is older than the
  whole window.

- **A timer reuses its sleeping thread across pause and play** (A-M10). Each
  `play` used to spawn another thread, and a paused timer's old ones slept on
  until their original deadline, so 500 pause/play cycles left 501 threads.
  Now one thread serves the timer; it exits when it wakes on a paused or ended
  timer, and a later `play` starts a new one.
- **`string.suggest` returns the distance it matched on** (A-L1), the
  case-insensitive one, so it never exceeds `opts.maxDistance`. It used to
  re-score the winner in its real casing: `suggest('FOO', {'foo'})` answered 3
  against a maximum of 2.
- **`mathx.clamp` returns `nil, reason` for a NaN value or reversed bounds**
  (A-L10, A-L15), as `interp.clamp` and `validate.clamp` already do. It used
  to swap reversed bounds and pass NaN through, so the three clamps disagreed.
  A caller that relied on the swap must order its bounds.
- **`interp.ease` limits `t` to [0, 1]** (A-L10). The circ curves returned NaN
  above 1. An unknown name is still the identity, unlimited.
- **`interp.clampLength` treats a negative length as 0** (A-L10) and gives the
  zero vector; it used to flip the vector.
- **`curve.pointAtXYZ` on a closed path treats an infinite distance as 0**
  (A-L10); `inf % length` was NaN with `ok` true.
- **`heap.replaceTop` refuses nil, and NaN under the default ordering,** with
  `nil, reason` (A-L2), as `push` does. `heap.build` skips nil holes and
  such NaNs in its list.
- **`lru.put` refuses a nil or NaN key** with `nil, reason` (A-L3). A nil
  value is still a remove.
- **`cron.next` and `cron.matches` answer `nil, reason` for a time the platform
  cannot convert, and `matches` for one that is not a number** (A-L4). They
  raised from `os.date`, `math.floor` or inside the date arithmetic.

### Fixed

- `mathx.round(0.49999999999999994)` returned 1; it returns 0. The result
  of `round(1.5, 400)` was NaN and `round(1e308, 1)` was infinity; both
  return the value (A-M2).
- `mathx.approx` no longer calls an infinity equal to a huge finite number or
  to its opposite, and compares integers as floats so `approx(maxinteger, -1)`
  is false instead of wrapping to a tiny difference (A-M3).
- `string.levenshtein` with a ceiling returned the true distance when only the
  last cell was above it, and ignored the ceiling against an empty string. It
  returns ceiling + 1 in both (A-L1).
- `lru.removeWhere` raised when its predicate removed the entry it would visit
  next, or the one it was asked about (A-L3).
- A late `window.record` no longer moves the newest bucket backwards, which
  made live samples read as expired (A-M6).
