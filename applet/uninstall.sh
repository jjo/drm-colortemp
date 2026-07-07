#!/bin/bash
# uninstall.sh — remove cosmic-applet-colortemp (leaves drm-colortemp itself alone)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo ./uninstall.sh" >&2; exit 1; }

rm -f /usr/local/bin/cosmic-applet-colortemp
rm -f /usr/local/bin/drm-colortemp-apply
rm -f /usr/share/applications/io.github.jjo.CosmicAppletColortemp.desktop
rm -f /usr/share/icons/hicolor/scalable/apps/io.github.jjo.CosmicAppletColortemp-symbolic.svg
rm -f /etc/sudoers.d/drm-colortemp-applet
echo "Removed. (Remove the applet from your panel in COSMIC Settings if still listed.)"
