# AUR Release Runbook (Arch Linux box)

Run from an Arch Linux machine with `base-devel`, `pacman-contrib` (for
`updpkgsums`), `namcap`, and an AUR account with SSH key uploaded
(<https://aur.archlinux.org/account/>).

## Prerequisites

1. v2.0.0 tag pushed to <https://github.com/jjo/drm-colortemp>.
2. GitHub Release workflow has published `drm-colortemp-2.0.0.tar.gz`
   (release artifacts, not just the auto-generated source archive).
3. `packaging/aur/PKGBUILD-rust` + `PKGBUILD-rust-git` are on `main` and
   their layout matches the released tarball (binary paths, scripts dir, conf
   location).

## Versioned package (`drm-colortemp`)

```bash
# 1. Clone the AUR repo (separate from the main project repo)
git clone ssh://aur@aur.archlinux.org/drm-colortemp.git aur-drm-colortemp
cd aur-drm-colortemp

# 2. Stage the Rust PKGBUILD as the canonical PKGBUILD
cp /path/to/drm-colortemp/packaging/aur/PKGBUILD-rust PKGBUILD

# 3. Refresh sha256 from the v2.0.0 release tarball
updpkgsums

# 4. Local build + install — MUST succeed clean before push
makepkg -si
namcap PKGBUILD
namcap drm-colortemp-*.pkg.tar.zst

# 5. Regenerate .SRCINFO (AUR rejects pushes whose .SRCINFO is stale)
makepkg --printsrcinfo > .SRCINFO

# 6. Push
git add PKGBUILD .SRCINFO
git commit -m "drm-colortemp 2.0.0-1: Rust rewrite"
git push origin master
```

## VCS package (`drm-colortemp-git`)

```bash
# Separate AUR repo
git clone ssh://aur@aur.archlinux.org/drm-colortemp-git.git aur-drm-colortemp-git
cd aur-drm-colortemp-git

cp /path/to/drm-colortemp/packaging/aur/PKGBUILD-rust-git PKGBUILD

# Local verification
makepkg -si --skipchecksums    # source=git; pkgver() resolves from HEAD
namcap PKGBUILD

makepkg --printsrcinfo > .SRCINFO

git add PKGBUILD .SRCINFO
git commit -m "drm-colortemp-git: switch to Rust rewrite"
git push origin master
```

## Update on future releases

1. Bump `pkgver` in `packaging/aur/PKGBUILD-rust` on main, set `pkgrel=1`.
2. Push the new git tag → wait for the GitHub Release workflow to publish the
   tarball.
3. In `aur-drm-colortemp`, refresh `PKGBUILD` from main, run `updpkgsums`,
   regenerate `.SRCINFO`, commit, push.

The `-git` package needs no version bump — `pkgver()` resolves at build time
from `git describe`.

## Caveats found while drafting the PKGBUILD-rust

- `prepare()` calls `cargo fetch --locked`, so `Cargo.lock` MUST be in the
  release tarball. The Release workflow on `main` already copies it
  (`Cargo.toml Cargo.lock` line in `.github/workflows/release.yml`). If the
  tarball ever omits it, drop `--locked`/`--frozen` from `prepare()`/`build()`.
- Binary is shipped as `/usr/bin/drm-colortemp` even though cargo names it
  `drm-colortemp-rs`. The `install -Dm755 target/release/drm-colortemp-rs
  "$pkgdir/usr/bin/drm-colortemp"` line handles the rename.
- Config path is `/etc/default/drm-colortemp.conf` across the binary
  default (`src/main.rs: DEFAULT_DAEMON_CONFIG`), the systemd unit
  (`scripts/drm-colortemp.service: ReadOnlyPaths`), and the AUR / Debian
  packages. Don't put the file at `/etc/drm-colortemp.conf` — the daemon
  won't find it.

## Testing the package post-install

```bash
sudo systemctl enable --now drm-colortemp
journalctl -u drm-colortemp -f
# From a free TTY (Ctrl+Alt+F3):
sudo drm-colortemp -t 3500
sudo drm-colortemp -l
```
