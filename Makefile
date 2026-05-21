# Default to Rust build
.DEFAULT_GOAL := rust

# =============================================================================
# RUST IMPLEMENTATION (v2.0) - PRIMARY TARGETS
# =============================================================================

# Installed binary name (used by users/systemd).
RUST_TOOL = drm-colortemp
# Cargo-produced binary name (from Cargo.toml `name = drm-colortemp-rs`).
CARGO_BIN = drm-colortemp-rs
RUST_DAEMON = drm-colortemp-daemon
RUST_SERVICE = scripts/drm-colortemp.service

.PHONY: rust rust-build rust-test rust-install rust-uninstall rust-clean
.PHONY: legacy legacy-tool legacy-daemon legacy-test legacy-clean
.PHONY: legacy-install legacy-install-notifier legacy-uninstall

# Build Rust implementation (primary)
rust: rust-build
	@echo ""
	@echo "✓ Rust build complete"
	@echo "  Binary: $(RUST_TOOL)"
	@echo "  Run: cargo run --release -- --help"

rust-build:
	@echo "Building Rust implementation..."
	cargo build --release
	@echo ""
	@echo "✓ Rust build complete"
	@echo "  Binary: target/release/$(CARGO_BIN)"
	@echo "  Run: ./target/release/$(CARGO_BIN) --help"

rust-test:
	@echo "Running Rust unit tests..."
	cargo test --release

rust-install: rust-build
	@echo "Installing Rust implementation..."
	install -D -m 755 target/release/$(CARGO_BIN) /usr/local/bin/$(RUST_TOOL)
	install -D -m 644 $(RUST_SERVICE) /etc/systemd/system/$(RUST_TOOL).service
	systemctl daemon-reload
	@echo ""
	@echo "✓ Rust installation complete!"
	@echo ""
	@echo "Next steps:"
	@echo " 1. Edit config: sudo nano /etc/default/drm-colortemp.conf"
	@echo " 2. Enable daemon: sudo systemctl enable $(RUST_TOOL)"
	@echo " 3. Start daemon: sudo systemctl start $(RUST_TOOL)"

rust-uninstall:
	@echo "Removing Rust implementation..."
	rm -f /usr/local/bin/$(RUST_TOOL)
	rm -f /etc/systemd/system/$(RUST_TOOL).service
	systemctl daemon-reload
	@echo "✓ Rust uninstall complete"

rust-clean:
	cargo clean
	@echo "✓ Rust clean complete"

# =============================================================================
# DEBIAN PACKAGING (Rust)
# =============================================================================
# Builds a .deb containing the Rust binary + systemd units + notifier scripts.
# Replaces the C-era `deb` target referenced by .github/workflows/{build,release}.yml.

VERSION ?= 0.0.0
ARCH    ?= $(shell dpkg --print-architecture 2>/dev/null || echo amd64)
DEB_PKG  = drm-colortemp_$(VERSION)_$(ARCH)
DEB_DIR  = build-deb/$(DEB_PKG)

