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
	# Only our own staging dir: `applet-deb` stages a sibling under build-deb/.
	rm -rf $(DEB_DIR)
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
# DEBIAN PACKAGING (COSMIC applet)
# =============================================================================
# Separate binary package: the applet drags in libcosmic wayland/xkbcommon/X11
# runtime libs that the headless daemon package has no business depending on.
# Shipped alongside the main .deb by .github/workflows/release.yml.

APPLET_BIN     = cosmic-applet-colortemp
APPLET_PKG     = drm-colortemp-cosmic-applet
APPLET_DEB_PKG = $(APPLET_PKG)_$(VERSION)_$(ARCH)
APPLET_DEB_DIR = build-deb/$(APPLET_DEB_PKG)
# Packages cannot know which user runs the panel, so the sudoers rule is granted
# to a group. `sudo` is the Debian/Ubuntu admin group (Arch uses `wheel`).
APPLET_SUDO_GROUP ?= sudo
# Minimum daemon version the applet's helper expects (VT-switch semantics).
APPLET_DAEMON_MIN ?= 2.0.0

# Runtime libraries libcosmic/winit dlopen() rather than link: they carry no
# DT_NEEDED entry, so they must be listed by hand. Required under COSMIC.
# libxkbcommon0 is DT_NEEDED in the current build and would be derived anyway,
# but winit can also load it via xkbcommon-dl, so name it here too; the union is
# deduplicated.
APPLET_DLOPEN_DEPS ?= libwayland-client0, libxkbcommon0
# winit's X11 backend is also dlopen()ed. Unused on COSMIC (Wayland), so these
# are Recommends, not Depends.
APPLET_X11_DEPS ?= libx11-6, libx11-xcb1, libxcb1, libxi6, libxkbcommon-x11-0
# Fallback when dpkg is unavailable to map sonames to packages (e.g. building
# the .deb on a non-Debian host). Mirrors the binary's current DT_NEEDED set.
APPLET_STATIC_DEPS ?= libc6, libgcc-s1, libxkbcommon0
# Set to 1 on Debian hosts (CI does) to make the static fallback a hard error
# instead of a silent downgrade — otherwise a broken derivation looks like a pass.
REQUIRE_DERIVED ?=
# Note: the applet renders with tiny-skia/softbuffer (software), not wgpu, so it
# needs no Vulkan or GL runtime — only fonts, hence the fonts-dejavu-core
# Recommends below.

