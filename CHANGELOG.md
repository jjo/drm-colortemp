# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The Release workflow (`.github/workflows/release.yml`) extracts the section
matching the pushed tag and embeds it in the GitHub Release body. Keep the
section heading format strict: `## [X.Y.Z] - YYYY-MM-DD`.

## [Unreleased]

## [2.0.1] - 2026-05-21

### Fixed
- Systemd unit (`scripts/drm-colortemp.service`) used
  `DeviceAllow=/dev/dri/card0 rw`, which blocked the daemon's cgroup
  device filter from opening any other DRM node. On machines where the
  active GPU isn't `card0` (e.g. ThinkPad T480s: `card0`/`card2` are
  EVDI virtual cards, `card1` is the real Intel iGPU), auto-detect fell
  back to a virtual card whose CRTCs report `mode_valid=0`, and gamma
  application failed silently with `no CRTCs accepted the gamma change`.
  Replaced with `DeviceAllow=char-drm rw` to cover every `/dev/dri/*`.
- Service `ExecStart` aligned with the `.deb` install path (`/usr/bin`).
- Added `DeviceAllow` entries for `/dev/tty0` and `/dev/console`, needed
  by `VT_GETSTATE` under `ProtectSystem=strict`.

### Changed
- `apply_temperature` no longer calls `drmSetMaster`. The C daemon never
  did either, and grabbing the master while the compositor holds it is
  pointless; `SETGAMMA` succeeds whenever the compositor has released
  the master (TTY switch) or we hold raw rw access on the right card.
- 30 s failure backoff after a failed apply, reset on success or VT
  change. Stops the log filling up every `CHECK_INTERVAL` when the
  compositor still owns master.
- Demoted the `try_become_master` failure log from `warn` to `debug`.
  The CLI tool still calls it best-effort; the warning was noise on
  every COSMIC session.

## [2.0.0] - 2026-05-21

### Added
- Complete Rust port. New crate at `src/` provides one `drm-colortemp`
  binary that subsumes both the C `drm_colortemp` CLI and the C
  `drm_colortemp_daemon`.
- Raw DRM ioctls (no `libdrm` runtime dependency):
  `DRM_IOCTL_MODE_{GETRESOURCES,GETCRTC,SETGAMMA,GETCONNECTOR,GETENCODER}`
  plus `DRM_IOCTL_SET_MASTER`. CRTC enumeration, connector→encoder→CRTC
  resolution, and gamma application all done via direct ioctls.
- VT-aware daemon: detects the active virtual terminal via `VT_GETSTATE`
  and lets `WARM_TTY` / `COOL_TTY` override the time-based schedule.
- Connector filter (`CONNECTOR=` in config) with both canonical names
  (`DisplayPort-1`) and short aliases (`DP-1`, `HDMI-A-1`, `eDP-1`).
- `GAMMA_SIZE` config override (range 64–4096; 0 = use hardware-reported
  size).
- Inotify-based config auto-reload that watches the parent directory and
  matches the basename per event — survives vim/nano atomic-rename writes.
- `make deb` target builds a `.deb` of the Rust binary
  (`Depends: libc6, libgcc-s1`; no `libdrm` runtime dep).
- `make rust-test` target plus `make test` alias running `cargo test`
  (34 tests).
- AUR templates under `packaging/aur/`: `PKGBUILD-rust` (versioned),
  `PKGBUILD-rust-git` (VCS), and matching `.SRCINFO*`. Legacy C templates
  (`PKGBUILD`, `PKGBUILD-git`) retained for reference.
- `docs/AUR_RELEASE.md` runbook for publishing both AUR packages.

### Changed
- `make test` now runs the Rust test suite (was the C `test_config`
  binary). Use `make legacy-test` for the C tests.
- `make deb` builds the Rust package (was a no-op alias to the broken
  C-era target). Use `make legacy-deb` for the C variant.
- Default CLI device is `/dev/dri/card1`, matching the C version.
- Source tree reorganized: C sources moved to `src-c/`, shell scripts
  and systemd units moved to `scripts/`.
- CI (`.github/workflows/{build,release}.yml`) rewritten for the Rust
  build: installs `rustup` via `dtolnay/rust-toolchain@stable`, caches
  cargo registry + `target/`, runs `cargo test` and `cargo clippy
  -D warnings`. Release workflow ships the built Rust binary in the
  release tarball and uses this CHANGELOG section as the release body.
- Systemd unit (`scripts/drm-colortemp.service`) uses `ReadOnlyPaths=`
  for the config since the daemon never writes it.

### Fixed
- Brightness validation now runs in both `-t TEMP -b N` and bare `-b N`
  paths (previous Rust scaffold accepted `-t 6500 -b 5.0`).
- Gamma LUT u16 cast now clamps before truncation; `brightness > 1.0`
  no longer wraps near-white entries to small values.
- Config parser: invalid integers now warn and keep the previous
  (defaulted) value per key. The previous scaffold silently swallowed
  every error.
- `device_has_crtcs` actually runs `DRM_IOCTL_MODE_GETRESOURCES` instead
  of falsely returning the `device_accessible` result.

### Notes
- v1.x configs are read unchanged. Canonical config path remains
  `/etc/default/drm-colortemp.conf`.
- The original C tree under `src-c/` still builds via `make legacy*` for
  side-by-side validation. There are no immediate plans to remove it.

## [1.4.0] - 2026-04-01
- Extracted config parser into `drm_config.{c,h}`; added timezone safety,
  connector filter, and gamma-size control (`05cbd5a`).
- Switched daemon logs from `printf` to `syslog` (`5e91544`, `3cb817c`).

## [1.3.0] - 2026-03-19
- Multi-card support: `DEVICE1`..`DEVICE8` config keys (`30ca301`).
- Follow-up: ship files missed in the initial multi-card PR (`9719fdd`).

## [1.2.0] - 2026-02-25
- Auto-detect first DRM device with CRTCs instead of hard-coding
  `/dev/dri/card0` (`bba0309`).
- Notifier script: fix TTY / card detection order (`b1a9599`).
- Notifier script: fix `date` command syntax in log messages (`bb6a095`).

## [1.1.0] - 2026-02-07
- Force warm / cool TTY triggers — daemon overrides the time-based
  schedule when the user switches to a configured TTY (`6efe68a`).
- Extract shared color-temperature code into `drm_colortemp_utils.{c,h}`;
  fix a `basename()` / `dirname()` buffer-aliasing issue (`2edea24`).

## [1.0.0] - 2026-02-07
- Initial release: DRM-based color temperature control tool for COSMIC
  DE, working around missing `wlr-gamma-control-unstable-v1` protocol
  support on the Pop!\_OS COSMIC compositor (`7cb2c59`).

[Unreleased]: https://github.com/jjo/drm-colortemp/compare/v2.0.1...HEAD
[2.0.1]: https://github.com/jjo/drm-colortemp/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/jjo/drm-colortemp/compare/v1.4.0...v2.0.0
[1.4.0]: https://github.com/jjo/drm-colortemp/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/jjo/drm-colortemp/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/jjo/drm-colortemp/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/jjo/drm-colortemp/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/jjo/drm-colortemp/releases/tag/v1.0.0
