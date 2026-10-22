<!-- Independent read-only re-audit, 2026-10-22, of branch claude/vigilant-hamilton-3b0fva at or just before e0561a2. Line numbers may drift slightly. NOT YET ACTED ON. Scratch harness paths it mentions were in the cloud session and are gone. -->

## cis_libs NUI layer audit (branch claude/vigilant-hamilton-3b0fva, read-only)

I read everything in scope in full: web/**, client/interface/*.lua, client/ui.lua, server/interface.lua, the interface entries in api.lua (lines 401–681), test/interface.lua and test/web/*. The test suites pass: `npm run test:web` 47/47 and `npm test` 3050 assertions, including interface 234/234. My scratch probes are in /tmp/claude-0/audit/ (utf8.lua, v.mjs, md.mjs).

**Grade: B.** Rendering is text-node-only, NUI callbacks are shape-checked, the focus stack has a single exit, idle cost is zero and the tests are strong. Two things keep it from an A: a likely runtime CSS incompatibility, and NUI callback ids that are easy to guess.

### HIGH

**H1. CSS needs Chromium 104 or later, but FiveM's CEF has been reported at Chromium 103.**
- **Evidence:** web/style.css:40, 41, 52–54, 60, 61, 66 and 151 position things with the standalone `translate:` and `rotate:` properties. Chromium only supports those from version 104.
- **Why I think CEF is 103:** the Cfx.re client update of Nov 8 2022 moved CEF from M91 to M103. A Cfx forum thread from Jan 2026 still asks for a CEF update.
- **Failure on M103:** these elements land off-centre:
  - progress bar: left edge at 50%, about 170px right of centre
  - skill check: 60px off
  - text UI: all four positions
  - notification lanes: top, bottom and center-*
  - progress circle: starts at 3 o'clock instead of 12, because `.cis-ring svg {rotate:-90deg}` is dropped.
- The fake DOM in the web tests has no CSS, so nothing catches this.
- **Caveat:** check on a live client first. If CEF is newer by now, this finding goes away.

### MEDIUM

**M1. NUI callback ids are one shared counter, and the page's message listener doesn't check where messages come from.**
- **Evidence:**
  - Every id comes from one 1-up counter `I.nextId()` (nui.lua:42–45): alert.lua:316, input.lua:166, context.lua:178, radial.lua:76, skillcheck.lua:327.
  - core.js:18–23 accepts any `message` event without checking `e.source` or `e.origin`.
- **Failure:** script running in any other resource's NUI frame (for example an XSS in a chat or phone resource; this attack chain is publicly documented) can loop `fetch('https://cis_libs/alert', {id:1..500, result:'confirm'})`. That confirms whatever alert is open. The same works for `context` select (runs `onSelect`/`serverEvent`), `input` values and `skill` success. It can also `postMessage` fake components or `skill:stop` into the frame.
- The header comment in nui.lua:4–11 claims an unknown id is a no-op, but a counter is trivially guessed.
- **Fix:** random tokens, plus a check on `e.source`.
- For comparison, ox_lib has no tokens at all.

**M2. An input dialog can leave the player stuck with the cursor and an invisible dialog.**
- **Evidence:**
  - The page closes the dialog before posting the answer (dialog.js:147–148).
  - Lua silently rejects values it doesn't accept and keeps the dialog open with focus held (input.lua:216–221).
  - With `allowCancel=false`, Escape does nothing (input.lua:172–174).
- **Concrete triggers:**
  - Select option values above 2^53, such as Steam64 IDs stored as numbers. JavaScript rounds them, the page's own check still passes, and Lua's exact check fails.
  - Textarea text over 65,536 bytes (no `maxlength` is set).
  - A lost fetch.
- **Result:** NUI focus and cursor stay up, nothing is drawn, Escape is dead. The only recovery is `CloseInputDialog`, the owner stopping, or a cis_libs restart.

**M3. Lua checks less than api.lua promises.**
- **Evidence:** api.lua:525 says "Values are checked against the rows" and "date is YYYY-MM-DD, time HH:MM, color #rrggbb". `valueOk` (input.lua:98–121) only checks type, whether the value was offered, and nil-when-required.
- **Not checked:** number min/max, string length, `maxSelectedValues`, date/time/colour formats, a required checkbox being true, duplicates in multi-select.
- **Failure:** a forged answer (via M1) can return `-1e308` for a `number` row with `min=1`.

**M4. ox_lib-style icon names render as text or nothing.**
- **Evidence:** core.js:80–93 knows 12 built-in icons. Anything else of 4 characters or fewer is drawn as literal text.
- **Failure:**
  - `icon='hand'`, `'gear'`, `'bars'`, `'bolt'` or `'home'` draw the word itself as the icon.
  - `'hashtag'`, `'fa-box'` and table icons like `{'far','calendar'}` (I.str drops tables) draw nothing.

**M5. Input field meanings differ from ox_lib under the same field names.**
- **Textarea `min`/`max`:** ox_lib uses them as row counts (confirmed in the ox_lib docs). Here `min` is both the row count and a minimum length, and `max` is a maximum length (dialog.js:108–111, validate.js:105).
- **Verified failure:** an ox-style `{min=3, max=10, autosize=true}` rejects "ab" with "At least 3 characters" and limits the text to 10 characters.
- **Date/time:** they return strings here, while ox_lib returns timestamps. This one is documented, but it is still a migration trap.

**M6. Skill-check timing and the lack of a watchdog.**
- **Timing:** the key press is detected in Lua, sent to the page, and judged there with the page's clock on arrival (skillcheck.lua:338–341 → skillcheck.js:52–55). That makes the judgement late by an amount that depends on frame rate. I did not measure it; at "hard" (0.315°/ms), each 16 ms frame is about 5° of the 25° zone.
- **No watchdog:** if the page never reports a result (a spoofed `skill:stop`, or a JavaScript error), the thread at skillcheck.lua:330–346 keeps disabling attack/aim (24, 25, 140–142, 257, 263) and the check's keys indefinitely. The skill check has no focus entry, so Escape can't end it either.

### LOW

- **L1. Non-ASCII notifications from the server become '?'.** The server cuts strings by bytes (server/interface.lua:287–291). The client then sees invalid UTF-8 and replaces every non-ASCII character with '?' (nui.lua:57–59). Verified: a 520-byte Cyrillic title arrives as "???? ????". Separately, `I.str` limits characters, not bytes.
- **L2. Right-click probably closes the list menu.** menu.lua:14 treats control 177 as "back". Per the FiveM control reference, 177 (INPUT_CELLPHONE_CANCEL) includes the right mouse button. With `disableInput=false`, aiming would close the menu and call `onClose('Backspace')`.
- **L3. Progress percentage never updates in two cases.** With reduced motion, the circle shows "0%" for the whole run. The bar never updates `aria-valuenow` (progress.js:35–42).
- **L4. Holding Escape closes more than one layer.** Auto-repeat isn't filtered (app.js:21–26), so holding Escape closes an alert and then the context menu under it.
- **L5. Focus and layering after modals.**
  - When a dialog closes, focus doesn't return to the context menu, so arrow keys stop working until the player clicks.
  - A context menu opened while a dialog is up is drawn under the dialog's backdrop (index.html layer order), so it can't be clicked.
- **L6. Theme colour keys can overwrite non-colour tokens.** For example `colors.scale='red'` breaks the `font` shorthand (theme.lua:84–91, core.js:131–133).
- **L7. Links inside context options do two things.** A markdown link in an option opens the URL (`openUrl`) and also selects the option (context.js:24/34 with core.js:53–59).
- **L8. Documentation is out of date or contradicts the code.**
  - DOCUMENTATION.md:1155 and 1205, and client/ui.lua:3–7, still say no NUI ships.
  - The `Toast` entry in api.lua says notify "routes here once wired"; it already does.
  - The theme.lua comment says the UI never touches the network, but core.js:76 and context.js:28 load https icon and image URLs, which exposes players' IPs to third-party hosts.
  - fxmanifest says 1.0.0 while the exports say `since 1.1.0`.
- **L9. Progress props and animation loading.**
  - Props are created as networked objects (progress.lua:92). Strict entity lockdown may reject them; I could not verify this offline.
  - There is no `DoesAnimDictExist` check, so a misspelled dictionary stalls the start by 3 seconds (progress.lua:48–55).
- **L10. Progress before the page loads runs invisibly.** It is neither buffered nor waited for (progress.lua:280).
- **L11. Payloads and dead code.**
  - Total payload size isn't capped: `SetMenuOptions` re-sends all options, up to 256 options with 128 values each.
  - The page's `notify:clear` handler has no Lua export calling it, and there is no way to close one toast by id.
  - The markdown parser takes about 80 ms on a pathological 8,000-character alert.
- **L12. Accessibility.**
  - `<label for>` points at a div listbox, so the listbox has no accessible name.
  - White text on the accent colour is 3.2:1, below the 4.5:1 guideline.
  - `lang="en"` is fixed even when the locale changes.
- **L13. Radial keys reach the game.** The radial keeps game input, so Space or Enter used to activate an item also reach the game. Space makes the player jump; control 22 isn't disabled (radial.lua:16).
- **L14. Re-registering an open context menu shifts the options.** Selection uses the new list's indexes (context.lua:253). ox_lib behaves the same way.
- **L15. `AddRadialItem` can half-succeed.** When it hits MAX_ITEMS, it has already added some items before returning false (radial.lua:155–162).

### By category

- **Security:**
  - XSS/HTML injection: none found. There are no HTML sinks; the markdown parser only builds text nodes; link URLs are limited to https/nui with no quotes.
  - CSS injection: none found. Values go through `setProperty` per property and colours are validated.
  - Spoofing server-to-client notifications from a client: none found (notify.lua:187–192 only accepts network events; the server side is export-only).
  - The real problems are M1 and M3.
- **Focus and input:** the stack design is sound. Every exit path calls `settle`/`finish`, and stop, restart and reload all clear focus. Controls are only disabled while something is active. Exceptions: M2, M6, L4 and L5.
- **Performance:** zero idle cost confirmed. The only timers are one `setTimeout` per toast and requestAnimationFrame for the circle and skill check while shown; Lua threads exist only while a component is active.
- **Gaps versus ox_lib:**
  - icons: the full Font Awesome set and `iconAnimation` (here, 12 icons)
  - select/multi-select: `searchable` and `clearable`
  - date/time: `format` and timestamps; colour formats
  - markdown: lists, headings, tables, images
  - radial: `getCurrentRadialId`, string `onSelect`, hold-to-open
  - clipboard
  - the player settings menu
  - bundled locales

### What keeps it from an A

1. H1
2. M1
3. M2
4. M3
5. M4
6. M5
7. M6 (timing and watchdog)
8. L1
9. L8 (documentation drift)

Sources: [Cfx.re client update, Nov 8 2022 (CEF M91 to M103)](https://forum.cfx.re/t/cfx-re-client-update-fivem-redm-for-november-8-2022/4942671), [Cfx forum cef tag (2026 request to update CEF)](https://forum.cfx.re/tag/cef), [ox_lib input docs](https://overextended.dev/ox_lib/Modules/Interface/Client/input), [Gigazine on NUI XSS research](https://gigazine.net/gsc_news/en/20230831-hacking-gta-servers)
