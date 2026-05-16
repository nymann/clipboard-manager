# clipboard-manager

A lightweight macOS clipboard history manager — a leaner replacement for
Jumpcut. It watches the system pasteboard, keeps a capped in-memory
history of plain-text clips, and gives you two global hotkeys to get an
old clip back into the app you're working in:

- **`⌘⌥V` — searchable panel.** A floating panel pops up; type to
  filter, arrow keys to move, Return to pick. The chosen clip is put on
  the pasteboard and immediately pasted into whatever app was frontmost.
- **`⌃⌥V` — cycle bezel.** A small centered HUD shows the most recent
  clip. Each further press of the hotkey steps one clip older. Stop
  pressing for ~1 s and the shown clip is pasted; `Esc` cancels.

Both hotkeys end the same way: the selected text is placed on the
pasteboard and a synthetic `⌘V` is sent to the app that was frontmost
when the hotkey fired.

## Scope (v0)

- Menu-bar-only app (`LSUIElement`), no Dock icon, no main window.
- Watches `NSPasteboard.general` by polling `changeCount` on a 0.5 s
  timer (the pasteboard has no change notification API).
- **Plain text only.** Captures `public.utf8-plain-text`
  (`NSPasteboard.PasteboardType.string`). Images, RTF and files are
  ignored on purpose — this keeps the store tiny and the UI trivial.
- **In-memory only.** Nothing is written to disk. History is a capped
  ring (200 entries) that dies with the process. This is the most
  private option and needs no storage code; the cost is that history
  resets on logout/reboot. (See "Possible later directions".)
- **De-duplicated.** Re-copying an existing clip moves it to the front
  rather than adding a duplicate.
- **Password-safe.** Clips whose pasteboard carries
  `org.nspasteboard.ConcealedType` (password managers) or
  `org.nspasteboard.TransientType` (clipboard tools marking a clip as
  not-for-history) are skipped.
- Two global hotkeys, registered with Carbon `RegisterEventHotKey`:
  - `⌘⌥V` → searchable panel
  - `⌃⌥V` → cycle bezel
  Hotkeys are hardcoded in v0 (named constants at the top of
  `main.swift`); a config file is a "later" item.
- On pick: write the clip to the pasteboard, re-activate the
  previously-frontmost app, then post a synthetic `⌘V`.
- Menu-bar status item: left-click opens the searchable panel;
  right-click shows a menu (item count, Clear History, the two
  hotkeys as disabled hints, Accessibility status, Quit).
- Exit is via the menu's Quit. Errors are logged with `NSLog`; the app
  never blocks or shows modal alerts.

Out of scope for v0: persistence, images/RTF/files, pinned/favourite
clips, editing a clip before paste, per-app rules, configurable
hotkeys, Sparkle auto-update, Developer ID signing / notarization.

## The cycle bezel vs. classic Jumpcut

Classic Jumpcut works as *hold modifier, tap key to cycle, release
modifier to paste*. That release-to-commit gesture needs the key-up /
flags-changed event. Carbon's `RegisterEventHotKey` only delivers a
single key-**down** per chord, so true release-to-paste isn't available
without a global event tap (heavier, and a second Accessibility
surface).

The v0 model instead is **press-to-step, pause-to-commit**:

- First `⌃⌥V`: record the frontmost app, show the bezel at index 0
  (newest clip).
- Each further `⌃⌥V` within the window: index += 1 (older), wrapping at
  the end; the commit timer resets.
- No press for `commitDelay` (1.0 s): paste the clip at the current
  index, hide the bezel.
- A global `Esc` monitor (only active while the bezel is up) cancels
  without pasting.

This is keyboard-only, needs no event tap, and is faithful to the
"flick through recent clips without leaving the keyboard" feel even
though the commit trigger differs.

## Permissions

- **Hotkeys** need nothing — Carbon `RegisterEventHotKey` is not gated
  by Accessibility.
