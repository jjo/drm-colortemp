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

From the repository root:

```sh
make applet                # ~10 min first time (builds libcosmic)
sudo make install-applet
```

Or from this directory: `cargo build --release && sudo ./install.sh`

Then: COSMIC Settings → Desktop → Panel → Configure panel applets → **Add "Color Temperature"**.

## Uninstall

```sh
sudo ./uninstall.sh
```

## Files installed

| Path | Purpose |
|---|---|
| `/usr/local/bin/cosmic-applet-colortemp` | the applet (runs as you) |
| `/usr/local/bin/drm-colortemp-apply` | root helper doing the VT switch |
| `/etc/sudoers.d/drm-colortemp-applet` | NOPASSWD rule for the 3 helper commands |
| `/usr/share/applications/io.github.jjo.CosmicAppletColortemp.desktop` | panel applet entry |
| `/usr/share/icons/hicolor/scalable/apps/…-symbolic.svg` | panel icon |

## Troubleshooting

- **"sudo rule missing"** in the popup → re-run `sudo ./install.sh` (it regenerates
  and validates the sudoers rule with `visudo -c`).
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
