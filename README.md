# DRM Color Temperature Control for COSMIC DE

[![Build](https://github.com/jjo/drm-colortemp/actions/workflows/build.yml/badge.svg)](https://github.com/jjo/drm-colortemp/actions)

A workaround for adjusting screen color temperature on COSMIC Desktop Environment (Pop!_OS), until native gamma control is implemented ([cosmic-comp#2059](https://github.com/pop-os/cosmic-comp/issues/2059)).

## The Problem

COSMIC DE doesn't implement `wlr-gamma-control-unstable-v1` protocol yet, so tools like `redshift`, `wlsunset`, and `gammastep` don't work.

## The Solution

This package provides:
- **Direct DRM manipulation** tool to set color temperature
- **Automatic daemon** that applies settings when you switch to TTY3
- **Config file** with live reload (changes apply instantly via inotify)
- **Desktop notifications** to remind you when to apply (optional)

### How It Works

1. A daemon runs in the background monitoring TTY switches
2. You press **Ctrl+Alt+F3** (switches to TTY3)
3. Daemon detects the switch and applies gamma (COSMIC releases DRM lock on TTY3)
4. You immediately press **Ctrl+Alt+F2** (back to COSMIC)
5. Total time: ~2 seconds, screen flickers briefly

The gamma settings persist even after switching back to COSMIC!

## Build Dependencies (Pop!_OS / Ubuntu)

```bash
sudo apt install build-essential libdrm-dev linux-libc-dev libnotify-bin
```

- `build-essential` - gcc, make
- `libdrm-dev` - DRM/KMS headers and library
- `linux-libc-dev` - Linux kernel headers (ioctl definitions)
- `libnotify-bin` - `notify-send` for desktop notifications (optional)

## Quick Start

```bash
# Clone and build
git clone https://github.com/jjo/drm-colortemp.git
cd drm-colortemp
make

# Interactive installer (recommended)
sudo ./install_daemon.sh

# Or non-interactive
sudo make install
sudo make install-notifier  # Optional: desktop notifications
sudo systemctl enable --now drm-colortemp-daemon
sudo systemctl enable --now drm-colortemp-notifier  # Optional

# Use it! Press Ctrl+Alt+F3, then immediately Ctrl+Alt+F2
```

Pre-built binaries are also available on the [Releases page](https://github.com/jjo/drm-colortemp/releases).

## Daily Usage

### With Notifications (Optional)

At 19:55 (if sunset is 20:00), you'll see:
```
🌙 Night Mode Ready
Press Ctrl+Alt+F3 then F2 to apply warm 3500K
```

Press **Ctrl+Alt+F3** then **Ctrl+Alt+F2**. Done!

### Without Notifications

Just press **Ctrl+Alt+F3** then **Ctrl+Alt+F2** whenever you want to apply:
- Evening (after 20:00): Warm 3500K applied
- Morning (after 08:00): Neutral 6500K applied

### Manual Usage

You can also use the tool directly (requires TTY):

```bash
# From TTY (Ctrl+Alt+F3):
sudo drm_colortemp -d /dev/dri/card1 -t 3500
```

## Configuration

Edit the config file (changes apply automatically via inotify, no restart needed):
```bash
sudo nano /etc/default/drm-colortemp.conf
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| DEVICE | /dev/dri/card1 | DRM device path |
| DAY_TEMP | 6500 | Daytime temperature (Kelvin) |
| NIGHT_TEMP | 3500 | Nighttime temperature (Kelvin) |
| SUNSET_HOUR | 20 | When to switch to night mode (24h) |
| SUNRISE_HOUR | 8 | When to switch to day mode (24h) |
| MONITOR_TTY | 3 | Which TTY to monitor for auto-apply |
| NOTIFY_ENABLED | 0 | Enable desktop notifications (0/1) |
| NOTIFY_USER | "" | Username to send notifications to |
| NOTIFY_MINUTES_BEFORE | 5 | Minutes before sunset/sunrise to notify |
| VERBOSE | 0 | Enable verbose logging (0/1) |

### Color Temperature Guide

- **6500K** - Neutral daylight (default)
- **5500K** - Slightly warm
- **4500K** - Warm
- **3500K** - Evening/sunset
- **2700K** - Warm incandescent bulb
- **2000K** - Very warm candlelight

### Desktop Notifications

```bash
# Install notification service (if not done during initial install)
sudo make install-notifier

# Set in /etc/default/drm-colortemp.conf:
#   NOTIFY_ENABLED=1
#   NOTIFY_USER="your_username"

sudo systemctl enable --now drm-colortemp-notifier
```

See [NOTIFICATIONS.md](NOTIFICATIONS.md) for detailed documentation.

## Systemd Service Management

```bash
# Main daemon
sudo systemctl status drm-colortemp-daemon
sudo systemctl restart drm-colortemp-daemon
sudo journalctl -u drm-colortemp-daemon -f

# Notification daemon (if installed)
sudo systemctl status drm-colortemp-notifier
sudo journalctl -u drm-colortemp-notifier -f
```

## Troubleshooting

### "Permission denied" errors
- Ensure daemon is running: `sudo systemctl status drm-colortemp-daemon`
- Check device path in config: `/etc/default/drm-colortemp.conf`
- Verify you're on the correct TTY when applying

### Color not applying
- Check logs: `sudo journalctl -u drm-colortemp-daemon -f`
- Ensure you switch to TTY3 (not TTY1 or TTY2)
- Verify the tool works manually from TTY3

### Config changes not detected
- Check logs for inotify errors
- Make sure config file exists: `ls -la /etc/default/drm-colortemp.conf`
- Inotify watches the directory, so any editor (nano, vim, etc.) should work

### Notifications not appearing
- Check `NOTIFY_ENABLED=1` and `NOTIFY_USER` in config
- Ensure `notify-send` is installed: `sudo apt install libnotify-bin`
- Test manually: `sudo /usr/local/bin/drm-colortemp-notify.sh your_username 3500 night`

### Finding your DRM device
```bash
ls -la /dev/dri/
# Look for card0, card1, etc.
# Update DEVICE in /etc/default/drm-colortemp.conf
```

## Uninstallation

```bash
sudo make uninstall
# Config file is preserved at /etc/default/drm-colortemp.conf
# Remove manually if desired: sudo rm /etc/default/drm-colortemp.conf
```

## Technical Details

### Why This Works

The Linux DRM (Direct Rendering Manager) subsystem controls display output. Wayland compositors like COSMIC hold "DRM master" - exclusive control over the display. This prevents other processes from adjusting gamma.

When you switch to a text console (TTY3), COSMIC temporarily releases DRM master. Our daemon detects this switch and immediately applies the gamma settings before COSMIC reclaims control. When you switch back, the settings persist because COSMIC doesn't actively reset them.

### Components

1. **drm_colortemp** - CLI tool using DRM ioctls to set gamma LUTs
2. **drm_colortemp_daemon** - Monitors VT switches via `VT_GETSTATE` ioctl
3. **drm_device** - Shared DRM device detection and auto-fallback
4. **inotify** - Watches config file directory for changes without polling
5. **systemd** - Manages daemon lifecycle and logging
6. **notification system** - Optional reminder service with desktop notifications

### Why Not Just Use Redshift?

COSMIC needs to implement the `wlr-gamma-control-unstable-v1` Wayland protocol for tools like `redshift` and `wlsunset` to work. Until then, direct DRM manipulation is the only option.

Track progress: https://github.com/pop-os/cosmic-comp/issues/2059

## Future

Once COSMIC implements `wlr-gamma-control-unstable-v1`, you can switch to:
- `wlsunset` - Automatic sunset/sunrise calculation
- `gammastep` - Redshift fork for Wayland
- Native COSMIC settings

Until then, this provides a functional workaround!

## License

Apache License 2.0 - see [LICENSE](LICENSE)

## Credits

Color temperature algorithm based on Tanner Helland's work:
http://www.tannerhelland.com/4435/convert-temperature-rgb-algorithm-code/

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines.

This is a workaround tool. The real solution is for COSMIC to implement gamma control protocol. Consider contributing to https://github.com/pop-os/cosmic-comp.
