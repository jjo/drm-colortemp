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
    return 1
}

# A partially resolved list is worse than none: it would install cleanly and then
# fail at runtime on the missing library. Any DT_NEEDED entry that cannot be
# resolved and attributed therefore invalidates the whole derivation. The loop
# runs in a subshell, so it signals failure through a marker file.
unresolved=$(mktemp)
trap 'rm -f "$unresolved"' EXIT INT TERM

derived=''
if command -v dpkg >/dev/null 2>&1 && command -v objdump >/dev/null 2>&1; then
    derived=$(
        objdump -p "$BIN" 2>/dev/null | awk '/NEEDED/ {print $2}' | while read -r so; do
            # The program interpreter is listed in DT_NEEDED but ldd prints it
            # without a `=>` mapping, so it is never resolvable here. It belongs
            # to libc6, which libc.so.6 already pulls in.
            case "$so" in
                ld-linux*.so.*|ld64.so.*|ld.so.*) continue ;;
            esac
            # Resolve the soname to the file actually loaded, then ask dpkg which
            # package owns that exact path. Globbing (`dpkg -S "*/$so"`) can match
            # several packages shipping the same basename and pick the wrong one.
            # `=> not found` yields $3 == "not", which must not be taken as a path.
            path=$(ldd "$BIN" 2>/dev/null \
                | awk -v s="$so" '$1 == s && $2 == "=>" && $3 != "not" {print $3; exit}')
            if [ -z "$path" ]; then
                echo "applet-deb-deps.sh: cannot resolve $so (missing library?)" >&2
                echo "$so" >> "$unresolved"
                continue
            fi
            owning_package "$path" || echo "$so" >> "$unresolved"
        done
    )
fi

if [ -s "$unresolved" ]; then
    echo "applet-deb-deps.sh: unresolved DT_NEEDED entries:" \
         "$(tr '\n' ' ' < "$unresolved")" >&2
    # Discard the partial list so the checks below treat this as a failed
    # derivation rather than shipping an incomplete Depends field.
    derived=''
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
