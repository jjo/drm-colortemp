#!/bin/bash
# install_daemon.sh - Interactive installer for DRM color temperature daemon
# Installs the Rust implementation (primary, `make rust-install`).

set -e

echo "=== DRM Color Temperature Daemon - Interactive Installer ==="
echo ""
echo "This script will guide you through installation and configuration."
echo "For non-interactive install, use: sudo make install"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (use sudo)"
    exit 1
fi

# Compile if the Rust binary doesn't exist
if [ ! -f "target/release/drm-colortemp-rs" ]; then
    echo "Binary not found, compiling..."
    if ! make; then
        echo ""
        echo "Error: Compilation failed"
        echo "Make sure you have a Rust toolchain installed (e.g. via rustup):"
        echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
        exit 1
    fi
    echo ""
fi

# Install main daemon (binary, systemd unit, and config if not already present)
echo "Installing main daemon..."
make install

echo ""

# Ask about notifications
read -p "Do you want to install desktop notifications? (y/n) " -n 1 -r
echo ""

NOTIFIER_INSTALLED=0
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Installing notification service..."
    make install-notifier
    NOTIFIER_INSTALLED=1

    # Try to detect current user
    DETECTED_USER=""
    if [ -n "$SUDO_USER" ]; then
        DETECTED_USER="$SUDO_USER"
    else
        DETECTED_USER=$(who | grep '(:0)' | awk '{print $1}' | head -1)
    fi

    echo ""
    if [ -n "$DETECTED_USER" ]; then
        echo "Detected user: $DETECTED_USER"
        read -p "Configure notifications for this user? (y/n) " -n 1 -r
        echo ""

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Enable notifications and set user in config
            sed -i "s/^NOTIFY_ENABLED=.*/NOTIFY_ENABLED=1/" /etc/default/drm-colortemp.conf
            sed -i "s/^NOTIFY_USER=.*/NOTIFY_USER=\"$DETECTED_USER\"/" /etc/default/drm-colortemp.conf
            echo "✓ Notifications enabled for user: $DETECTED_USER"
        fi
    else
        echo "Could not auto-detect user."
        echo "Please edit /etc/default/drm-colortemp.conf and set:"
        echo "  NOTIFY_ENABLED=1"
        echo "  NOTIFY_USER=\"your_username\""
    fi
fi

echo ""
echo "Configuration file: /etc/default/drm-colortemp.conf"
echo ""

# Ask to edit config
read -p "Do you want to edit the config file now? (y/n) " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    ${EDITOR:-nano} /etc/default/drm-colortemp.conf
    echo ""
fi

# Ask to enable and start services
read -p "Enable and start services now? (y/n) " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Enabling and starting main daemon..."
    systemctl enable --now drm-colortemp

    if [ $NOTIFIER_INSTALLED -eq 1 ]; then
        echo "Enabling and starting notifier daemon..."
        systemctl enable --now drm-colortemp-notifier
    fi

    echo ""
    echo "✓ Services are now running!"
    echo ""
    echo "Check status:"
    echo "  sudo systemctl status drm-colortemp"
    if [ $NOTIFIER_INSTALLED -eq 1 ]; then
        echo "  sudo systemctl status drm-colortemp-notifier"
    fi
    echo ""
    echo "View logs:"
    echo "  sudo journalctl -u drm-colortemp -f"
    if [ $NOTIFIER_INSTALLED -eq 1 ]; then
        echo "  sudo journalctl -u drm-colortemp-notifier -f"
    fi
else
    echo ""
    echo "Services installed but not started."
    echo ""
    echo "To enable and start manually:"
    echo "  sudo systemctl enable --now drm-colortemp"
    if [ $NOTIFIER_INSTALLED -eq 1 ]; then
        echo "  sudo systemctl enable --now drm-colortemp-notifier"
    fi
fi

echo ""
echo "=== Usage ==="
echo ""
echo "Apply color temperature (return-to-desktop key depends on your compositor's"
echo "VT — usually F1 or F2; check with: loginctl show-session \$XDG_SESSION_ID -p VTNr):"
echo "  1. Press Ctrl+Alt+F3"
echo "  2. Immediately press Ctrl+Alt+F1 (or F2)"
echo "  3. Done! Temperature applied."
echo ""
if [ $NOTIFIER_INSTALLED -eq 1 ]; then
    echo "You'll receive notifications when it's time to apply."
    echo ""
fi
echo "Edit config anytime (changes apply automatically):"
echo "  sudo nano /etc/default/drm-colortemp.conf"
echo ""
echo "✓ Installation complete!"
