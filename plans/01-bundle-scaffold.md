# 01 — .app bundle scaffold

Stand up the hand-rolled `.app` bundle pipeline with a stub binary, so
every later plan builds on a known-good build/sign/install path. No
clipboard logic yet. See `design.md` for the rationale.

## Pre-conditions

- Fresh repo: `design.md` and `plans/` exist, nothing else at root.
- `swiftc`, `just`, `iconutil` available.

## Steps

1. `.gitignore` with at least:

   ```
   clipboard-manager.app/
   build/
   *.swiftmodule
   .DS_Store
   .run-plans-worktree/
   ```

2. `Info.plist` (plain XML plist):

   - `CFBundleIdentifier` = `dev.nymann.clipboard-manager`
   - `CFBundleExecutable` = `clipboard-manager`
   - `CFBundleName` = `Clipboard Manager`
   - `CFBundlePackageType` = `APPL`
   - `CFBundleShortVersionString` = `0.1.0`
   - `CFBundleVersion` = `1`
   - `LSUIElement` = `true`
   - `CFBundleIconFile` = `AppIcon`

3. `clipboard-manager.swift` stub: an `.accessory` `NSApplication`
   with an empty `AppController` delegate that just creates a status
   item with an SF Symbol. `swiftc -typecheck` must pass.

4. `make-icon.swift`: generate the 10-size `AppIcon.iconset`
   (clipboard SF Symbol on a coloured rounded square), modelled on the
   sibling `nosleep`/`micflip` icon generators.

5. `justfile` (model on `nosleep`): `build` (assemble + icns +
   ad-hoc sign), `install`/`uninstall` (/Applications), `run`,
   `agent-install`/`agent-restart`/`agent-uninstall`, `clean`,
   `test` (typecheck every `.swift`), `release VERSION`.

6. `dev.nymann.clipboard-manager.plist` LaunchAgent
   (`RunAtLoad`, `KeepAlive`).

## Verification

- `just test` passes.
- `just build` produces `clipboard-manager.app` with
  `Contents/{Info.plist,MacOS/clipboard-manager,Resources/AppIcon.icns}`.
- `codesign -dv clipboard-manager.app` reports an ad-hoc signature.
- Launching the bundle shows a menu-bar icon and no Dock icon.

## Commit

`feat: scaffold .app bundle assembly`
