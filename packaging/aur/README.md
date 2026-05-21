# AUR packaging

Four `PKGBUILD`s for Arch User Repository, covering both the legacy C build
(v0.2.x) and the Rust rewrite (v2.x):

| File | AUR pkgname | Source | Notes |
|---|---|---|---|
| `PKGBUILD`          | `drm-colortemp`     | release tarball | **legacy C** v0.2.x |
| `PKGBUILD-git`      | `drm-colortemp-git` | `main` branch   | **legacy C** VCS |
| `PKGBUILD-rust`     | `drm-colortemp`     | release tarball | **Rust** v2.x (recommended) |
| `PKGBUILD-rust-git` | `drm-colortemp-git` | `main` branch   | **Rust** VCS |

The Rust rewrite ships a single `drm-colortemp` binary that subsumes both
the old `drm_colortemp` CLI and the `drm_colortemp_daemon`. It also drops
the `libdrm` runtime dependency (raw ioctls). When you cut the v2.0.0 tag,
switch your AUR `drm-colortemp` / `drm-colortemp-git` repos to the
`PKGBUILD-rust*` variants.

These are templates kept in the upstream tree. The AUR itself requires a
**separate git repo per package** under `ssh://aur@aur.archlinux.org/`. Do not
push this directory there directly — copy the relevant `PKGBUILD` into the AUR
repo as `PKGBUILD`, generate `.SRCINFO`, then push.

## Prerequisites

- AUR account with SSH key uploaded: <https://aur.archlinux.org/account/>
- `base-devel`, `pacman-contrib` (for `updpkgsums`), `namcap`

## Local verification (always run before pushing)

```bash
cd packaging/aur
cp PKGBUILD /tmp/aur-test/PKGBUILD       # work in a scratch dir
cd /tmp/aur-test
updpkgsums                                # refresh sha256
makepkg -si                               # build + install — must succeed clean
namcap PKGBUILD
namcap drm-colortemp-*.pkg.tar.zst
makepkg --printsrcinfo > .SRCINFO
```

## Publishing the versioned package

```bash
git clone ssh://aur@aur.archlinux.org/drm-colortemp.git aur-drm-colortemp
cp packaging/aur/PKGBUILD aur-drm-colortemp/PKGBUILD
cd aur-drm-colortemp
makepkg --printsrcinfo > .SRCINFO
git add PKGBUILD .SRCINFO
git commit -m "drm-colortemp 0.2.10-1: initial import"
git push origin master
```

## Publishing the `-git` package

```bash
git clone ssh://aur@aur.archlinux.org/drm-colortemp-git.git aur-drm-colortemp-git
cp packaging/aur/PKGBUILD-git aur-drm-colortemp-git/PKGBUILD
cd aur-drm-colortemp-git
makepkg --printsrcinfo > .SRCINFO
git add PKGBUILD .SRCINFO
git commit -m "drm-colortemp-git: initial import"
git push origin master
```

## Publishing the Rust variant

For the v2.0.0+ Rust rewrite, use `PKGBUILD-rust` (versioned) or
`PKGBUILD-rust-git` (VCS):

```bash
git clone ssh://aur@aur.archlinux.org/drm-colortemp.git aur-drm-colortemp
cp packaging/aur/PKGBUILD-rust aur-drm-colortemp/PKGBUILD
cd aur-drm-colortemp
updpkgsums
makepkg --printsrcinfo > .SRCINFO
git add PKGBUILD .SRCINFO
git commit -m "drm-colortemp 2.0.0-1: switch to Rust rewrite"
git push origin master
```

Note for the Rust PKGBUILDs: `makepkg` runs `cargo fetch --locked` in
`prepare()`, so the upstream `Cargo.lock` must be checked into the release
tag tarball. If it isn't, drop `--locked`/`--frozen` from `prepare()`/`build()`.

## Updating on new release

1. Bump `pkgver` in `packaging/aur/PKGBUILD` (C) or `PKGBUILD-rust` (Rust),
   set `pkgrel=1`.
2. `updpkgsums` to refresh the tarball checksum.
3. Sync to the AUR repo, regen `.SRCINFO`, commit, push.

The `-git` packages need no version bump — `pkgver()` resolves at build time.
