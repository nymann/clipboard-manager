# clipboard-manager

A lightweight macOS clipboard history manager — a leaner replacement
for Jumpcut. It lives in the menu bar, watches the pasteboard for
text, styled text and image clips, and binds one global hotkey to a
searchable command-palette panel.

## What it does

- **`⌃⇧⌥⌘V` (Hyper+V) — searchable panel.** A blurred command-palette
  panel appears; type to filter, ↑/↓ to move, Return (or double-click)
  to paste the selected clip into the app you were in. Clicking
  anywhere outside it — or Esc — dismisses it. (Same as left-clicking
  the menu-bar icon.) The Hyper chord pairs with a Caps-Lock-as-Hyper
  remap such as the [`caps`](https://github.com/nymann/caps) tool. The
  panel is themed **Catppuccin** — Latte in Light, Frappé in Dark,
  following the system appearance automatically.
- Captures **text, styled text, and images**. Bold/italic copied from
  a rich editor stays bold/italic in the list (recoloured to the theme
  so it's readable) and pastes back styled.
- **Images don't sit in memory.** The full image is written once to a
  disk cache (`$TMPDIR/clipboard-manager-cache/<sha256>.png`); only a
  thumbnail + size/dimensions are kept in memory. The cache is bounded
  by the 200-entry ring, a 256 MB total cap (oldest evicted first),
  and is wiped on launch and on quit. Text/RTF are never written to
  disk; history (last 200, de-duplicated) resets on logout/reboot.
- Password-safe — clips marked concealed/transient (password managers,
  other clipboard tools) are skipped.

Right-click the menu-bar icon for the clip count, Accessibility status,
Clear History and Quit.

## Requirements

- macOS 14+
- Xcode command line tools (`xcode-select --install`) — `swiftc`,
  `iconutil`, `codesign`.
- [`just`](https://github.com/casey/just) — `brew install just`.

## Install

Via the Homebrew tap:

```sh
brew tap nymann/tap
brew install --cask nymann/tap/clipboard-manager
```

Or from source:

```sh
just signing-setup  # one-time: create the stable signing identity
just install        # build clipboard-manager.app, copy it to /Applications
just agent-install  # auto-start at login via launchd
```

### Accessibility permission

Auto-paste synthesizes `⌘V`, which macOS gates behind Accessibility.
On first launch you'll be prompted; grant it in **System Settings →
Privacy & Security → Accessibility**. Until then the panel and hotkey
still work — the selected clip is placed on the clipboard and you press
`⌘V` yourself (the app flashes a reminder).

The build is signed with a **stable self-signed identity** created by
`just signing-setup`, so the Accessibility grant survives rebuilds —
unlike ad-hoc signing, where every `just build` would void it. The
identity is local to your machine; the committed `.signing/openssl.cnf`
plus `just signing-setup` regenerate it, and the private key is
gitignored.

The app is not notarized. After a cask install, clear the Gatekeeper
quarantine once:

```sh
xattr -dr com.apple.quarantine /Applications/clipboard-manager.app
```

## All recipes

```
just signing-setup    One-time: create + import the stable signing identity
just build            Build clipboard-manager.app in the project directory
just reload           Rebuild and relaunch (Accessibility grant carries over)
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

After editing the source, the dev loop is just `just reload`.

## Notes

- The hotkey uses Carbon `RegisterEventHotKey` and needs no special
  permission; only auto-paste needs Accessibility.
- `LSUIElement` is set: menu-bar item only, no Dock icon.
- Hotkey and cap are hardcoded constants in `clipboard-manager.swift`
  (`enum Cfg`) for v0 — see `design.md` for rationale and possible
  later directions.

## Release flow

`just release X.Y.Z` builds, zips, tags `vX.Y.Z` and publishes a
GitHub release. The `.github/workflows/bump-cask.yml` workflow then
opens a PR against [`nymann/homebrew-tap`](https://github.com/nymann/homebrew-tap)
bumping the cask's `version` and `sha256`; merge it to ship.

The workflow needs a `HOMEBREW_TAP_TOKEN` repo secret (a fine-grained
PAT with Contents + Pull requests write on `nymann/homebrew-tap`) — see
the tap's README for the one-time setup.
