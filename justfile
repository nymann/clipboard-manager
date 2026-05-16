app := "clipboard-manager.app"
bin := "clipboard-manager"
agent := "dev.nymann.clipboard-manager"
plist := agent + ".plist"
signid := "clipboard-manager-dev-knj"

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

# One-time: create a stable self-signed code-signing identity and
# import it into the login keychain. A *stable* signature (vs ad-hoc,
# whose identity changes every rebuild) is what lets the macOS
# Accessibility/TCC grant survive `just build` — auto-paste needs it.
# Re-run only if the keychain identity is missing.
signing-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    cd .signing
    if [[ ! -f cert.pem || ! -f key.pem ]]; then
        openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
            -days 3650 -nodes -config openssl.cnf -extensions v3_req
    fi
    openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem \
        -out cert.p12 -name "{{signid}}" -passout pass:clipboard
    security import cert.p12 -k ~/Library/Keychains/login.keychain-db \
        -P clipboard -A -T /usr/bin/codesign
    echo "imported signing identity: {{signid}}"

# Assemble clipboard-manager.app and sign it with the stable identity
# (falls back to ad-hoc if the identity isn't in the keychain — run
# `just signing-setup` once so the Accessibility grant persists).
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
    if security find-certificate -c "{{signid}}" >/dev/null 2>&1; then
        codesign --force --sign "{{signid}}" \
            --identifier {{agent}} {{app}}
    else
        echo "warning: '{{signid}}' not in keychain — ad-hoc signing; the" >&2
        echo "Accessibility grant will reset on every rebuild. Run 'just signing-setup'." >&2
        codesign --force --sign - {{app}}
    fi

# Rebuild and relaunch the project-dir bundle (the stable signature
# means the Accessibility grant carries over — no re-grant needed).
reload: build
    #!/usr/bin/env bash
    set -euo pipefail
    pkill -x {{bin}} 2>/dev/null || true
    sleep 0.5
    open {{app}}

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
