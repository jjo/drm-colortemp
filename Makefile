CC = gcc
CFLAGS = -Wall -O2 $(shell pkg-config --cflags libdrm 2>/dev/null || echo "-I/usr/include/libdrm -I/usr/include/drm")
LIBS = $(shell pkg-config --libs libdrm 2>/dev/null || echo "-ldrm") -lm

# Targets
TOOL = drm_colortemp
DAEMON = drm_colortemp_daemon

# Source files
TOOL_SRC = drm_colortemp.c drm_device.c
DAEMON_SRC = drm_colortemp_daemon_inotify.c drm_device.c

# Object files
TOOL_OBJ = drm_colortemp.o drm_device.o
DAEMON_OBJ = drm_colortemp_daemon_inotify.o drm_device.o

all: $(TOOL) $(DAEMON)

# Header dependencies
drm_device.o: drm_device.h
drm_colortemp.o: drm_device.h
drm_colortemp_daemon_inotify.o: drm_device.h

# Compile object files
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

# Link tool
$(TOOL): $(TOOL_OBJ)
	$(CC) $(CFLAGS) $(TOOL_OBJ) -o $(TOOL) $(LIBS)

# Link daemon  
$(DAEMON): $(DAEMON_OBJ)
	$(CC) $(CFLAGS) $(DAEMON_OBJ) -o $(DAEMON) $(LIBS)

clean:
	rm -f $(TOOL) $(DAEMON) *.o

# Main daemon install (non-interactive)
install: $(TOOL) $(DAEMON)
	@echo "Installing binaries..."
	install -D -m 755 $(TOOL) /usr/local/bin/$(TOOL)
	install -D -m 755 $(DAEMON) /usr/local/bin/$(DAEMON)
	@echo "Installing config file..."
	install -D -m 644 drm-colortemp.conf /etc/default/drm-colortemp.conf
	@echo "Installing systemd service..."
	install -D -m 644 drm-colortemp-daemon.service /etc/systemd/system/drm-colortemp-daemon.service
	systemctl daemon-reload
	@echo ""
	@echo "✓ Installation complete!"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Edit config: sudo nano /etc/default/drm-colortemp.conf"
	@echo "  2. Enable daemon: sudo systemctl enable drm-colortemp-daemon"
	@echo "  3. Start daemon: sudo systemctl start drm-colortemp-daemon"
	@echo ""
	@echo "Optional: Install notifications with 'make install-notifier'"

# Notification service install (non-interactive)
install-notifier:
	@echo "Installing notification service..."
	install -D -m 755 drm-colortemp-notify.sh /usr/local/bin/drm-colortemp-notify.sh
	install -D -m 755 drm-colortemp-notifier.sh /usr/local/bin/drm-colortemp-notifier.sh
	install -D -m 644 drm-colortemp-notifier.service /etc/systemd/system/drm-colortemp-notifier.service
	systemctl daemon-reload
	@echo ""
	@echo "✓ Notification service installed!"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Edit /etc/default/drm-colortemp.conf:"
	@echo "     NOTIFY_ENABLED=1"
	@echo "     NOTIFY_USER=\"your_username\""
	@echo "  2. Enable notifier: sudo systemctl enable drm-colortemp-notifier"
	@echo "  3. Start notifier: sudo systemctl start drm-colortemp-notifier"

# Uninstall everything
uninstall:
	@echo "Stopping services..."
	-systemctl stop drm-colortemp-daemon 2>/dev/null
	-systemctl stop drm-colortemp-notifier 2>/dev/null
	-systemctl disable drm-colortemp-daemon 2>/dev/null
	-systemctl disable drm-colortemp-notifier 2>/dev/null
	@echo "Removing files..."
	rm -f /usr/local/bin/$(TOOL)
	rm -f /usr/local/bin/$(DAEMON)
	rm -f /usr/local/bin/drm-colortemp-notify.sh
	rm -f /usr/local/bin/drm-colortemp-notifier.sh
	rm -f /etc/systemd/system/drm-colortemp-daemon.service
	rm -f /etc/systemd/system/drm-colortemp-notifier.service
	@echo "Keeping config file: /etc/default/drm-colortemp.conf"
	@echo "(Remove manually if desired)"
	systemctl daemon-reload
	@echo ""
	@echo "✓ Uninstall complete!"

.PHONY: all clean install install-notifier uninstall