.PHONY: applet-deb debs
applet-deb: applet
	@echo "Building Debian package $(APPLET_DEB_PKG).deb..."
	rm -rf $(APPLET_DEB_DIR)
	install -D -m 755 applet/target/release/$(APPLET_BIN) $(APPLET_DEB_DIR)/usr/bin/$(APPLET_BIN)
	# Root helper doing the chvt dance; the only privileged piece.
	install -D -m 755 applet/helper/drm-colortemp-apply $(APPLET_DEB_DIR)/usr/bin/drm-colortemp-apply
	install -D -m 644 applet/data/io.github.jjo.CosmicAppletColortemp.desktop \
		$(APPLET_DEB_DIR)/usr/share/applications/io.github.jjo.CosmicAppletColortemp.desktop
	install -D -m 644 applet/data/icons/io.github.jjo.CosmicAppletColortemp-symbolic.svg \
		$(APPLET_DEB_DIR)/usr/share/icons/hicolor/scalable/apps/io.github.jjo.CosmicAppletColortemp-symbolic.svg
	install -D -m 644 applet/README.md $(APPLET_DEB_DIR)/usr/share/doc/$(APPLET_PKG)/README.md
	# Sources default to the source-install prefix; rewrite for packaged layout.
	sed -i 's|/usr/local/bin|/usr/bin|g' \
		$(APPLET_DEB_DIR)/usr/share/applications/io.github.jjo.CosmicAppletColortemp.desktop
	# Sudoers rule from the shared template, granted to a group rather than a user.
	mkdir -p $(APPLET_DEB_DIR)/etc/sudoers.d
	sed -e 's|@PRINCIPAL@|%$(APPLET_SUDO_GROUP)|g' -e 's|@BINDIR@|/usr/bin|g' \
		applet/data/drm-colortemp-applet.sudoers.in \
		> $(APPLET_DEB_DIR)/etc/sudoers.d/drm-colortemp-applet
	chmod 0440 $(APPLET_DEB_DIR)/etc/sudoers.d/drm-colortemp-applet
	# Reject a malformed rule at build time rather than at the user's install.
	if command -v visudo >/dev/null 2>&1; then \
		visudo -cf $(APPLET_DEB_DIR)/etc/sudoers.d/drm-colortemp-applet >/dev/null; \
	fi
	mkdir -p $(APPLET_DEB_DIR)/DEBIAN
	# Library deps are derived from the binary (see scripts/applet-deb-deps.sh):
	# DT_NEEDED entries resolved to owning packages, unioned with the dlopen()ed
	# ones that carry no DT_NEEDED entry.
	set -e; \
	LIB_DEPS=$$(DLOPEN_DEPS="$(APPLET_DLOPEN_DEPS)" STATIC_DEPS="$(APPLET_STATIC_DEPS)" \
		REQUIRE_DERIVED="$(REQUIRE_DERIVED)" \
		$(SCRIPTS_DIR)/applet-deb-deps.sh applet/target/release/$(APPLET_BIN)); \
	{ \
		echo "Package: $(APPLET_PKG)"; \
		echo "Version: $(VERSION)"; \
		echo "Architecture: $(ARCH)"; \
		echo "Maintainer: jjo <jjo@users.noreply.github.com>"; \
		echo "Depends: drm-colortemp (>= $(APPLET_DAEMON_MIN)), sudo, kbd, $$LIB_DEPS"; \
		echo "Recommends: $(APPLET_X11_DEPS), fonts-dejavu-core"; \
		echo "Section: x11"; \
		echo "Priority: optional"; \
		echo "Homepage: https://github.com/jjo/drm-colortemp"; \
		echo "Description: COSMIC panel applet for drm-colortemp"; \
		echo " Panel applet exposing one-click Auto / Night / Day screen color"; \
		echo " temperature for the drm-colortemp daemon on COSMIC Desktop."; \
		echo " Runs a narrowly scoped root helper via sudo to perform the VT switch"; \
		echo " that lets the daemon apply the gamma LUT."; \
	} > $(APPLET_DEB_DIR)/DEBIAN/control
	echo "/etc/sudoers.d/drm-colortemp-applet" > $(APPLET_DEB_DIR)/DEBIAN/conffiles
	# Refuse to install over a source install (applet/install.sh): it owns the
	# same sudoers file but authorizes the /usr/local/bin helper, which the applet
	# prefers at runtime, so the combination denies every action.
	printf '#!/bin/sh\nset -e\nif [ "$$1" = "install" ] && [ -e /usr/local/bin/drm-colortemp-apply ]; then\n    echo "ERROR: a source install was detected (/usr/local/bin/drm-colortemp-apply)." >&2\n    echo "It is mutually exclusive with this package; run applet/uninstall.sh first." >&2\n    exit 1\nfi\n' \
		> $(APPLET_DEB_DIR)/DEBIAN/preinst
	printf '#!/bin/sh\nset -e\nif [ "$$1" = "configure" ]; then\n    if command -v gtk-update-icon-cache >/dev/null 2>&1; then\n        gtk-update-icon-cache -q /usr/share/icons/hicolor || true\n    fi\nfi\n' \
		> $(APPLET_DEB_DIR)/DEBIAN/postinst
	printf '#!/bin/sh\nset -e\nif [ "$$1" = "remove" ] || [ "$$1" = "purge" ]; then\n    if command -v gtk-update-icon-cache >/dev/null 2>&1; then\n        gtk-update-icon-cache -q /usr/share/icons/hicolor || true\n    fi\nfi\n' \
		> $(APPLET_DEB_DIR)/DEBIAN/postrm
	chmod 755 $(APPLET_DEB_DIR)/DEBIAN/preinst $(APPLET_DEB_DIR)/DEBIAN/postinst \
		$(APPLET_DEB_DIR)/DEBIAN/postrm
	dpkg-deb --build --root-owner-group $(APPLET_DEB_DIR) build-deb/
	@echo ""
	@echo "✓ Built build-deb/$(APPLET_DEB_PKG).deb"

# Both packages in one shot (what release CI ships).
debs: deb applet-deb

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

# =============================================================================
# COSMIC panel applet (optional, see applet/README.md)
# =============================================================================

applet:
	cd applet && cargo build --release
	@echo "✓ Applet built: applet/target/release/cosmic-applet-colortemp"

install-applet:
	cd applet && ./install.sh

uninstall-applet:
	cd applet && ./uninstall.sh

applet-clean:
	cd applet && cargo clean

.PHONY: applet install-applet uninstall-applet applet-clean

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
	@echo "  deb VERSION=X.Y.Z    - Build Debian package (Rust daemon)"
	@echo "  applet-deb VERSION=X.Y.Z - Build Debian package (COSMIC applet)"
	@echo "  debs VERSION=X.Y.Z   - Build both .debs (what release CI ships)"
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
	@echo "COSMIC panel applet (optional):"
	@echo "  applet               - Build the panel applet (Rust/libcosmic)"
	@echo "  install-applet       - Install applet + root helper + sudoers rule"
	@echo "  uninstall-applet     - Remove the applet"
	@echo "  applet-clean         - Clean applet build artifacts"
	@echo "  applet-deb VERSION=X.Y.Z - Package the applet as a .deb"
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
