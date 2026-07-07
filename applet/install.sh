#!/bin/bash
# install.sh — build and install cosmic-applet-colortemp
# Run from the project directory: sudo ./install.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo: sudo ./install.sh" >&2
    exit 1
fi

APPLET_USER="${SUDO_USER:-}"
if [ -z "$APPLET_USER" ]; then
    read -rp "Username that should be allowed to apply color temperature: " APPLET_USER
fi
if ! id -u "$APPLET_USER" >/dev/null 2>&1; then
    echo "User '$APPLET_USER' not found" >&2
    exit 1
fi

BIN=target/release/cosmic-applet-colortemp

# 1. Build (as the invoking user, not root, if possible)
if [ ! -x "$BIN" ]; then
    echo "==> Building (first build pulls libcosmic; takes ~10 min)..."
    if command -v sudo >/dev/null && [ -n "$APPLET_USER" ]; then
        sudo -u "$APPLET_USER" cargo build --release
    else
        cargo build --release
    fi
fi

echo "==> Installing applet binary"
install -Dm755 "$BIN" /usr/local/bin/cosmic-applet-colortemp

echo "==> Installing root helper"
install -Dm755 helper/drm-colortemp-apply /usr/local/bin/drm-colortemp-apply

echo "==> Installing desktop entry and icon"
install -Dm644 data/io.github.jjo.CosmicAppletColortemp.desktop \
    /usr/share/applications/io.github.jjo.CosmicAppletColortemp.desktop
install -Dm644 data/icons/io.github.jjo.CosmicAppletColortemp-symbolic.svg \
    /usr/share/icons/hicolor/scalable/apps/io.github.jjo.CosmicAppletColortemp-symbolic.svg
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q /usr/share/icons/hicolor || true

echo "==> Installing sudoers rule (only the 3 exact helper commands, for $APPLET_USER)"
SUDOERS_FILE=/etc/sudoers.d/drm-colortemp-applet
TMP=$(mktemp)
cat > "$TMP" <<EOF
# Allow $APPLET_USER to trigger drm-colortemp's VT-switch helper without a
# password. Installed by cosmic-applet-colortemp. Remove with uninstall.sh.
$APPLET_USER ALL=(root) NOPASSWD: /usr/local/bin/drm-colortemp-apply auto, /usr/local/bin/drm-colortemp-apply night, /usr/local/bin/drm-colortemp-apply day
EOF
visudo -cf "$TMP" >/dev/null   # validate before installing
install -m 0440 "$TMP" "$SUDOERS_FILE"
rm -f "$TMP"

# Sanity checks
if ! systemctl is-active --quiet drm-colortemp-daemon.service 2>/dev/null \
   && ! systemctl is-active --quiet drm-colortemp.service 2>/dev/null; then
    echo ""
    echo "WARNING: the drm-colortemp daemon does not appear to be running."
    echo "The applet needs it. Install/enable it first:"
    echo "  https://github.com/jjo/drm-colortemp"
    echo "  sudo systemctl enable --now drm-colortemp-daemon"
fi

echo ""
echo "Done. Add the applet to your panel:"
echo "  COSMIC Settings -> Desktop -> Panel -> Configure panel applets -> Add 'Color Temperature'"