.PHONY: deb
deb: rust-build
	@echo "Building Debian package $(DEB_PKG).deb..."
	rm -rf build-deb
	# Cargo names the binary $(CARGO_BIN); ship as /usr/bin/$(RUST_TOOL).
	install -D -m 755 target/release/$(CARGO_BIN) $(DEB_DIR)/usr/bin/$(RUST_TOOL)
	# Notifier helpers stay shell scripts.
	install -D -m 755 $(SCRIPTS_DIR)/drm-colortemp-notify.sh   $(DEB_DIR)/usr/bin/drm-colortemp-notify.sh
	install -D -m 755 $(SCRIPTS_DIR)/drm-colortemp-notifier.sh $(DEB_DIR)/usr/bin/drm-colortemp-notifier.sh
	# Default config; binary defaults to /etc/default/drm-colortemp.conf
	# (matches the C daemon's historical path).
	install -D -m 644 drm-colortemp.conf $(DEB_DIR)/etc/default/drm-colortemp.conf
	# Systemd units.
	install -D -m 644 $(SCRIPTS_DIR)/drm-colortemp.service          $(DEB_DIR)/usr/lib/systemd/system/drm-colortemp.service
	install -D -m 644 $(SCRIPTS_DIR)/drm-colortemp-notifier.service $(DEB_DIR)/usr/lib/systemd/system/drm-colortemp-notifier.service
	# Docs.
	install -D -m 644 README.md $(DEB_DIR)/usr/share/doc/drm-colortemp/README.md
	# Rewrite hardcoded /usr/local/bin → /usr/bin for packaged layout.
	sed -i 's|/usr/local/bin|/usr/bin|g' \
		$(DEB_DIR)/usr/lib/systemd/system/drm-colortemp.service \
		$(DEB_DIR)/usr/lib/systemd/system/drm-colortemp-notifier.service \
		$(DEB_DIR)/usr/bin/drm-colortemp-notifier.sh
	# DEBIAN/control: Rust binary needs no libdrm runtime dep (raw ioctls).
	mkdir -p $(DEB_DIR)/DEBIAN
	{ \
		echo "Package: drm-colortemp"; \
		echo "Version: $(VERSION)"; \
		echo "Architecture: $(ARCH)"; \
		echo "Maintainer: jjo <jjo@users.noreply.github.com>"; \
		echo "Depends: libc6, libgcc-s1"; \
		echo "Recommends: libnotify-bin"; \
		echo "Section: utils"; \
		echo "Priority: optional"; \
		echo "Homepage: https://github.com/jjo/drm-colortemp"; \
		echo "Description: DRM color temperature control for COSMIC DE"; \
		echo " Screen color temperature adjustment tool for COSMIC Desktop Environment,"; \
		echo " working around missing wlr-gamma-control-unstable-v1 protocol support."; \
		echo " Time-based scheduling, TTY-triggered overrides, connector filtering."; \
	} > $(DEB_DIR)/DEBIAN/control
	echo "/etc/default/drm-colortemp.conf" > $(DEB_DIR)/DEBIAN/conffiles
	printf '#!/bin/sh\nset -e\nif [ "$$1" = "configure" ]; then\n    systemctl daemon-reload || true\nfi\n' \
		> $(DEB_DIR)/DEBIAN/postinst
	printf '#!/bin/sh\nset -e\nif [ "$$1" = "remove" ] || [ "$$1" = "purge" ]; then\n    systemctl stop drm-colortemp 2>/dev/null || true\n    systemctl stop drm-colortemp-notifier 2>/dev/null || true\n    systemctl disable drm-colortemp 2>/dev/null || true\n    systemctl disable drm-colortemp-notifier 2>/dev/null || true\n    systemctl daemon-reload || true\nfi\n' \
		> $(DEB_DIR)/DEBIAN/prerm
	chmod 755 $(DEB_DIR)/DEBIAN/postinst $(DEB_DIR)/DEBIAN/prerm
	dpkg-deb --build --root-owner-group $(DEB_DIR) build-deb/
	@echo ""
	@echo "✓ Built build-deb/$(DEB_PKG).deb"

# =============================================================================
# C IMPLEMENTATION (LEGACY) - PREFIXED TARGETS
# =============================================================================

CC = gcc
CFLAGS = -Wall -O2 $(shell pkg-config --cflags libdrm 2>/dev/null || echo "-I/usr/include/libdrm -I/usr/include/drm")
LIBS = $(shell pkg-config --libs libdrm 2>/dev/null || echo "-ldrm") -lm

# Source directory
C_SRC_DIR = src-c

# Scripts directory
SCRIPTS_DIR = scripts

# Targets
LEGACY_TOOL = drm_colortemp
LEGACY_DAEMON = drm_colortemp_daemon

# Source files
LEGACY_TOOL_SRC = $(C_SRC_DIR)/drm_colortemp.c $(C_SRC_DIR)/drm_device.c
LEGACY_DAEMON_SRC = $(C_SRC_DIR)/drm_colortemp_daemon_inotify.c $(C_SRC_DIR)/drm_device.c

