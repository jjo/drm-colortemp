# cosmic-applet-colortemp

A COSMIC panel applet for drm-colortemp. One click on a panel icon applies your
screen color temperature — no manual Ctrl+Alt+F3 / Ctrl+Alt+F2 dance.

Popup offers three actions: **Auto** (time-based, daemon decides), **Night** (warm,
your `NIGHT_TEMP`), and **Day** (neutral, your `DAY_TEMP`). Temperatures shown in the
popup are read live from `/etc/default/drm-colortemp.conf`.

## How it works

COSMIC holds DRM master, so nothing can set gamma while it's in the foreground.
drm-colortemp's daemon applies gamma during the moment COSMIC releases DRM master
on a VT switch. This applet automates that: it runs a small root helper
(`drm-colortemp-apply`) that does `chvt <target-tty>`, waits ~1.2 s for the daemon
to apply the gamma LUT, then `chvt` back. Your screen still flickers briefly —
that's inherent to the workaround, not a bug.

The helper is the only thing that runs as root, authorized by a sudoers rule that
permits exactly three fixed command lines (`... apply auto|night|day`) for your
user only. The applet itself runs unprivileged.

## Prerequisites

- drm-colortemp installed with its daemon running:
  `sudo systemctl enable --now drm-colortemp-daemon`
- Rust toolchain (rustup recommended; libcosmic wants a recent stable, 1.85+)
- Build deps: `sudo apt install build-essential pkg-config libxkbcommon-dev libwayland-dev cmake`

## Install

### From a package (recommended)

The applet ships as its own package so the headless daemon does not inherit
libcosmic's runtime dependencies.

```sh
# Debian / Ubuntu — attached to each GitHub release
sudo apt install ./drm-colortemp-cosmic-applet_*.deb

# Arch (AUR)
yay -S cosmic-applet-colortemp        # or cosmic-applet-colortemp-git
```

Packages install to `/usr/bin` and authorize the helper for a **group**
(`%sudo` on Debian/Ubuntu, `%wheel` on Arch) rather than a single user, since a
package cannot know who runs the panel. Make sure your user is in that group.

### From source

From the repository root:

```sh
make applet                # ~10 min first time (builds libcosmic)
sudo make install-applet
```

Or from this directory: `cargo build --release && sudo ./install.sh`

The source install uses `/usr/local/bin` and grants the sudoers rule to the
invoking user only. The applet resolves the helper at runtime, preferring
`/usr/local/bin` over `/usr/bin`, so either layout works on its own.

> **Pick one — they are mutually exclusive.** Both installers own the same
> `/etc/sudoers.d/drm-colortemp-applet`, but authorize different helper paths.
> Install the package over a source install and the packaged rule (which permits
> only `/usr/bin/drm-colortemp-apply`) replaces yours, while the applet still
> prefers the `/usr/local/bin` helper left behind — every action then fails with
> a sudo denial. Remove the other layout first: `sudo ./uninstall.sh` before
> installing the package, or `sudo apt remove drm-colortemp-cosmic-applet`
> before installing from source. `install.sh` and the package both refuse to
> proceed if they detect the other layout.

To build the `.deb` yourself: `make applet-deb VERSION=2.0.1` from the repo root.

Then: COSMIC Settings → Desktop → Panel → Configure panel applets → **Add "Color Temperature"**.

## Uninstall

```sh
sudo ./uninstall.sh          # source install
sudo apt remove drm-colortemp-cosmic-applet   # .deb
```

## Files installed

Paths below are for a source install; packages use `/usr/bin` instead of
`/usr/local/bin`.

| Path | Purpose |
|---|---|
| `/usr/local/bin/cosmic-applet-colortemp` | the applet (runs as you) |
| `/usr/local/bin/drm-colortemp-apply` | root helper doing the VT switch |
| `/etc/sudoers.d/drm-colortemp-applet` | NOPASSWD rule for the 3 helper commands |
| `/usr/share/applications/io.github.jjo.CosmicAppletColortemp.desktop` | panel applet entry |
| `/usr/share/icons/hicolor/scalable/apps/…-symbolic.svg` | panel icon |

The sudoers rule is generated from `data/drm-colortemp-applet.sudoers.in` — one
template shared by `install.sh`, the `.deb`, and the AUR PKGBUILDs, so the
authorized command lines can't drift between install methods.

## Troubleshooting

- **"sudo rule missing"** in the popup → source install: re-run `sudo ./install.sh`
  (it regenerates and validates the sudoers rule with `visudo -c`). Package install:
  confirm your user is in `sudo` (Debian/Ubuntu) or `wheel` (Arch) —
  `id -nG | tr ' ' '\n' | grep -x 'sudo\|wheel'`.
- **"daemon is not running"** → `sudo systemctl enable --now drm-colortemp-daemon`.
- **Nothing changes but console flashes** → check `sudo journalctl -u drm-colortemp-daemon -f`
  while clicking; verify `MONITOR_TTY`/`WARM_TTY`/`COOL_TTY` in
  `/etc/default/drm-colortemp.conf` match what the helper targets (it reads the same file).
- **Applet not listed in panel settings** → confirm the .desktop file is in
  `/usr/share/applications` and has `X-CosmicApplet=true`; log out/in.

## Notes

- Built against libcosmic pinned to the same revision used by pop-os/cosmic-applets
  (see `Cargo.toml`). If a future `cargo build` fails on API changes, bump the rev and
  compare against a current applet in [pop-os/cosmic-applets](https://github.com/pop-os/cosmic-applets).
- This whole mechanism becomes obsolete once COSMIC ships native night light
  ([cosmic-comp#2059](https://github.com/pop-os/cosmic-comp/issues/2059)).
