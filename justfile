app := "clipboard-manager.app"
bin := "clipboard-manager"
agent := "dev.nymann.clipboard-manager"
plist := agent + ".plist"

default: build

# Type-check every .swift source — the syntax/type gate run-plans
# calls between plans. There is no unit-test suite in v0 (see design.md).
test:
    #!/usr/bin/env bash
    set -euo pipefail
    shopt -s nullglob
    sources=(*.swift)
    if (( ${#sources[@]} == 0 )); then
        echo "no .swift sources yet — nothing to type-check"
        exit 0
    fi
    for f in "${sources[@]}"; do
        echo "==> swiftc -typecheck $f"
        swiftc -typecheck "$f"
    done

# Assemble clipboard-manager.app in the project dir and ad-hoc sign it.
build:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf {{app}}
    mkdir -p {{app}}/Contents/MacOS {{app}}/Contents/Resources
    swiftc -O {{bin}}.swift -o {{app}}/Contents/MacOS/{{bin}}
    iconset="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$iconset"
    swift make-icon.swift "$iconset"
    iconutil -c icns "$iconset" -o {{app}}/Contents/Resources/AppIcon.icns
    cp Info.plist {{app}}/Contents/Info.plist
    codesign --force --sign - {{app}}

# Build, then copy clipboard-manager.app to /Applications.
install: build
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf /Applications/{{app}}
    cp -R {{app}} /Applications/

# Remove clipboard-manager.app from /Applications.
uninstall:
    rm -rf /Applications/{{app}}

# Run the binary directly without bundling (hotkeys work; the
# Accessibility grant won't persist for an un-bundled binary).
run:
    swift {{bin}}.swift

# Regenerate the committed reference iconset preview (optional).
icon:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf AppIcon.iconset && mkdir AppIcon.iconset
    swift make-icon.swift AppIcon.iconset

# Install the LaunchAgent so it starts at login.
agent-install:
    #!/usr/bin/env bash
    set -e
    cp {{plist}} ~/Library/LaunchAgents/
    launchctl bootout "gui/$(id -u)/{{agent}}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/{{plist}}

# Restart the LaunchAgent (use after rebuilding).
agent-restart:
    launchctl kickstart -k "gui/$(id -u)/{{agent}}"

# Uninstall the LaunchAgent.
agent-uninstall:
    -launchctl bootout "gui/$(id -u)/{{agent}}"
    rm -f ~/Library/LaunchAgents/{{plist}}

# Remove build artifacts.
clean:
    rm -rf {{app}} build AppIcon.iconset

# Tag, build, zip and publish a GitHub release. Triggers the
# bump-cask workflow which opens a PR against nymann/homebrew-tap.
release VERSION:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "working tree dirty — commit or stash before releasing" >&2
        exit 1
    fi
    just build
    mkdir -p build
    rm -f build/{{bin}}-*.zip
    ditto -c -k --sequesterRsrc --keepParent {{app}} build/{{bin}}-{{VERSION}}.zip
    git tag -a v{{VERSION}} -m "v{{VERSION}}"
    git push origin v{{VERSION}}
    gh release create v{{VERSION}} build/{{bin}}-{{VERSION}}.zip \
        --title "v{{VERSION}}" --generate-notes