# Object files
LEGACY_TOOL_OBJ = $(C_SRC_DIR)/drm_colortemp.o $(C_SRC_DIR)/drm_colortemp_utils.o $(C_SRC_DIR)/drm_device.o
LEGACY_DAEMON_OBJ = $(C_SRC_DIR)/drm_colortemp_daemon_inotify.o $(C_SRC_DIR)/drm_colortemp_utils.o $(C_SRC_DIR)/drm_device.o $(C_SRC_DIR)/drm_config.o

# Legacy: Build both tool and daemon
legacy: legacy-tool legacy-daemon
	@echo ""
	@echo "✓ Legacy C build complete"
	@echo "  Tool: $(LEGACY_TOOL)"
	@echo "  Daemon: $(LEGACY_DAEMON)"

# Legacy: Build tool only
legacy-tool: $(LEGACY_TOOL)
	@echo "✓ Legacy tool built: $(LEGACY_TOOL)"

# Legacy: Build daemon only
legacy-daemon: $(LEGACY_DAEMON)
	@echo "✓ Legacy daemon built: $(LEGACY_DAEMON)"

# Legacy: Build test binary
legacy-test: legacy-test-config
	@echo "✓ Legacy test built"

legacy-test-config: $(C_SRC_DIR)/test_config
	@echo "✓ Legacy test_config built"

# Legacy: Install
legacy-install: legacy
	@echo "Installing legacy C implementation..."
	install -D -m 755 $(LEGACY_TOOL) /usr/local/bin/$(LEGACY_TOOL)
	install -D -m 755 $(LEGACY_DAEMON) /usr/local/bin/$(LEGACY_DAEMON)
	install -D -m 644 drm-colortemp.conf /etc/default/drm-colortemp.conf
	install -D -m 644 $(SCRIPTS_DIR)/drm-colortemp-daemon.service /etc/systemd/system/drm-colortemp-daemon.service
	systemctl daemon-reload
	@echo ""
	@echo "✓ Legacy installation complete!"
	@echo ""
	@echo "Next steps:"
	@echo " 1. Edit config: sudo nano /etc/default/drm-colortemp.conf"
	@echo " 2. Enable daemon: sudo systemctl enable drm-colortemp-daemon"
	@echo " 3. Start daemon: sudo systemctl start drm-colortemp-daemon"
	@echo ""
	@echo "Optional: Install notifications with 'make legacy-install-notifier'"

# Legacy: Install notifier
legacy-install-notifier:
	@echo "Installing legacy notification service..."
	install -D -m 755 $(SCRIPTS_DIR)/drm-colortemp-notify.sh /usr/local/bin/drm-colortemp-notify.sh
	install -D -m 755 $(SCRIPTS_DIR)/drm-colortemp-notifier.sh /usr/local/bin/drm-colortemp-notifier.sh
	install -D -m 644 $(SCRIPTS_DIR)/drm-colortemp-notifier.service /etc/systemd/system/drm-colortemp-notifier.service
	systemctl daemon-reload
	@echo ""
	@echo "✓ Legacy notification service installed!"

# Legacy: Uninstall
legacy-uninstall:
	@echo "Removing legacy C implementation..."
	rm -f /usr/local/bin/$(LEGACY_TOOL)
	rm -f /usr/local/bin/$(LEGACY_DAEMON)
	rm -f /usr/local/bin/drm-colortemp-notify.sh
	rm -f /usr/local/bin/drm-colortemp-notifier.sh
	rm -f /etc/systemd/system/drm-colortemp-daemon.service
	rm -f /etc/systemd/system/drm-colortemp-notifier.service
	systemctl daemon-reload
	@echo "✓ Legacy uninstall complete"

