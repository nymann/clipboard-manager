# clipboard-manager

A lightweight macOS clipboard history manager — a leaner replacement
for Jumpcut. It lives in the menu bar, watches the pasteboard for
plain-text clips, and gives you two global hotkeys to paste an old clip
straight back into whatever app you're working in.

## What it does

- **`⌘⌥V` — searchable panel.** A floating panel appears; type to
  filter, ↑/↓ to move, Return to paste, Esc to dismiss. (Same as
  left-clicking the menu-bar icon.)
- **`⌃⌥V` — cycle bezel.** A centered HUD shows the newest clip; each
  further press steps one clip older. Pause ~1 s and it pastes; press
  Esc to cancel.

Both hotkeys put the chosen text on the clipboard and paste it into the
app that was frontmost when you pressed the hotkey.

- Plain text only — formatting, images and files are ignored on
  purpose.
- In-memory only — history (last 200, de-duplicated) lives while the
  app runs and is **not** written to disk. It resets on logout/reboot.
- Password-safe — clips marked concealed/transient (password managers,
  other clipboard tools) are skipped.

Right-click the menu-bar icon for the clip count, Clear History,
Accessibility status and Quit.

## Requirements

- macOS 14+
- Xcode command line tools (`xcode-select --install`) — provides
  `swiftc` and `iconutil`.
- [`just`](https://github.com/casey/just) — `brew install just`.

## Install

Via the Homebrew tap:

```sh
brew tap nymann/tap
brew install --cask nymann/tap/clipboard-manager
```

Or from source:

```sh
just install        # build clipboard-manager.app and copy it to /Applications
just agent-install  # auto-start at login via launchd
```

### Accessibility permission

Auto-paste synthesizes `⌘V`, which macOS gates behind Accessibility.
On first launch you'll be prompted; grant it in **System Settings →
Privacy & Security → Accessibility** and relaunch. Until then, clips
are still captured and the hotkeys still work — the selected clip is
placed on the clipboard and you press `⌘V` yourself.

The app is ad-hoc signed (not notarized). Clear the Gatekeeper
quarantine once after a cask install:

```sh
xattr -dr com.apple.quarantine /Applications/clipboard-manager.app
```

## All recipes

```
just build            Build clipboard-manager.app in the project directory
just install          Build, then copy it to /Applications
just uninstall        Remove it from /Applications
just run              Run the binary directly (skips bundling)
just icon             Regenerate the reference AppIcon.iconset
just agent-install    Install the LaunchAgent so it starts at login
just agent-restart    Restart the LaunchAgent (use after rebuilding)
just agent-uninstall  Uninstall the LaunchAgent
just clean            Remove build artifacts
just release X.Y.Z    Tag, build, zip, publish a GitHub release
```

After editing the source, the typical loop is:

```sh
just install agent-restart
```

## Notes

- Hotkeys are registered with Carbon `RegisterEventHotKey` and need no
  special permission; only auto-paste needs Accessibility.
- The TCC Accessibility grant is keyed by bundle id + code signature,
  so the bundle is ad-hoc codesigned — enough for local use, and the
  grant persists across rebuilds.
- `LSUIElement` is set: menu-bar item only, no Dock icon.
- Hotkeys, cap and capture rules are hardcoded constants in
  `clipboard-manager.swift` (`enum Cfg`) for v0 — see `design.md` for
  the rationale and possible later directions.

## Release flow

`just release X.Y.Z` builds, zips, tags `vX.Y.Z` and publishes a
GitHub release. The `.github/workflows/bump-cask.yml` workflow then
opens a PR against [`nymann/homebrew-tap`](https://github.com/nymann/homebrew-tap)
bumping the cask's `version` and `sha256`; merge it to ship.

The workflow needs a `HOMEBREW_TAP_TOKEN` repo secret (a fine-grained
PAT with Contents + Pull requests write on `nymann/homebrew-tap`) — see
the tap's README for the one-time setup.
