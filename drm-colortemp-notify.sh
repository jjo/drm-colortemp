#!/bin/bash
# drm-colortemp-notify.sh - Send desktop notification to user
# Called by daemon to notify user it's time to apply color temperature

USERNAME="$1"
TEMP="$2"
MODE="$3"  # "night" or "day"

if [ -z "$USERNAME" ] || [ -z "$TEMP" ] || [ -z "$MODE" ]; then
    echo "Usage: $0 <username> <temperature> <mode>"
    exit 1
fi

# Get user's UID
USER_UID=$(id -u "$USERNAME" 2>/dev/null)
if [ -z "$USER_UID" ]; then
    echo "Error: User $USERNAME not found"
    exit 1
fi

# Detect DRM device (use same logic as main tool)
DEVICE=""
if [ -r "/dev/dri/card1" ]; then
    DEVICE="/dev/dri/card1"
elif [ -r "/dev/dri/card0" ]; then
    DEVICE="/dev/dri/card0"
else
    # Search for first available card
    for i in {0..9}; do
        if [ -r "/dev/dri/card$i" ]; then
            DEVICE="/dev/dri/card$i"
            break
        fi
    done
fi

DEVICE_MSG=""
if [ -n "$DEVICE" ]; then
    DEVICE_MSG=" on ${DEVICE}"
fi

# Find the user's display and DBUS session
for DISPLAY_NUM in 0 1; do
    DISPLAY_VAR=":${DISPLAY_NUM}"
    
    # Try to find DBUS session from compositor process
    DBUS_SESSION=$(pgrep -u "$USERNAME" -x "cosmic-comp\|gnome-shell\|plasmashell\|kwin_wayland" | head -1)
    
    if [ -n "$DBUS_SESSION" ]; then
        # Get DBUS_SESSION_BUS_ADDRESS from the process environment
        DBUS_ADDR=$(grep -z DBUS_SESSION_BUS_ADDRESS /proc/$DBUS_SESSION/environ 2>/dev/null | tr '\0' '\n' | cut -d= -f2-)
        
        if [ -n "$DBUS_ADDR" ]; then
            # Set up notification based on mode
            if [ "$MODE" = "night" ]; then
                ICON="weather-clear-night"
                TITLE="🌙 Night Mode Ready"
                MESSAGE="Press Ctrl+Alt+F3 then F2 to apply warm ${TEMP}K${DEVICE_MSG}"
            else
                ICON="weather-clear"
                TITLE="☀️ Day Mode Ready"  
                MESSAGE="Press Ctrl+Alt+F3 then F2 to apply ${TEMP}K${DEVICE_MSG}"
            fi
            
            # Send notification as user
            su "$USERNAME" -c "DISPLAY=$DISPLAY_VAR DBUS_SESSION_BUS_ADDRESS=$DBUS_ADDR notify-send -i '$ICON' -u normal -t 10000 '$TITLE' '$MESSAGE'" 2>/dev/null
            
            if [ $? -eq 0 ]; then
                exit 0
            fi
        fi
    fi
done

# Fallback: try without specific DBUS (might work on some systems)
su "$USERNAME" -c "notify-send -i 'weather-clear-night' -u normal -t 10000 'Color Temperature' 'Time to adjust: ${TEMP}K${DEVICE_MSG}. Press Ctrl+Alt+F3 then F2'" 2>/dev/null

exit 0