# Legacy: Clean
legacy-clean:
	rm -f $(LEGACY_TOOL) $(LEGACY_DAEMON) $(C_SRC_DIR)/test_config $(C_SRC_DIR)/*.o
	rm -rf build-deb
	@echo "✓ Legacy clean complete"

# Legacy: Build Debian package
legacy-deb: legacy
	@echo "Building Debian package..."
	@echo "Note: Use 'make deb' for Rust version"
	@echo "This builds legacy C version package"
	rm -rf build-deb
	VERSION=1.3.0 ARCH=$(shell dpkg --print-architecture 2>/dev/null || echo amd64) DEB_PKG=drm-colortemp-legacy_$(VERSION)_$(ARCH) DEB_DIR=build-deb/$(DEB_PKG) bash -c '\
	mkdir -p $$(dirname $$DEB_DIR) && \
	rm -rf $$DEB_DIR && \
	install -D -m 755 $(LEGACY_TOOL) $$DEB_DIR/usr/bin/$(LEGACY_TOOL) && \
	install -D -m 755 $(LEGACY_DAEMON) $$DEB_DIR/usr/bin/$(LEGACY_DAEMON) && \
	install -D -m 755 $(SCRIPTS_DIR)/drm-colortemp-notify.sh $$DEB_DIR/usr/bin/drm-colortemp-notify.sh && \
	install -D -m 755 $(SCRIPTS_DIR)/drm-colortemp-notifier.sh $$DEB_DIR/usr/bin/drm-colortemp-notifier.sh && \
	install -D -m 644 drm-colortemp.conf $$DEB_DIR/etc/default/drm-colortemp.conf && \
	install -D -m 644 $(SCRIPTS_DIR)/drm-colortemp-daemon.service $$DEB_DIR/usr/lib/systemd/system/drm-colortemp-daemon.service && \
	install -D -m 644 $(SCRIPTS_DIR)/drm-colortemp-notifier.service $$DEB_DIR/usr/lib/systemd/system/drm-colortemp-notifier.service && \
	install -D -m 644 README.md $$DEB_DIR/usr/share/doc/drm-colortemp-legacy/README.md && \
	mkdir -p $$DEB_DIR/DEBIAN && \
	echo "Package: drm-colortemp-legacy" > $$DEB_DIR/DEBIAN/control && \
	echo "Version: $(VERSION)" >> $$DEB_DIR/DEBIAN/control && \
	echo "Architecture: $$ARCH" >> $$DEB_DIR/DEBIAN/control && \
	echo "Maintainer: jjo <jjo@users.noreply.github.com>" >> $$DEB_DIR/DEBIAN/control && \
	echo "Depends: libdrm2" >> $$DEB_DIR/DEBIAN/control && \
	echo "Recommends: libnotify-bin" >> $$DEB_DIR/DEBIAN/control && \
	echo "Section: utils" >> $$DEB_DIR/DEBIAN/control && \
	echo "Priority: optional" >> $$DEB_DIR/DEBIAN/control && \
	echo "Homepage: https://github.com/jjo/drm-colortemp" >> $$DEB_DIR/DEBIAN/control && \
	echo "Description: DRM color temperature control (C version)" >> $$DEB_DIR/DEBIAN/control && \
	dpkg-deb --build --root-owner-group $$DEB_DIR build-deb/ && \
	echo "" && \
	echo "✓ Built build-deb/$$(basename $$DEB_DIR).deb"'

# =============================================================================
# C OBJECT FILE COMPILATION (LEGACY)
# =============================================================================

# Header dependencies
$(C_SRC_DIR)/drm_device.o: $(C_SRC_DIR)/drm_device.h
$(C_SRC_DIR)/drm_colortemp.o: $(C_SRC_DIR)/drm_device.h $(C_SRC_DIR)/drm_colortemp_utils.h $(C_SRC_DIR)/drm_log.h
$(C_SRC_DIR)/drm_colortemp_daemon_inotify.o: $(C_SRC_DIR)/drm_device.h $(C_SRC_DIR)/drm_colortemp_utils.h $(C_SRC_DIR)/drm_config.h $(C_SRC_DIR)/drm_log.h
$(C_SRC_DIR)/drm_colortemp_utils.o: $(C_SRC_DIR)/drm_colortemp_utils.h
$(C_SRC_DIR)/drm_config.o: $(C_SRC_DIR)/drm_config.h $(C_SRC_DIR)/drm_device.h $(C_SRC_DIR)/drm_log.h

# Compile object files
$(C_SRC_DIR)/%.o: $(C_SRC_DIR)/%.c
	$(CC) $(CFLAGS) -c $< -o $@

# Link tool
$(LEGACY_TOOL): $(LEGACY_TOOL_OBJ)
	$(CC) $(CFLAGS) $(LEGACY_TOOL_OBJ) -o $(LEGACY_TOOL) $(LIBS)

# Link daemon 
$(LEGACY_DAEMON): $(LEGACY_DAEMON_OBJ)
	$(CC) $(CFLAGS) $(LEGACY_DAEMON_OBJ) -o $(LEGACY_DAEMON) $(LIBS)

# Test binary
$(C_SRC_DIR)/test_config: $(C_SRC_DIR)/test_config.c $(C_SRC_DIR)/drm_colortemp_daemon_inotify_test.o $(C_SRC_DIR)/drm_colortemp_utils.o $(C_SRC_DIR)/drm_device.o $(C_SRC_DIR)/drm_config.o
	$(CC) $(CFLAGS) -DTEST_BUILD $^ -o $@ $(LIBS)

$(C_SRC_DIR)/drm_colortemp_daemon_inotify_test.o: $(C_SRC_DIR)/drm_colortemp_daemon_inotify.c $(C_SRC_DIR)/drm_device.h $(C_SRC_DIR)/drm_colortemp_utils.h $(C_SRC_DIR)/drm_config.h
	$(CC) $(CFLAGS) -DTEST_BUILD -c $< -o $@

# =============================================================================
# ALIASES & BACKWARD COMPATIBILITY
# =============================================================================

# Default 'all' builds both (for transition period)
all: rust legacy
	@echo ""
	@echo "✓ Built both Rust and Legacy C versions"
	@echo "  Rust:   ./target/release/$(RUST_TOOL)"
	@echo "  Legacy: ./$(LEGACY_TOOL) ./$(LEGACY_DAEMON)"

# Old target names now point to legacy versions
tool: legacy-tool
daemon: legacy-daemon
# `make test` is the Rust test suite — what CI expects. Use `legacy-test` for C.
test: rust-test

# Clean everything
clean: rust-clean legacy-clean
	rm -rf build-deb
	@echo "✓ Clean complete (Rust + Legacy + build-deb)"

# Help target
help:
	@echo "DRM Color Temperature - Build Targets"
	@echo ""
	@echo "Primary (Rust v2.0):"
	@echo "  rust / rust-build    - Build Rust implementation (default)"
	@echo "  rust-test            - Run cargo test (alias: 'make test')"
	@echo "  rust-install         - Install Rust version"
	@echo "  rust-uninstall       - Remove Rust version"
	@echo "  rust-clean           - Clean Rust build artifacts"
	@echo "  deb VERSION=X.Y.Z    - Build Debian package (Rust)"
	@echo ""
	@echo "Legacy (C version):"
	@echo "  legacy               - Build both tool and daemon"
	@echo "  legacy-tool          - Build CLI tool only"
	@echo "  legacy-daemon        - Build daemon only"
	@echo "  legacy-test          - Build test binary"
	@echo "  legacy-install       - Install C version"
	@echo "  legacy-install-notifier - Install notification service"
	@echo "  legacy-uninstall     - Remove C version"
	@echo "  legacy-clean         - Clean C build artifacts"
	@echo "  legacy-deb           - Build Debian package (C version)"
	@echo ""
	@echo "Aliases:"
	@echo "  all                  - Build both Rust and C versions"
	@echo "  clean                - Clean both versions"
	@echo "  tool                 - Alias for legacy-tool"
	@echo "  daemon               - Alias for legacy-daemon"
	@echo "  test                 - Alias for legacy-test"
	@echo ""
	@echo "Recommendation: Use Rust version for new installations"
	@echo "  make rust-install    # Install Rust v2.0"

.PHONY: all clean tool daemon test help
