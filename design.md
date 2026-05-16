# clipboard-manager

A lightweight macOS clipboard history manager — a leaner replacement
for Jumpcut. It lives in the menu bar, watches the pasteboard for
text, styled text and image clips, keeps a capped history, and binds
**one** global hotkey — **Hyper+V (`⌃⇧⌥⌘V`)** — that opens a searchable
command-palette panel. Pick a clip and it's placed on the pasteboard
and pasted into whatever app was frontmost.

## Scope (v0)

- Menu-bar-only app (`LSUIElement`), no Dock icon, no main window.
- Watches `NSPasteboard.general` by polling `changeCount` on a 0.5 s
  timer (the pasteboard has no change notification API).
- **Three clip kinds**, captured in priority order per pasteboard
  change:
  1. **Image** — any `NSImage` on the pasteboard. Re-encoded to PNG.
  2. **Styled text** — RTF (`NSPasteboard.PasteboardType.rtf`); the
     plain-text rendering is kept alongside for search/dedup/fallback.
  3. **Plain text** — `public.utf8-plain-text`.
  Other file types are ignored.
- **History is in-memory; image bytes are on disk.** The ring (200
  entries) dies with the process. Text/RTF live in the ring directly.
  Images would bloat memory, so the full PNG is written once to a disk
  cache (`$TMPDIR/clipboard-manager-cache/<sha256>.png`) and only a
  small thumbnail + metadata is held in memory. The cache is bounded
  three ways: a file is deleted when its entry leaves the ring; a
  256 MB total-size cap evicts oldest-first; and the whole directory
  is wiped on launch *and* on `applicationWillTerminate`. So a fresh
  run starts clean and files never accumulate — no time-based expiry
  needed. Nothing text-related is ever written to disk.
- **De-duplicated.** Re-copying an existing clip moves it to the
  front. Paste-from-history does **not** reorder, so the list doesn't
  reshuffle while you scan it.
- **Password-safe.** Clips whose pasteboard carries
  `org.nspasteboard.ConcealedType` (password managers) or
  `org.nspasteboard.TransientType` are skipped.
- **One global hotkey:** `⌃⇧⌥⌘V` (Hyper+V), registered with Carbon
  `RegisterEventHotKey`. Pairs naturally with a Caps-Lock-as-Hyper
  remap (e.g. the sibling `caps` tool); the chord is a hardcoded
  constant in v0.
- **Searchable panel:** a borderless, flat **Catppuccin** command-
  palette panel — Latte in a light appearance, Frappé in a dark one,
  via dynamic `NSColor`s so "auto" (follow system) just works; nothing
  forces an appearance (also opened by left-clicking the menu-bar
  icon). Type to filter
  (case-insensitive `contains`), ↑/↓ to move, Return / double-click to
  paste. It dismisses the moment focus leaves it — a click anywhere
  outside, or Esc.
- On pick: write the clip to the pasteboard, hand focus back to the
  previously-frontmost app, then post a synthetic `⌘V`.
- Menu-bar status item right-click: clip count, the hotkey hint, an
  Accessibility-needed warning when untrusted, Clear History, Quit.

There is **no** cycle/bezel mode — an earlier iteration had a
Jumpcut-style press-to-step bezel; it was cut in favour of the single
searchable panel. Also out of scope: persistence, images/RTF/files,
pinned clips, editing before paste, per-app rules, configurable
hotkey, notarization.

## Permissions and stable signing

- **The hotkey** needs nothing — Carbon `RegisterEventHotKey` is not
  gated by Accessibility.
- **Auto-paste** synthesizes `⌘V` with `CGEvent.post`, which requires
  the app to be trusted for Accessibility. At launch the app calls
  `AXIsProcessTrustedWithOptions` with the prompt option; it keeps
  running regardless (capture + hotkey + panel all work without it).
  `paste` re-checks `AXIsProcessTrusted()` **live** every time, and if
  untrusted it leaves the clip on the pasteboard and flashes a HUD
  telling you to grant access / press `⌘V` yourself.
