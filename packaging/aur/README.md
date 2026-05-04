# AUR packaging

Two `PKGBUILD`s for Arch User Repository:

- `PKGBUILD`     — versioned package `drm-colortemp` (release tag tarball)
- `PKGBUILD-git` — VCS package `drm-colortemp-git` (tracks `main`)

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

## Updating on new release

1. Bump `pkgver` in `packaging/aur/PKGBUILD`, set `pkgrel=1`.
2. `updpkgsums` to refresh the tarball checksum.
3. Sync to the AUR repo, regen `.SRCINFO`, commit, push.

The `-git` package needs no version bump — `pkgver()` resolves at build time.
