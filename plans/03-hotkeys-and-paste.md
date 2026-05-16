# 03 — Carbon hotkeys + auto-paste

Wire the two global hotkeys and the shared paste path.

## Pre-conditions

- Plan 02 landed; history fills as you copy.

## Steps

1. Carbon hotkeys via `RegisterEventHotKey` + one
   `InstallEventHandler` on `kEventClassKeyboard /
   kEventHotKeyPressed`. The C callback dispatches to
   `AppController.shared?.handleHotkey(id)` on the main queue.
   - id 1 = panel: `kVK_ANSI_V` + `cmdKey|optionKey`
   - id 2 = cycle: `kVK_ANSI_V` + `controlKey|optionKey`

2. Accessibility: at launch call
   `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`.
   Store the result; don't block on it.

3. `paste(_ text:)`:
   - `pb.clearContents(); pb.setString(text, .string)`,
     then `markPasteboardWritten()`.
   - `prevApp?.activate()`.
   - After ~0.12 s post `v` down+up with `.maskCommand` via
     `CGEvent` on `.cghidEventTap`.
   - If not Accessibility-trusted, skip the synthetic keystroke (the
     clip is still on the pasteboard) and `NSLog` a hint.

4. Capture `NSWorkspace.shared.frontmostApplication` into `prevApp`
   at the *start* of each hotkey handler, before any UI shows.

## Verification

- With Accessibility granted: copy A, copy B, focus a text field,
  press the panel hotkey stub / call `paste("A")` → "A" is inserted.
- Hotkeys fire even before Accessibility is granted (verify via
  `NSLog`).
- `swiftc -typecheck` passes.

## Commit

`feat: global hotkeys + synthetic-paste path`
