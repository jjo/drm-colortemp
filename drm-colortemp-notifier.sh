#!/bin/bash
# drm-colortemp-notifier.sh - Send periodic notifications to remind user to apply color temp
# This runs as a separate lightweight daemon

CONFIG_FILE="/etc/default/drm-colortemp.conf"

# Source config
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

# Defaults
NOTIFY_ENABLED=${NOTIFY_ENABLED:-0}
NOTIFY_USER=${NOTIFY_USER:-$SUDO_USER}
NOTIFY_MINUTES_BEFORE=${NOTIFY_MINUTES_BEFORE:-5}
SUNSET_HOUR=${SUNSET_HOUR:-20}
SUNRISE_HOUR=${SUNRISE_HOUR:-8}
NIGHT_TEMP=${NIGHT_TEMP:-3500}
DAY_TEMP=${DAY_TEMP:-6500}

if [ "$NOTIFY_ENABLED" != "1" ]; then
    echo "Notifications disabled in config"
    exit 0
fi

if [ -z "$NOTIFY_USER" ]; then
    # Try to detect logged-in user
    NOTIFY_USER=$(who | grep '(:0)' | awk '{print $1}' | head -1)
    if [ -z "$NOTIFY_USER" ]; then
        echo "Error: Could not detect user. Set NOTIFY_USER in config."
        exit 1
    fi
fi

echo "Notifier started for user: $NOTIFY_USER"
echo "Sunset: ${SUNSET_HOUR}:00 (notify at $(date -d "${SUNSET_HOUR}:00 - ${NOTIFY_MINUTES_BEFORE} minutes" +%H:%M))"
echo "Sunrise: ${SUNRISE_HOUR}:00 (notify at $(date -d "${SUNRISE_HOUR}:00 - ${NOTIFY_MINUTES_BEFORE} minutes" +%H:%M))"

SUNSET_NOTIFIED=0
SUNRISE_NOTIFIED=0

while true; do
    HOUR=$(date +%H)
    MINUTE=$(date +%M)
    CURRENT_MINUTES=$((10#$HOUR * 60 + 10#$MINUTE))
    
    SUNSET_NOTIFY_TIME=$((SUNSET_HOUR * 60 - NOTIFY_MINUTES_BEFORE))
    SUNRISE_NOTIFY_TIME=$((SUNRISE_HOUR * 60 - NOTIFY_MINUTES_BEFORE))
    
    # Check for sunset notification
    if [ $CURRENT_MINUTES -eq $SUNSET_NOTIFY_TIME ] && [ $SUNSET_NOTIFIED -eq 0 ]; then
        echo "$(date): Sending sunset notification"
        /usr/local/bin/drm-colortemp-notify.sh "$NOTIFY_USER" "$NIGHT_TEMP" "night"
        SUNSET_NOTIFIED=1
    elif [ $CURRENT_MINUTES -ne $SUNSET_NOTIFY_TIME ]; then
        SUNSET_NOTIFIED=0
    fi
    
    # Check for sunrise notification
    if [ $CURRENT_MINUTES -eq $SUNRISE_NOTIFY_TIME ] && [ $SUNRISE_NOTIFIED -eq 0 ]; then
        echo "$(date): Sending sunrise notification"
        /usr/local/bin/drm-colortemp-notify.sh "$NOTIFY_USER" "$DAY_TEMP" "day"
        SUNRISE_NOTIFIED=1
    elif [ $CURRENT_MINUTES -ne $SUNRISE_NOTIFY_TIME ]; then
        SUNRISE_NOTIFIED=0
    fi
    
    sleep 60  # Check every minute
done
