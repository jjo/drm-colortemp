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
	rm -rf build-deb

# Debian package
VERSION ?= 0.0.0
ARCH ?= $(shell dpkg --print-architecture 2>/dev/null || echo amd64)
DEB_PKG = drm-colortemp_$(VERSION)_$(ARCH)
DEB_DIR = build-deb/$(DEB_PKG)

deb: $(TOOL) $(DAEMON)
	rm -rf build-deb
	# Binaries
	install -D -m 755 $(TOOL) $(DEB_DIR)/usr/bin/$(TOOL)
	install -D -m 755 $(DAEMON) $(DEB_DIR)/usr/bin/$(DAEMON)
	install -D -m 755 drm-colortemp-notify.sh $(DEB_DIR)/usr/bin/drm-colortemp-notify.sh
	install -D -m 755 drm-colortemp-notifier.sh $(DEB_DIR)/usr/bin/drm-colortemp-notifier.sh
	# Config
	install -D -m 644 drm-colortemp.conf $(DEB_DIR)/etc/default/drm-colortemp.conf
	# Systemd services
	install -D -m 644 drm-colortemp-daemon.service $(DEB_DIR)/usr/lib/systemd/system/drm-colortemp-daemon.service
	install -D -m 644 drm-colortemp-notifier.service $(DEB_DIR)/usr/lib/systemd/system/drm-colortemp-notifier.service
	# Docs
	install -D -m 644 README.md $(DEB_DIR)/usr/share/doc/drm-colortemp/README.md
	# Adjust paths from /usr/local/bin to /usr/bin for deb packaging
	sed -i 's|/usr/local/bin|/usr/bin|g' \
		$(DEB_DIR)/usr/lib/systemd/system/drm-colortemp-daemon.service \
		$(DEB_DIR)/usr/lib/systemd/system/drm-colortemp-notifier.service \
		$(DEB_DIR)/usr/bin/drm-colortemp-notifier.sh
	# DEBIAN control files
	mkdir -p $(DEB_DIR)/DEBIAN
	echo "Package: drm-colortemp" > $(DEB_DIR)/DEBIAN/control
	echo "Version: $(VERSION)" >> $(DEB_DIR)/DEBIAN/control
	echo "Architecture: $(ARCH)" >> $(DEB_DIR)/DEBIAN/control
	echo "Maintainer: jjo <jjo@users.noreply.github.com>" >> $(DEB_DIR)/DEBIAN/control
	echo "Depends: libdrm2" >> $(DEB_DIR)/DEBIAN/control
	echo "Recommends: libnotify-bin" >> $(DEB_DIR)/DEBIAN/control
	echo "Section: utils" >> $(DEB_DIR)/DEBIAN/control
	echo "Priority: optional" >> $(DEB_DIR)/DEBIAN/control
	echo "Homepage: https://github.com/jjo/drm-colortemp" >> $(DEB_DIR)/DEBIAN/control
	echo "Description: DRM color temperature control for COSMIC DE" >> $(DEB_DIR)/DEBIAN/control
	echo " Screen color temperature adjustment tool for COSMIC Desktop Environment," >> $(DEB_DIR)/DEBIAN/control
	echo " working around missing wlr-gamma-control-unstable-v1 protocol support." >> $(DEB_DIR)/DEBIAN/control
	echo " Provides automatic time-based switching and manual TTY-triggered overrides." >> $(DEB_DIR)/DEBIAN/control
	echo "/etc/default/drm-colortemp.conf" > $(DEB_DIR)/DEBIAN/conffiles
	printf '#!/bin/sh\nset -e\nif [ "$$1" = "configure" ]; then\n    systemctl daemon-reload || true\nfi\n' > $(DEB_DIR)/DEBIAN/postinst
	printf '#!/bin/sh\nset -e\nif [ "$$1" = "remove" ] || [ "$$1" = "purge" ]; then\n    systemctl stop drm-colortemp-daemon 2>/dev/null || true\n    systemctl stop drm-colortemp-notifier 2>/dev/null || true\n    systemctl disable drm-colortemp-daemon 2>/dev/null || true\n    systemctl disable drm-colortemp-notifier 2>/dev/null || true\n    systemctl daemon-reload || true\nfi\n' > $(DEB_DIR)/DEBIAN/prerm
	chmod 755 $(DEB_DIR)/DEBIAN/postinst $(DEB_DIR)/DEBIAN/prerm
	dpkg-deb --build --root-owner-group $(DEB_DIR) build-deb/
	@echo ""
	@echo "✓ Built build-deb/$(DEB_PKG).deb"

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

.PHONY: all clean install install-notifier uninstall deb
