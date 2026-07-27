#!/bin/sh
# applet-deb-deps.sh — compute the Debian `Depends:` library list for the COSMIC
# applet package.
#
# Usage: applet-deb-deps.sh <binary>
#
# Environment:
#   DLOPEN_DEPS  comma-separated packages providing libraries the binary
#                dlopen()s (no DT_NEEDED entry, so underivable)
#   STATIC_DEPS  comma-separated fallback used when dpkg is unavailable, e.g.
#                when building the .deb on a non-Debian host
#
# Prints one comma-separated dependency list on stdout.
#
# Why not dpkg-shlibdeps: it requires a debian/ source tree (debian/control) that
# this hand-rolled dpkg-deb layout does not have, and it only sees DT_NEEDED —
# the same blind spot that makes DLOPEN_DEPS necessary either way. What it does
# better is resolving the owning package precisely, which is why the DT_NEEDED
# sonames below are resolved to absolute paths via ldd before asking dpkg who
# owns them, rather than globbing on basename.
set -eu

BIN=${1:?usage: applet-deb-deps.sh <binary>}
DLOPEN_DEPS=${DLOPEN_DEPS:-}
STATIC_DEPS=${STATIC_DEPS:-}

[ -e "$BIN" ] || { echo "applet-deb-deps.sh: no such binary: $BIN" >&2; exit 1; }

# Split a comma-separated list into one trimmed entry per line.
split_list() {
    printf '%s\n' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | grep -v '^$' || true
}

# Ask dpkg which package owns a library path. On merged-/usr systems (Debian 12+,
# Ubuntu 22.04+) ldd reports /lib/..., while dpkg's database only records the
# /usr/lib/... name, so a single lookup silently finds nothing. Try the plausible
# spellings, including the fully resolved symlink target.
owning_package() {
    _path=$1
    for _cand in "$_path" "/usr$_path" "$(readlink -f "$_path" 2>/dev/null || true)" \
                 "$(readlink -f "/usr$_path" 2>/dev/null || true)"; do
        [ -n "$_cand" ] || continue
        _pkg=$(dpkg -S "$_cand" 2>/dev/null | head -1 | cut -d: -f1) || _pkg=''
        if [ -n "$_pkg" ]; then
            printf '%s\n' "$_pkg"
            return 0
        fi
    done
    echo "applet-deb-deps.sh: no package owns $_path" >&2
    return 0
}

derived=''
if command -v dpkg >/dev/null 2>&1 && command -v objdump >/dev/null 2>&1; then
    derived=$(
        objdump -p "$BIN" 2>/dev/null | awk '/NEEDED/ {print $2}' | while read -r so; do
            # Resolve the soname to the file actually loaded, then ask dpkg which
            # package owns that exact path. Globbing (`dpkg -S "*/$so"`) can match
            # several packages shipping the same basename and pick the wrong one.
            path=$(ldd "$BIN" 2>/dev/null \
                | awk -v s="$so" '$1 == s && $2 == "=>" {print $3; exit}')
            [ -n "$path" ] || continue
            owning_package "$path"
        done
    )
fi

if [ -z "$derived" ]; then
    # REQUIRE_DERIVED makes the fallback fatal. CI sets it so that a broken
    # derivation fails the build instead of quietly shipping the static list,
    # which would make the dependency assertions vacuous.
    if [ -n "${REQUIRE_DERIVED:-}" ]; then
        echo "applet-deb-deps.sh: DT_NEEDED derivation produced nothing and" \
             "REQUIRE_DERIVED is set — refusing to fall back to STATIC_DEPS" >&2
        exit 1
    fi
    echo "applet-deb-deps.sh: could not derive DT_NEEDED deps (no dpkg?); using STATIC_DEPS" >&2
    derived=$(split_list "$STATIC_DEPS")
fi

# Union with the dlopen()ed packages, deduplicated: entries may legitimately
# appear in both lists (libxkbcommon is linked today but loaded dynamically by
# some winit configurations, so it is named in both).
{ printf '%s\n' "$derived"; split_list "$DLOPEN_DEPS"; } \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | grep -v '^$' \
    | sort -u \
    | paste -sd, - \
    | sed 's/,/, /g'