- **Auto-paste** synthesizes `⌘V` with `CGEvent.post`, which requires
  the app to be trusted for Accessibility. At launch the app calls
  `AXIsProcessTrustedWithOptions` with the prompt option; if not yet
  trusted it keeps running (history capture and the hotkeys still
  work) and the right-click menu shows the clip is captured but paste
  is disabled until the user grants access in System Settings →
  Privacy & Security → Accessibility.
- The TCC Accessibility grant is keyed by bundle id **and** code
  signature, so the bundle is ad-hoc signed (`codesign --sign -`) in
  the build. Without *any* signature the grant would not persist
  across rebuilds; ad-hoc is enough for personal use. (Same rationale
  as the notification grant in the sibling `micflip` tool.)

## Tech approach

- Language: Swift, one source file (`clipboard-manager.swift`), built
  with `swiftc -O`. No Xcode project, no SwiftPM manifest — `swiftc`
  ships with the Command Line Tools. The `.app` bundle is
  hand-assembled by the `justfile` (Info.plist + binary + icon, then
  ad-hoc codesign), matching the sibling `nosleep` tool.
- `Cocoa` for the status item / panel / bezel, `Carbon.HIToolbox` for
  the hotkeys, `CoreGraphics` for the synthetic paste, `Application
  Services` (`AXIsProcessTrusted…`) for the permission check.
- `NSApplication` activation policy `.accessory`.
- A single `AppController` (an `NSApplicationDelegate`) owns the
  history, the timer, both hotkeys and both UIs. It is exposed as
  `AppController.shared` so the C hotkey callback can reach it.
- Pasteboard watcher: a `Timer` every 0.5 s compares
  `NSPasteboard.general.changeCount` to the last seen value. On
  change, if a `.string` is present and the pasteboard is not
  concealed/transient, the trimmed string is pushed onto the history.
  When *we* write the pasteboard for a paste, we record the new
  `changeCount` first so the watcher doesn't re-ingest our own write.
- Searchable panel: an `NSPanel` (`.titled`/`.nonactivatingPanel`
  borderless, `canBecomeKey == true`) with an `NSSearchField` over an
  `NSTableView` in an `NSScrollView`. Filtering is a case-insensitive
  `contains` on the history. A local key monitor handles ↑/↓/Return/Esc
  while the panel is key.
- Cycle bezel: a borderless non-activating `NSWindow`, centered,
  rounded translucent background, one multi-line label plus an
  `n/total` counter.
- Paste: `pb.clearContents(); pb.setString(s, forType: .string)`,
  record `changeCount`, `prevApp?.activate()`, then after a short
  delay post `v` down+up with `.maskCommand` via
  `CGEvent(keyboardEventSource:…)` on `.cghidEventTap`.
- Identify the target app by capturing
  `NSWorkspace.shared.frontmostApplication` *before* showing any UI,
  because showing the panel makes this app frontmost.

## Layout

```
clipboard-manager/
  design.md                       this file
  plans/                          numbered, actionable build plans
  clipboard-manager.swift         the app
  Info.plist                      template baked into the .app
  make-icon.swift                 one-shot AppIcon.iconset generator
  dev.nymann.clipboard-manager.plist  LaunchAgent for start-at-login
  justfile                        build / install / agent / release
  .github/workflows/bump-cask.yml release → PR against homebrew-tap
  README.md
```

## Testing

No unit tests in v0, matching the sibling tools: the logic is a
pasteboard poll, two Carbon hotkeys and a synthetic keystroke, whose
only real failure modes are environmental (Accessibility denied, hotkey
already taken). `just test` runs `swiftc -typecheck` over every
`.swift` source as the syntax/type gate between `run-plans` steps.

## Possible later directions

Only if the friction actually shows up:

- Optional on-disk persistence behind a flag / menu toggle.
- Pinned/favourite clips that survive the ring eviction.
- Configurable hotkeys + cap via `~/.config/clipboard-manager/config`.
- Capture images / RTF as additional, separately-rendered kinds.
- True release-to-paste cycle via a `CGEventTap` (second Accessibility
  surface — only if the pause-to-commit model annoys in practice).
- Exclude-app list (don't capture while a given app is frontmost).
