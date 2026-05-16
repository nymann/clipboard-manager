# 04 — Searchable panel + cycle bezel

The two recall UIs. Both end by calling `paste(_:)` from plan 03.

## Pre-conditions

- Plan 03 landed; `paste(_:)` works with Accessibility granted.

## Steps

1. **Searchable panel** (`⌘⌥V`, also status-item left-click):
   - Borderless `NSPanel`, `canBecomeKey == true`, centered.
   - `NSSearchField` on top; `NSTableView` (1 column, view-based,
     single-line truncated) in an `NSScrollView` below.
   - `NSApp.activate(ignoringOtherApps:)`, `makeKeyAndOrderFront`.
   - Filter: case-insensitive `contains`; empty query = full history,
     newest first. Selection defaults to row 0.
   - Local key monitor while key: ↑/↓ move, Return =
     `commit(selected)`, Esc = dismiss. Double-click also commits.
   - `commit`: hide panel, `paste(text)`.

2. **Cycle bezel** (`⌃⌥V`):
   - Borderless non-activating centered `NSWindow`, translucent
     rounded background, a wrapped label + `idx+1/total` counter.
   - First press: `index = 0`, show, (re)start `commitTimer`
     (1.0 s). Subsequent presses while visible: `index = (index+1) %
     count`, refresh label, restart timer.
   - Timer fire: `hide(); paste(items[index])`.
   - Global `Esc` monitor active only while visible → `hide()` with
     no paste.
   - Empty history: brief "no clips" flash, no timer.

3. Both UIs no-op gracefully on empty history.

## Verification

- `⌘⌥V`: panel opens, typing filters, Return pastes into the prior
  app, Esc dismisses.
- `⌃⌥V`: bezel steps older on each press, pauses to paste, Esc
  cancels.
- Status-item left-click opens the panel.
- `swiftc -typecheck` passes; `just build` green.

## Commit

`feat: searchable panel + cycle bezel`
