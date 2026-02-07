# Desktop Notifications Feature

The daemon can notify you when it's time to apply color temperature changes.

## How It Works

The daemon monitors the time and sends a desktop notification X minutes before sunset/sunrise, reminding you to press Ctrl+Alt+F3+F2.

## Configuration

Edit `/etc/default/drm-colortemp.conf`:

```bash
# Enable notifications
NOTIFY_ENABLED=1

# Your username (the logged-in user who will see notifications)
NOTIFY_USER="your_username"

# How many minutes before sunset/sunrise to notify
NOTIFY_MINUTES_BEFORE=5
```

## Auto-detect Username

If you leave `NOTIFY_USER=""` empty, the daemon will try to auto-detect the logged-in user.

## Example

With these settings:
- SUNSET_HOUR=20
- NOTIFY_MINUTES_BEFORE=5

You'll get a notification at 19:55 (7:55 PM) saying:
```
🌙 Night Mode Ready
Press Ctrl+Alt+F3 then F2 to apply warm 3500K
```

## Manual Implementation

The daemon calls `/usr/local/bin/drm-colortemp-notify.sh` which you can also call manually:

```bash
# Test notification
sudo /usr/local/bin/drm-colortemp-notify.sh your_username 3500 night
```

## Troubleshooting

**No notifications appearing:**
1. Check NOTIFY_ENABLED=1 in config
2. Verify NOTIFY_USER is set correctly
3. Ensure `notify-send` is installed: `sudo apt install libnotify-bin`
4. Check daemon logs: `sudo journalctl -u drm-colortemp-daemon -f`

**Notifications to wrong user:**
- Set NOTIFY_USER explicitly in config file

**Want different notification times:**
- Adjust NOTIFY_MINUTES_BEFORE in config
- Set to 0 to notify exactly at sunset/sunrise
- Set to 15 for 15 minutes advance notice

## Implementation Note

Currently, notifications are sent but the actual color temperature application still requires manual TTY switch (Ctrl+Alt+F3+F2). The notification just reminds you to do it.

Future enhancement: Could add a button in the notification to trigger the application automatically (would require additional infrastructure).