- The TCC Accessibility grant is keyed by bundle id **and code
  signature**. Ad-hoc signing (`codesign --sign -`) produces a *new*
  identity on every rebuild, so the grant silently dies each time you
  rebuild — the symptom is "paste stopped working after a rebuild".
  To fix that the build signs with a **stable self-signed identity**
  (`clipboard-manager-dev-knj`) imported into the login keychain, the
  same approach the sibling `caps` tool uses for its Input-Monitoring
  grant. Grant Accessibility once and it survives every subsequent
  `just build` / `just reload`. (For cask users on other machines the
  self-signed signature behaves like ad-hoc: clear the Gatekeeper
  quarantine once; the grant is per-machine anyway.)

## Tech approach

- Language: Swift, one source file (`clipboard-manager.swift`), built
  with `swiftc -O`. No Xcode project / SwiftPM. The `.app` bundle is
  hand-assembled by the `justfile` (Info.plist + binary + icon, then
  codesigned with the stable identity), matching the sibling tools.
- `Cocoa` for the status item / panel / HUD, `Carbon.HIToolbox` for
  the hotkey, `CoreGraphics` for the synthetic paste,
  `ApplicationServices` for the Accessibility check.
- `NSApplication` activation policy `.accessory`. A single
  `AppController` owns the history, timer, hotkey and panel; exposed
  as `AppController.shared` so the C hotkey callback can reach it.
- Pasteboard watcher: a `Timer` every 0.5 s compares
  `changeCount`. On change, if a `.string` is present and the
  pasteboard isn't concealed/transient, the trimmed string is pushed.
  When *we* write the pasteboard for a paste we record the new
  `changeCount` first so the watcher doesn't re-ingest it.
- Panel: a borderless `KeyablePanel: NSPanel` (`canBecomeKey == true`)
  whose content is a rounded, blurred `NSVisualEffectView` — a leading
  magnifier glyph + borderless `NSTextField` above a divider and an
  `.inset` `NSTableView` in an `NSScrollView`, with a faint key-hint
  footer. Placed centered in the upper third of the active screen.
  A local key monitor (removed-before-re-added so it can't stack and
  double-step) handles ↑/↓/Return/Esc; `windowDidResignKey` dismisses
  on any focus loss.
- Paste: set the pasteboard, `NSApp.hide(nil)` + reactivate the saved
  `prevApp` with `.activateIgnoringOtherApps`, then after a short
  delay post `v` down+up with `.maskCommand` on `.cghidEventTap`. The
  paste target is captured from `NSWorkspace.shared.frontmostApplication`
  *before* the panel takes focus.

## Layout

```
clipboard-manager/
  design.md                       this file
  plans/                          numbered build plans (historical)
  clipboard-manager.swift         the app
  Info.plist                      template baked into the .app
  make-icon.swift                 one-shot AppIcon.iconset generator
  dev.nymann.clipboard-manager.plist  LaunchAgent for start-at-login
  .signing/                       openssl.cnf + (gitignored) cert/key
  justfile                        signing-setup / build / reload / release
  .github/workflows/bump-cask.yml release → PR against homebrew-tap
  README.md
```

## Testing

No unit tests in v0, matching the sibling tools: the logic is a
pasteboard poll, one Carbon hotkey and a synthetic keystroke, whose
only real failure modes are environmental (Accessibility denied,
hotkey already taken). `just test` runs `swiftc -typecheck` over every
`.swift` source as the syntax/type gate.

## Possible later directions

Only if the friction actually shows up:

- Optional on-disk persistence behind a flag / menu toggle.
- Pinned/favourite clips that survive ring eviction.
- Configurable hotkey + cap via `~/.config/clipboard-manager/config`.
- Exclude-app list (don't capture while a given app is frontmost).
