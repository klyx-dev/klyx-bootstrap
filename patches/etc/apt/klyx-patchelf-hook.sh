#!/data/data/com.klyx/files/usr/bin/sh
# This hook runs after dpkg unpacks new files during package install.
# It fixes compatibility issues in recently installed ELF binaries.
#
# The script performs two main recovery actions:
#   1. It rewrites embedded Termux path strings inside ELF rodata
#      so binaries and scripts installed from packages resolve to
#      the Klyx prefix.
#   2. It adjusts ELF DT_RUNPATH entries for newly installed binaries
#      when patchelf is available, so dynamic loaders find libraries
#      under the Klyx prefix.
#
# The hook uses ctime (-cmin) instead of file modification time,
# because dpkg preserves the original mtime from the package but
# updates ctime when it changes ownership or permissions during install.
#
# Compatibility guidance learned from testing:
#   * Do not use patchelf force-rpath. It converts DT_RUNPATH into
#     DT_RPATH and can corrupt some libraries.
#   * Avoid rewriting ELF files whose RUNPATH already points at our prefix.
#   * Avoid patching packaged runtime files that are intentionally shipped
#     with their own loader or dynamic linker.
set -u

PREFIX=/data/data/com.klyx/files/usr
WANT="$PREFIX/lib"

debug() {
    [ -n "${KLYX_DEBUG:-}" ] && printf '%s\n' "klyx-patchelf-hook: $*" >&2
}

ARCH=$(uname -m 2>/dev/null || echo unknown)
case "$ARCH" in
    aarch64) MUSL_LD="ld-musl-aarch64.so.1" ;;
    x86_64)  MUSL_LD="ld-musl-x86_64.so.1"  ;;
    *)       MUSL_LD="ld-musl.so.1"          ;;
esac

# Choose the patchelf binary to use for runpath fixes.
# Prefer the musl-linked patchelf from the main prefix because it
# matches the bootstrap environment, and fall back to the glibc-stack
# version only if needed. If neither exists, the script still performs
# the rodata path rewrite.
PATCHELF=""
if [ -x "$PREFIX/bin/patchelf" ]; then
    PATCHELF="$PREFIX/bin/patchelf"
elif [ -x "$PREFIX/glibc/bin/patchelf" ]; then
    PATCHELF="$PREFIX/glibc/bin/patchelf"
fi

debug "Selected patchelf: ${PATCHELF:-none}"

maybe_patchelf() {
    [ -n "$PATCHELF" ] || return 0
    file="$1"
    debug "Checking runtime path for $file"
    case "${file##*/}" in
        ld-musl-*.so.1|libc.musl-*.so.1|libc++_shared.so)
            debug "Skipping packaged runtime file that should not be rewritten: $file"
            return 0
            ;;
    esac
    current=$("$PATCHELF" --print-rpath "$file" 2>/dev/null) || {
        debug "Could not read rpath for $file"
        return 0
    }
    debug "Current rpath for $file: $current"
    [ "$current" = "$WANT" ] && {
        debug "Rpath already matches desired prefix for $file"
        return 0
    }
    case "$current" in *com.klyx*)
        debug "Binary already has Klyx path in rpath; skipping $file"
        return 0
        ;;
    esac
    debug "Updating rpath for $file to $WANT"
    if ! "$PATCHELF" --set-rpath "$WANT" "$file" 2>/dev/null; then
        debug "patchelf failed to set rpath on $file"
    fi
}
maybe_hex_patch() {
    [ -x "$PREFIX/bin/perl" ] || return 0
    # Only inspect binaries that actually contain the Termux path.
    # This avoids processing files unnecessarily.
    local has_termux=0
    grep -q -a -- '/data/data/com.termux/' "$1" 2>/dev/null && has_termux=1
    [ $has_termux -eq 0 ] && return 0

    # Perform an in-place rewrite of embedded Termux paths to Klyx paths.
    # The replacement is equal length, so the binary layout remains stable.
    "$PREFIX/bin/perl" -e '
                my $path = $ARGV[0];
                open my $fh, "+<:raw", $path or exit 0;
                my $data = do { local $/; <$fh> };
                my $tcount = 0;
                # Pass 1: com.termux/ -> com.klyx/ (22 bytes <-> 22 bytes,
                # in-place; the equal-length property of the com.klyx
                # rename).
                while ($data =~ m{/data/data/com\.termux/}g) {
                    my $offset = $-[0];
                    seek $fh, $offset, 0;
                    print $fh "/data/data/com.klyx/\x00\x00";
                    $tcount++;
                }
                close $fh;
                print STDERR "klyx-rodata-hex: $tcount com.termux in $path\n" if ($tcount > 0);
            ' "$1" 2>&1
}

# Scan recently modified installed files and apply compatibility fixes.
# The first loop covers executables and helper binaries; the second loop
# covers shared libraries that may need RUNPATH adjustment.
find "$PREFIX/bin" "$PREFIX/sbin" "$PREFIX/libexec" "$PREFIX/glibc/bin" "$PREFIX/glibc/sbin" "$PREFIX/glibc/libexec" -type f -cmin -10 2>/dev/null | while IFS= read -r f; do maybe_hex_patch "$f"; maybe_patchelf "$f"; done
find "$PREFIX/lib" "$PREFIX/glibc/lib" -type f -cmin -10 -name '*.so*' 2>/dev/null | while IFS= read -r f; do maybe_hex_patch "$f"; maybe_patchelf "$f"; done
exit 0
